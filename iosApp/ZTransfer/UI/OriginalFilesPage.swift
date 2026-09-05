import Foundation
import SwiftUI
import UIKit
import ZTransferShared

/// A page adapter, not another camera/queue owner. The diagnostic/session owner forwards its ONE queue observer.
@MainActor
final class OriginalFilesPageBridge: NSObject, ObservableObject, Identifiable, NativeFilesPagePlatform, NativePreviewReadPlatform {
    let id = UUID()
    let queuePage: OriginalQueuePageBridge
    private let connectionID: UUID
    private let catalog: CameraCatalog
    private let queue: CameraOriginalQueue
    private let previews: CameraPreviewStore
    private let exifSource: CameraExifSource
    private let exifCache: NativePreviewExifCache
    private let decoder = PreviewImageDecoder()
    private let preferences: BrowsePreferencesStore
    private var refreshTask: Task<Void, Never>?
    private var originalIndexTask: Task<Void, Never>?
    private var needsOriginalUpdate = false
    private var needsOriginalRescan = false
    private var originalRevision: Int64 = -1
    private var completedOriginalRevision: UInt64?
    private var commands: [UUID: Task<Void, Never>] = [:]
    private var images: [UUID: Task<Void, Never>] = [:]
    private var previewRequests: [String: Task<Void, Never>] = [:]
    private var previewPriorities: [String: Task<UUID?, Never>] = [:]
    private var previewUse: (session: Int64, task: Task<UUID, Never>)?
    private var lastPreviewSession: Int64 = 0
    private var filesByHandle: [Int32: CameraFileInfo] = [:]
    private var infosByHandle: [Int32: PtpObjectInfo] = [:]
    private var scanSequence: Int64 = 0
    private var connected = false
    private var closed = false
    private(set) lazy var model = NativeFilesPageModel(connectionId: connectionID.uuidString, queue: queuePage.model, platform: self)

    init(connectionID: UUID, catalog: CameraCatalog, queue: CameraOriginalQueue, previews: CameraPreviewStore,
         exifSource: CameraExifSource, exifCache: NativePreviewExifCache, stationMode: Bool,
         preferences: BrowsePreferencesStore? = nil) {
        self.connectionID = connectionID; self.catalog = catalog; self.queue = queue; self.previews = previews
        self.exifSource = exifSource; self.exifCache = exifCache
        self.preferences = preferences ?? BrowsePreferencesStore()
        queuePage = OriginalQueuePageBridge(connectionID: connectionID, queue: queue, previews: previews, stationMode: stationMode)
        super.init()
        precondition(model.attachPreviewReads(platform: self))
    }

    func publishQueue(_ value: OriginalQueueSnapshot) {
        guard !closed, value.connectionID == connectionID else { return }
        queuePage.publish(value)
        if completedOriginalRevision == nil || value.completedOriginalRevision > completedOriginalRevision! {
            completedOriginalRevision = value.completedOriginalRevision
            refreshOriginals(rescan: originalRevision < 0)
        }
    }
    func setConnected(_ value: Bool) { if !closed { connected = value; queuePage.setConnected(value) } }
    func readBrowsePreferences() -> NativeBrowsePreferences? {
        guard !closed else { return nil }
        let value = preferences.read()
        relayPriority(value ?? NativeBrowsePreferences.companion.defaults())
        return value
    }
    func saveBrowsePreferences(value: NativeBrowsePreferences) -> Bool {
        guard !closed else { return false }
        relayPriority(value) // A failed disk save does not revoke the current page's actual date selection.
        return preferences.save(value)
    }
    private func relayPriority(_ value: NativeBrowsePreferences) {
        let first = value.startDay, last = value.endDay
        let revision = BrowsePreferencesStore.nextUpdateRevision()
        let previews = previews
        Task { await previews.setPriorityRange(startDay: first, endDay: last, revision: revision) }
    }
    func currentDayKey() -> Int32 { Self.localDayKey(at: Date(), timeZone: .current) }
    nonisolated static func localDayKey(at date: Date, timeZone: TimeZone) -> Int32 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = day.year, (1...9999).contains(year), let month = day.month, let date = day.day else { return 0 }
        return Int32(year * 10000 + month * 100 + date)
    }

    func refresh() {
        guard !closed, connected, refreshTask == nil else { return }
        let sequence = model.beginScan()
        guard sequence > 0 else { return }
        refreshOriginals(rescan: true)
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.refreshTask = nil }
            do {
                let snapshot = try await self.catalog.refresh()
                guard !self.closed, !Task.isCancelled else { return }
                _ = self.acceptCatalog(snapshot, sequence: sequence)
            } catch {
                guard !self.closed else { return }
                _ = self.model.finishScan(sequence: sequence, snapshot: nil)
            }
        }
    }

    /// Low-frequency completed-file revisions only. Never enumerates disk for 200 ms progress samples.
    private func refreshOriginals(rescan: Bool) {
        guard !closed else { return }
        needsOriginalUpdate = true
        needsOriginalRescan = needsOriginalRescan || rescan
        guard originalIndexTask == nil else { return }
        model.beginOriginalsRefresh()
        originalIndexTask = Task { [weak self] in
            guard let self else { return }
            defer { self.originalIndexTask = nil }
            while self.needsOriginalUpdate && !self.closed && !Task.isCancelled {
                let rescan = self.needsOriginalRescan
                self.needsOriginalUpdate = false; self.needsOriginalRescan = false
                do {
                    let result = try await self.queue.originals(since: self.originalRevision, rescan: rescan)
                    guard !self.closed, !Task.isCancelled else { return }
                    let update = NativeOriginalIndexUpdate(revision: result.revision,
                        baseRevision: result.baseRevision, fullSnapshot: result.fullSnapshot)
                    for row in result.entries {
                        if !update.add(name: row.name, size: row.size, folder: row.folder, locator: row.url.absoluteString) { break }
                    }
                    guard self.model.publishOriginals(update: update) else {
                        self.model.originalsRefreshFailed(); return
                    }
                    self.originalRevision = result.revision
                } catch {
                    guard !self.closed, !Task.isCancelled else { return }
                    self.model.originalsRefreshFailed()
                    // No automatic retry loop on a broken directory. Manual refresh retries a full scan.
                    self.needsOriginalUpdate = false; self.needsOriginalRescan = false
                }
            }
        }
    }

    @discardableResult
    func acceptCatalog(_ value: CameraCatalogSnapshot, sequence: Int64) -> Bool {
        guard !closed else { return false }
        let snapshot = NativeFilesPageSnapshot(connectionId: value.connectionID.uuidString,
            metadataComplete: value.metadataComplete, changedWhileScanning: value.changedWhileScanning)
        let cameraStores = KotlinIntArray(size: Int32(value.storageIDs.count))
        for (index, store) in value.storageIDs.enumerated() { cameraStores.set(index: Int32(index), value: store) }
        snapshot.setStorageIds(values: cameraStores) // Include empty cards, not just stores represented by a photo.
        for file in value.files {
            let storageIDs = file.storageIds.map { $0.int32Value }
            let stores = KotlinIntArray(size: Int32(storageIDs.count))
            for (index, store) in storageIDs.enumerated() { stores.set(index: Int32(index), value: store) }
            if !snapshot.addFile(handle: file.handle, size: file.size, name: file.fileName, captureDate: file.captureDate,
                isProtected: file.isProtected, storageIds: stores) { break }
        }
        guard model.finishScan(sequence: sequence, snapshot: snapshot) else { return false }
        scanSequence = sequence
        filesByHandle = Dictionary(uniqueKeysWithValues: value.files.map { ($0.handle, $0) })
        infosByHandle = value.objectInfos
        return true
    }

    func enqueue(handles: KotlinIntArray, scanSequence: Int64, completion: NativeFilesEnqueueCompletion) {
        guard !closed, connected, self.scanSequence == scanSequence, commands.isEmpty else {
            completion.complete(acceptedCount: 0); return
        }
        let selected = (0..<Int(handles.size)).map { handles.get(index: Int32($0)) }
        let files = selected.compactMap { filesByHandle[$0] }
        let infos = selected.compactMap { infosByHandle[$0] }
        guard !selected.isEmpty, Set(selected).count == selected.count,
              files.count == selected.count, infos.count == selected.count else { completion.complete(acceptedCount: 0); return }
        let token = UUID()
        commands[token] = Task { [weak self] in
            guard let self else { completion.complete(acceptedCount: 0); return }
            var accepted: Int32 = 0
            defer { self.commands.removeValue(forKey: token); completion.complete(acceptedCount: accepted) }
            guard !self.closed, !Task.isCancelled, self.connected else { return }
            // Android defaults: no date subdirectory, no deferred start. Preference persistence is a later task.
            accepted = Int32(await self.queue.enqueueCatalog(infos, files: files, byDate: false, dayKey: 0, deferred: false))
            let snapshot = await self.queue.snapshot()
            guard !self.closed, !Task.isCancelled else { return }
            self.queuePage.publish(snapshot) // Real post-operation state before acknowledgement.
        }
    }

    func thumbnail(file: CameraFileInfo, allowRemote: Bool, completion: NativeFilesThumbnailCompletion) {
        guard !closed, (!allowRemote || connected), let info = infosByHandle[file.handle],
              info.fileName == file.fileName, info.size == file.size, info.captureDate == file.captureDate else {
            completion.complete(encodedImage: nil, retryable: false); return
        }
        guard images.count < 32 else { completion.complete(encodedImage: nil, retryable: true); return }
        let token = UUID()
        images[token] = Task { [weak self] in
            guard let self else { completion.complete(encodedImage: nil, retryable: false); return }
            defer { self.images.removeValue(forKey: token) }
            do {
                guard !Task.isCancelled, let data = try await self.previews.thumbnail(info: info, allowRemote: allowRemote) else {
                    completion.complete(encodedImage: nil, retryable: false); return
                }
                let png = try await self.decoder.gridThumbnailPNG(data)
                guard !self.closed, !Task.isCancelled, self.filesByHandle[file.handle] == file else {
                    completion.complete(encodedImage: nil, retryable: false); return
                }
                let bytes = KotlinByteArray(size: Int32(png.count))
                for (index, value) in png.enumerated() { bytes.set(index: Int32(index), value: Int8(bitPattern: value)) }
                completion.complete(encodedImage: bytes, retryable: false)
            } catch { completion.complete(encodedImage: nil, retryable: allowRemote && !self.closed && !Task.isCancelled) }
        }
    }

    func beginPreviewReads(sessionId: Int64) {
        guard !closed, sessionId > lastPreviewSession else { return }
        if let previous = previewUse { endPreviewReads(sessionId: previous.session) }
        lastPreviewSession = sessionId
        let previews = previews
        previewUse = (sessionId, Task { await previews.beginForegroundUse() })
    }

    func beginPreviewPriority(sessionId: Int64, requestId: Int64, completion: NativePreviewPriorityCompletion) {
        let key = "\(sessionId):\(requestId)"
        guard !closed, connected, requestId > 0, previewUse?.session == sessionId,
              previewPriorities[key] == nil, previewPriorities.count < 32 else {
            completion.complete(granted: false); return
        }
        let source = exifSource
        previewPriorities[key] = Task { [weak self] in
            do {
                let token = try await source.beginInteractivePreview()
                guard let self, !self.closed, self.connected, !Task.isCancelled,
                      self.previewUse?.session == sessionId else {
                    await source.endInteractivePreview(token)
                    completion.complete(granted: false); return nil
                }
                completion.complete(granted: true)
                return token
            } catch { completion.complete(granted: false); return nil }
        }
    }

    func endPreviewPriority(sessionId: Int64, requestId: Int64) {
        endPreviewPriority(key: "\(sessionId):\(requestId)")
    }

    private func endPreviewPriority(key: String) {
        guard let task = previewPriorities.removeValue(forKey: key) else { return }
        task.cancel()
        let source = exifSource
        // Also release a token whose acquisition completed after cancellation or page replacement.
        Task { if let token = await task.value { await source.endInteractivePreview(token) } }
    }

    func readFhdPreview(sessionId: Int64, requestId: Int64, file: CameraFileInfo, completion: NativeFhdPreviewCompletion) {
        let key = "\(sessionId):\(requestId)"
        guard !closed, connected, requestId > 0, previewUse?.session == sessionId,
              previewRequests[key] == nil, previewRequests.count < 32,
              let use = previewUse, let info = infosByHandle[file.handle],
              filesByHandle[file.handle] == file else { completion.complete(image: nil); return }
        previewRequests[key] = Task { [weak self] in
            guard let self else { completion.complete(image: nil); return }
            defer { self.previewRequests.removeValue(forKey: key) }
            do {
                _ = await use.task.value // Whole-overlay background-fill suppression precedes its first request.
                try Task.checkCancellation()
                guard !self.closed, self.connected, self.previewUse?.session == sessionId,
                      let data = try await self.previews.fhd(info: info) else { completion.complete(image: nil); return }
                let png = try await self.decoder.fhdPreviewPNG(data)
                try Task.checkCancellation()
                guard !self.closed, self.connected, self.previewUse?.session == sessionId,
                      self.filesByHandle[file.handle] == file else { completion.complete(image: nil); return }
                completion.complete(image: NativePreviewImageBridge.shared.fhdPng(data: png as NSData))
            } catch { completion.complete(image: nil) }
        }
    }

    func cancelPreviewRead(sessionId: Int64, requestId: Int64) {
        endPreviewPriority(sessionId: sessionId, requestId: requestId)
        previewRequests["\(sessionId):\(requestId)"]?.cancel()
        // Keep the slot until the task finishes; a shared in-flight frame is drained, not cancelled globally.
    }

    func readLocalBitmap(sessionId: Int64, requestId: Int64, source: String, completion: NativeLocalPreviewCompletion) {
        readLocalPreview(sessionId: sessionId, requestId: requestId, source: source, embeddedRaw: false, completion: completion)
    }

    func readLocalRaw(sessionId: Int64, requestId: Int64, source: String, completion: NativeLocalPreviewCompletion) {
        readLocalPreview(sessionId: sessionId, requestId: requestId, source: source, embeddedRaw: true, completion: completion)
    }

    private func readLocalPreview(sessionId: Int64, requestId: Int64, source: String,
                                  embeddedRaw: Bool, completion: NativeLocalPreviewCompletion) {
        let key = "\(sessionId):\(requestId)"
        guard !closed, requestId > 0, previewUse?.session == sessionId,
              previewRequests[key] == nil, previewRequests.count < 32 else { completion.complete(image: nil); return }
        // Local originals remain readable offline. The shared opening snapshot authorizes the locator;
        // the existing file owner independently verifies its indexed URL and current filesystem entry.
        previewRequests[key] = Task { [weak self] in
            guard let self else { completion.complete(image: nil); return }
            defer { self.previewRequests.removeValue(forKey: key) }
            do {
                try Task.checkCancellation()
                let data: Data?
                if embeddedRaw { data = try await self.queue.originalRawPreviewData(locator: source) }
                else { data = try await self.queue.originalData(locator: source) }
                guard let data else { completion.complete(image: nil); return }
                try Task.checkCancellation()
                let png = try await self.decoder.originalBitmapPNG(data)
                try Task.checkCancellation()
                guard !self.closed, self.previewUse?.session == sessionId else { completion.complete(image: nil); return }
                completion.complete(image: NativePreviewImageBridge.shared.localPng(data: png as NSData))
            } catch { completion.complete(image: nil) }
        }
    }

    func readExif(sessionId: Int64, requestId: Int64, file: CameraFileInfo, completion: NativePreviewExifCompletion) {
        let key = "\(sessionId):\(requestId)"
        guard !closed, requestId > 0, previewUse?.session == sessionId,
              filesByHandle[file.handle] == file, previewRequests[key] == nil, previewRequests.count < 32 else {
            completion.complete(exif: nil); return
        }
        if let cached = exifCache.cached(file: file) { completion.complete(exif: cached.value); return }
        let maximum = NativePreviewExifPolicy.shared.headerBytes(file: file)
        if maximum == 0 { exifCache.remember(file: file, exif: nil); completion.complete(exif: nil); return }
        // An unavailable camera is not a failed attempt, and must not poison the stable key.
        guard connected, let use = previewUse else { completion.complete(exif: nil); return }
        previewRequests[key] = Task { [weak self] in
            guard let self else { completion.complete(exif: nil); return }
            defer { self.previewRequests.removeValue(forKey: key) }
            do {
                _ = await use.task.value
                try Task.checkCancellation()
                guard !self.closed, self.connected, self.previewUse?.session == sessionId,
                      self.filesByHandle[file.handle] == file else { completion.complete(exif: nil); return }
                let data = try await self.exifSource.exifHeader(handle: file.handle, maximumBytes: maximum)
                try Task.checkCancellation()
                let exif: PhotoExif?
                if let data { exif = try await self.decoder.exifMetadata(data) } else { exif = nil }
                try Task.checkCancellation()
                guard !self.closed, self.previewUse?.session == sessionId,
                      self.filesByHandle[file.handle] == file else { completion.complete(exif: nil); return }
                self.exifCache.remember(file: file, exif: exif)
                completion.complete(exif: exif)
            } catch {
                if !Task.isCancelled, !(error is CancellationError), !self.closed,
                   self.previewUse?.session == sessionId, self.filesByHandle[file.handle] == file {
                    self.exifCache.remember(file: file, exif: nil)
                }
                completion.complete(exif: nil)
            }
        }
    }

    func readLocalExif(sessionId: Int64, requestId: Int64, file: CameraFileInfo, source: String, completion: NativePreviewExifCompletion) {
        let key = "\(sessionId):\(requestId)"
        guard !closed, requestId > 0, previewUse?.session == sessionId,
              previewRequests[key] == nil, previewRequests.count < 32 else { completion.complete(exif: nil); return }
        if let cached = exifCache.cached(file: file) { completion.complete(exif: cached.value); return }
        if NativePreviewExifPolicy.shared.headerBytes(file: file) == 0 {
            exifCache.remember(file: file, exif: nil); completion.complete(exif: nil); return
        }
        previewRequests[key] = Task { [weak self] in
            guard let self else { completion.complete(exif: nil); return }
            defer { self.previewRequests.removeValue(forKey: key) }
            do {
                try Task.checkCancellation()
                let exif = try await self.queue.originalExif(locator: source)
                try Task.checkCancellation()
                guard !self.closed, self.previewUse?.session == sessionId else { completion.complete(exif: nil); return }
                self.exifCache.remember(file: file, exif: exif)
                completion.complete(exif: exif)
            } catch {
                if !Task.isCancelled, !(error is CancellationError), !self.closed, self.previewUse?.session == sessionId {
                    self.exifCache.remember(file: file, exif: nil)
                }
                completion.complete(exif: nil)
            }
        }
    }

    func endPreviewReads(sessionId: Int64) {
        for key in Array(previewPriorities.keys) where key.hasPrefix("\(sessionId):") { endPreviewPriority(key: key) }
        for (key, request) in previewRequests where key.hasPrefix("\(sessionId):") { request.cancel() }
        guard let use = previewUse, use.session == sessionId else { return }
        previewUse = nil
        let previews = previews
        Task { let token = await use.task.value; await previews.endForegroundUse(token) }
    }

    func cancelRequests() {
        guard !closed else { return }
        closed = true; refreshTask?.cancel(); refreshTask = nil
        if let use = previewUse { endPreviewReads(sessionId: use.session) }
        previewRequests.values.forEach { $0.cancel() }
        originalIndexTask?.cancel(); originalIndexTask = nil
        needsOriginalUpdate = false; needsOriginalRescan = false
        commands.values.forEach { $0.cancel() }; commands.removeAll()
        images.values.forEach { $0.cancel() }; images.removeAll()
        filesByHandle.removeAll(); infosByHandle.removeAll()
    }
    func close() { model.close() }
}

struct OriginalFilesPage: UIViewControllerRepresentable {
    let bridge: OriginalFilesPageBridge
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> OriginalFilesPageBridge { bridge }
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = SharedUiController.shared.originalFiles(model: bridge.model,
            languageTag: Locale.preferredLanguages.first ?? "en", onBack: {
                bridge.close(); dismiss(); return KotlinUnit()
            })
        bridge.queuePage.presenter = controller
        return controller
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: UIViewController, coordinator: OriginalFilesPageBridge) { coordinator.close() }
}
