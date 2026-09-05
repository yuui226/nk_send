import Foundation
import ZTransferShared

protocol CameraCatalogSource: AnyObject {
    var connectionID: UUID { get }
    func storageIDs() async throws -> [Int32]
    func objectHandles(storageID: Int32) async throws -> [Int32]
    func objectInfo(handle: Int32) async throws -> PtpObjectInfo
    func snapshot() async -> CameraConnectionSnapshot
}

extension CameraWiFiConnection: CameraCatalogSource {}

struct CameraCatalogSnapshot {
    let connectionID: UUID
    let revision: UInt64
    let storageIDs: [Int32]
    let files: [CameraFileInfo]
    let objectInfos: [Int32: PtpObjectInfo]
    let totalHandles: Int
    let metadataComplete: Bool
    let changedWhileScanning: Bool
}

/// Normal AP/STA catalog only. One immutable camera generation; failed enumeration never replaces
/// the last good snapshot with an empty list. Shared code owns handle order and backup merging.
/// Event revisions are invalidations, not lossless events; callers must schedule another scan when
/// changedWhileScanning is true. Automatic transfer/event reconciliation is a separate coordinator.
actor CameraCatalog {
    private let source: CameraCatalogSource
    private let stationMode: Bool
    private let previews: CameraPreviewStore?
    private var scanning = false
    private var latest: CameraCatalogSnapshot?

    init(source: CameraCatalogSource, stationMode: Bool, previews: CameraPreviewStore? = nil) {
        self.source = source; self.stationMode = stationMode; self.previews = previews
    }
    func snapshot() -> CameraCatalogSnapshot? { latest }

    func refresh() async throws -> CameraCatalogSnapshot {
        guard !scanning else { throw CameraStreamError.operationInProgress }
        try Task.checkCancellation()
        scanning = true
        defer { scanning = false }
        let fillScan = await previews?.beginCatalogScan()
        do {
            let before = await source.snapshot()
            guard before.phase == .ready else { throw CameraStreamError.notConnected }
            let stores = try await source.storageIDs()
            let scan = NativeCameraCatalogScan(rawStorageIds: Self.native(stores), stationMode: stationMode)
            for index in 0..<Int(scan.storageCount) {
                try Task.checkCancellation()
                let handles = try await source.objectHandles(storageID: scan.queryStorageId(index: Int32(index)))
                guard scan.addHandles(index: Int32(index), handles: Self.native(handles)) else { throw CameraStreamError.invalidArgument }
            }
            guard scan.begin() else { throw CameraStreamError.invalidArgument }
            while true {
                try Task.checkCancellation()
                if let handle = scan.nextReadHandle()?.int32Value {
                    let info: PtpObjectInfo?
                    do { info = try await source.objectInfo(handle: handle) }
                    catch is CameraOperationError {
                        // A fully consumed object-level rejection/incomplete dataset is a partial scan,
                        // never evidence that the file was deleted. Transport errors abort publication.
                        info = nil
                    }
                    guard scan.accept(handle: handle, info: info) else { throw CameraStreamError.invalidArgument }
                } else if !scan.publishNext() { break }
            }
            let after = await source.snapshot()
            try Task.checkCancellation()
            guard after.phase == .ready, after.connectionID == before.connectionID else { throw CameraStreamError.closed }
            var files: [CameraFileInfo] = []
            var infos: [Int32: PtpObjectInfo] = [:]
            for index in 0..<Int(scan.rowCount) {
                guard let file = scan.fileAt(index: Int32(index)) else { throw CameraStreamError.invalidArgument }
                files.append(file)
                if let info = scan.objectInfo(handle: file.handle) { infos[file.handle] = info }
            }
            let result = CameraCatalogSnapshot(connectionID: source.connectionID, revision: before.eventRevision,
                storageIDs: (0..<Int(scan.storageCount)).map { scan.storageId(index: Int32($0)) },
                files: files, objectInfos: infos, totalHandles: Int(scan.totalHandles),
                metadataComplete: scan.metadataComplete, changedWhileScanning: before.eventRevision != after.eventRevision)
            // Keep old complete rows on partial metadata failure; return the partial attempt explicitly
            // for diagnostics. A future incremental reconciler may merge it, never infer missing=deleted.
            if result.metadataComplete { latest = result }
            if let fillScan { _ = await previews?.finishCatalogScan(fillScan, snapshot: result) }
            return result
        } catch {
            if let fillScan { _ = await previews?.finishCatalogScan(fillScan, snapshot: nil) }
            throw error
        }
    }

    private static func native(_ values: [Int32]) -> KotlinIntArray {
        let array = KotlinIntArray(size: Int32(values.count))
        for (index, value) in values.enumerated() { array.set(index: Int32(index), value: value) }
        return array
    }
}
