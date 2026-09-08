import Foundation
import SwiftUI
import UIKit
import ZTransferShared

private actor APProbeLifetime {
    private var closing = false
    func beginClosing() { closing = true }
    func isClosing() -> Bool { closing }
}

#if DEBUG
private struct ProbeDocumentRequest: Identifiable {
    let id = UUID()
    let purpose: SystemDocumentPicker.Purpose
}
#endif

struct CameraProductSessionState: Equatable {
    let requestID: Int64
    let phase: String
    let message: String?
}

/// Sole AP/STA session owner, reused by the shared product home and DEBUG diagnostic controls.
/// The historical name is retained to avoid cloning or moving the camera/queue workflow.
@MainActor
final class CameraHandshakeProbe: ObservableObject {
    @Published private(set) var productState: CameraProductSessionState?
    @Published private(set) var sessionReady = false
    @Published private(set) var status = "先在系统设置中加入相机热点或相机所在的 Wi-Fi。"
    @Published private(set) var running = false
    @Published private(set) var samples: [String] = []
    @Published private(set) var downloading = false
    @Published private(set) var downloadStatus = ""
    @Published private(set) var savedURL: URL?
    private var savedOriginal: SavedCameraFile?
    private var savedCaptureDate: String?
    @Published private(set) var importingPhoto = false
    @Published private(set) var photoImportStatus = ""
    private let photoImporter = PhotoLibraryImporter()
    private var photoImportTask: Task<Void, Never>?
    private var sampleObjects: [PtpObjectInfo] = []
    private var downloadTask: Task<Void, Never>?
    private var downloadAttempt: UUID?
    @Published private(set) var queueSnapshot: OriginalQueueSnapshot?
    @Published var queuePage: OriginalQueuePageBridge?
    @Published var filesPage: OriginalFilesPageBridge?
    private var workspaceNavigation: UInt64 = 0
    var canOpenSharedWorkspace: Bool {
        running && sessionReady && !downloading && originalQueue != nil && apConnection != nil && previewStore != nil && catalog != nil
    }
    private var originalQueue: CameraOriginalQueue?
    private var queueObserver: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var closingTask: Task<Void, Never>?
    private var apConnection: CameraWiFiConnection?
    private var catalog: CameraCatalog?
    private let transferPreferences = TransferPreferencesStore()
    private var automaticTransfer: CameraAutomaticTransferCoordinator?
    private var catalogTask: Task<Void, Never>?
    @Published private(set) var scanningCatalog = false
    @Published private(set) var catalogStatus = ""
    private var previewStore: CameraPreviewStore?
    private let exifCache = NativePreviewExifCache()
    private let imageDecoder = PreviewImageDecoder()
    private let filterRenderer = PhotoFilterPreviewRenderer()
    private var previewTask: Task<Void, Never>?
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var previewPNG: Data?
    @Published private(set) var previewStatus = ""
    @Published private(set) var loadingPreview = false
    private var discovery: CameraBonjourDiscovery?
    private var discoveryTask: Task<Void, Never>?
    @Published private(set) var discoverySnapshot: CameraBonjourSnapshot?
    @Published private(set) var directoryStatus = ""
    @Published private(set) var directoryBusy = false
    @Published private(set) var exportStatus = ""
    private var directoryTask: Task<Void, Never>?
    private var queueShareTask: Task<Void, Never>?
    private var providerOriginals: ProviderOriginalStore?
    private var transferDestination: OriginalFilesDestination?
    private let destinationPreferences = OriginalDestinationPreferences()
    @Published private(set) var queueDestinationError: String?
    @Published private(set) var savesToSelectedDirectory = false
    var queueDestinationSummary: String {
        if let queueDestinationError { return queueDestinationError }
        return savesToSelectedDirectory
            ? "队列：所选目录。副本校验发布后才完成，应用内原片保留。"
            : "队列：应用沙盒。选择目录授权本身不会改变保存目标。"
    }
    @Published private(set) var metadataStatus = ""
    @Published private(set) var readingMetadata = false
    private let metadataReader = PhotoMetadataReader()
    private var metadataTask: Task<Void, Never>?

    func inspectSavedMetadata() {
        guard !readingMetadata, let url = savedURL else { return }
        readingMetadata = true
        metadataTask = Task {
            defer { readingMetadata = false; metadataTask = nil }
            do {
                let metadata = try await metadataReader.read(url)
                try Task.checkCancellation()
                guard savedURL == url else { return }
                let items = [metadata.make, metadata.model, metadata.aperture, metadata.shutter,
                             metadata.iso, metadata.focalLength, metadata.lensModel, metadata.dateTime].compactMap { $0 }
                metadataStatus = items.isEmpty ? "未读到相框可用的照片元数据。" : items.joined(separator: " · ")
                // Coordinates may exist in EXIF, but are deliberately not echoed in diagnostics.
            } catch {
                if !Task.isCancelled && savedURL == url { metadataStatus = "元数据读取失败：\(error)" }
            }
        }
    }

    func useDirectory(_ selection: URL? = nil, forget: Bool = false) {
        guard !directoryBusy else { return }
        if let selection, !forget, transferDestination != nil {
            selectQueueDirectory(selection)
            return
        }
        guard transferDestination == nil || (selection == nil && !forget) else {
            directoryStatus = "请等当前队列结束并切回应用沙盒，再改选或忘记目录授权；不会改写在途任务的目录。"
            return
        }
        filesPage?.close(); filesPage = nil // No frozen preview/index survives a grant change or refresh.
        directoryBusy = true
        directoryTask = Task {
            defer { directoryBusy = false; directoryTask = nil }
            do {
                if let transferDestination {
                    try await transferDestination.validateSelection() // A bound destination check must not refresh its bookmark.
                    directoryStatus = "当前保存目录授权有效；队列会在副本校验发布后才完成任务。"
                    return
                }
                let store = try ScopedDirectoryStore.applicationStore()
                if forget {
                    try await store.forget()
                    providerOriginals = nil
                    directoryStatus = "已忘记应用保存的目录授权；未删除外部目录或任何文件。"
                } else {
                    if let selection { try await store.select(selection) }
                    let name = try await store.displayName()
                    providerOriginals = nil // A select/stale-bookmark refresh establishes a new binding.
                    directoryStatus = "目录授权可用：\(name)。当前下载仍先存沙盒；选择目录不代表已把传输写入该位置。"
                }
            } catch { directoryStatus = error.localizedDescription }
        }
    }

    /// Prepare without invalidating the current grant, then commit behind the queue's execution fence.
    func selectQueueDirectory(_ selection: URL, completion: ((String?) -> Void)? = nil) {
        guard !directoryBusy, let queue = originalQueue else {
            completion?("目录操作尚未结束或连接已关闭，请稍后重试。")
            return
        }
        directoryBusy = true
        directoryTask = Task {
            var outcome: String?
            defer { directoryBusy = false; directoryTask = nil; completion?(outcome) }
            do {
                let directory = try ScopedDirectoryStore.applicationStore()
                let change = try await ProviderDirectoryChange.prepare(selection, directory: directory)
                guard try await queue.configureDestination(change) else {
                    directoryStatus = "当前队列仍在执行，请完成当前并暂停后重选；目录授权和保存目标均未改变。"
                    outcome = directoryStatus
                    return
                }
                // Commit returned successfully. Cancellation afterwards cannot undo that fact.
                let remembered = destinationPreferences.save(.provider)
                guard originalQueue === queue else { return }
                providerOriginals = change.provider; transferDestination = change.provider
                queueDestinationError = nil
                savesToSelectedDirectory = true
                workspaceNavigation &+= 1
                filesPage?.close(); filesPage = nil
                directoryStatus = "已切换到 \(change.displayName)；原目录文件保留，后续执行使用新目标。"
                    + (remembered ? "" : " 本次目标已生效，但偏好保存失败；下次连接可能需重选。")
            } catch {
                outcome = "保存目标未改变：\(error.localizedDescription)"
                if !Task.isCancelled, originalQueue === queue {
                    directoryStatus = "保存目标未改变：\(error.localizedDescription)"
                }
            }
        }
    }

    private func providerStore() throws -> ProviderOriginalStore {
        if let providerOriginals { return providerOriginals }
        let value = ProviderOriginalStore(directory: try ScopedDirectoryStore.applicationStore())
        providerOriginals = value
        return value
    }

    func inspectProviderOriginals() {
        guard !directoryBusy else { return }
        directoryBusy = true
        directoryTask = Task {
            defer { directoryBusy = false; directoryTask = nil }
            do {
                let snapshot = try await providerStore().originals(since: -1, rescan: true)
                let dated = snapshot.entries.filter { $0.folder != nil }.count
                directoryStatus = "目标目录索引：\(snapshot.entries.count) 个原片条目，其中日期目录 \(dated) 个；仅检查名称与大小，尚未接入共享文件页。"
            } catch { directoryStatus = Task.isCancelled ? "目录索引检查已取消；旧索引保留。" : error.localizedDescription }
        }
    }

    /// Actual provider publication probe; queue targets and shared-page indexes are still separate work.
    func publishSavedToDirectory(byDate: Bool) {
        guard !directoryBusy, let saved = savedOriginal, saved.url == savedURL else { return }
        let folder = PtpTransferBridge.shared.destinationFolder(captureDate: savedCaptureDate, byDate: byDate,
            dayKey: OriginalFilesPageBridge.localDayKey(at: Date(), timeZone: .current))
        directoryBusy = true
        directoryStatus = "正在向已选目录写入校验副本…"
        directoryTask = Task {
            defer { directoryBusy = false; directoryTask = nil }
            do {
                let result = try await providerStore().publish(saved, folder: folder)
                directoryStatus = "已写入 \(result.url.lastPathComponent)，\(result.bytes) 字节，校验一致；应用内原片保留。云端同步由文件服务处理。"
            } catch {
                directoryStatus = Task.isCancelled ? "已取消外部目录写入；应用内原片保留。" : error.localizedDescription
            }
        }
    }

    func exported(_ urls: [URL]?) {
        exportStatus = urls?.first.map { "系统已返回导出文件：\($0.lastPathComponent)。应用内原片保留；云端同步由文件服务管理。" }
            ?? "已取消系统导出；应用内原片保留。"
    }

    func discover() {
        guard !running else { return }
        discovery?.stop(); discoveryTask?.cancel()
        let browser = CameraBonjourDiscovery()
        discovery = browser
        discoveryTask = Task {
            for await snapshot in browser.updates {
                if Task.isCancelled { break }
                discoverySnapshot = snapshot
            }
        }
        browser.start()
    }

    func stopDiscovery() {
        discovery?.stop(); discoveryTask?.cancel(); discoveryTask = nil; discovery = nil
        if let snapshot = discoverySnapshot {
            discoverySnapshot = CameraBonjourSnapshot(services: snapshot.services, searching: false, message: snapshot.message)
        }
    }

    @discardableResult
    func connectProduct(host: String, stationMode: Bool, allowPairing: Bool, requestID: Int64,
                        expectedResponder: String? = nil, service: CameraBonjourService? = nil) -> Bool {
        guard requestID > 0, !running, !downloading, !directoryBusy, closingTask == nil else { return false }
        guard service != nil || NativeCameraEndpointAddress.shared.normalize(raw: host) != nil else { return false }
        start(host: host, stationMode: stationMode, persistentAP: true, allowPairing: allowPairing,
              expectedResponder: expectedResponder, service: service, productRequestID: requestID)
        return running
    }

    private func publishProduct(_ phase: String, message: String? = nil) {
        guard let current = productState else { return }
        if current.phase == "closing" && phase == "ready" { return }
        productState = CameraProductSessionState(requestID: current.requestID, phase: phase, message: message)
    }

    func start(host: String, stationMode: Bool, persistentAP: Bool = false,
               allowPairing: Bool = false, forcePairing: Bool = false, expectedResponder: String? = nil,
               service: CameraBonjourService? = nil, productRequestID: Int64? = nil) {
        guard !running, !downloading, !directoryBusy else { return }
        stopDiscovery()
        running = true
        sessionReady = false
        productState = productRequestID.map { CameraProductSessionState(requestID: $0, phase: "connecting", message: nil) }
        samples = []
        sampleObjects = []
        downloadStatus = ""
        savedURL = nil; savedOriginal = nil; savedCaptureDate = nil
        metadataStatus = ""; metadataTask?.cancel()
        queueSnapshot = nil
        status = "正在检查命令与事件通道…"
        task = Task {
            defer {
                running = false; task = nil; sessionReady = false
                if productState?.phase != "failed" && productState?.phase != "paired" { publishProduct("idle") }
            }
            do {
                let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                if persistentAP || service != nil {
                    try await inspectPersistentConnection(host: address, stationMode: stationMode,
                                                           allowPairing: allowPairing, forcePairing: forcePairing,
                                                           expectedResponder: expectedResponder, service: service)
                    return
                }
                let port = UInt16(PtpConstants.shared.PTP_PORT)
                let command = try CameraTCPStream(host: address, port: port)
                defer { command.close() }
                let event = try CameraTCPStream(host: address, port: port)
                defer { event.close() }
                let commandChannel = PtpIPChannel(stream: command)
                let eventChannel = PtpIPChannel(stream: event)
                // Persist the diagnostic identity: retrying must not invent a different PC identity.
                // Product profile selection/pairing is tracked separately in IOS-N03/N04.
                let guid = Self.probeIdentity()
                try await command.connect(timeout: 15)
                try await commandChannel.sendCommandHandshake(
                    guid: guid, name: stationMode ? "ZTransfer" : "NikonPTP", standard: stationMode, timeout: 15
                )
                let response = try await commandChannel.readControlPacket(timeout: 15)
                let ack = try await commandChannel.commandAcknowledgement(response)
                try await event.connect(timeout: 15)
                try await eventChannel.sendEventHandshake(connectionNumber: ack.connectionNumber, timeout: 15)
                let eventResponse = try await eventChannel.readControlPacket(timeout: 15)
                guard eventResponse.type == PtpConstants.shared.INIT_EVT_ACK else {
                    throw PtpIPChannelError.unexpectedPacket(eventResponse.type)
                }
                try Task.checkCancellation()
                if stationMode {
                    status = "STA 命令与事件通道握手通过，连接号 \(ack.connectionNumber)。已关闭诊断连接；配对、会话激活和照片传输尚未验证。"
                } else {
                    status = "AP 双通道握手通过，正在打开会话并读取相机信息…"
                    let session = PtpIPCommandSession(stream: command, initialTransactionId: 0)
                    do {
                        let description = try await Self.inspectAPSession(
                            session, eventChannel: eventChannel, connectionNumber: ack.connectionNumber
                        )
                        await session.close()
                        try Task.checkCancellation()
                        status = description
                    } catch {
                        await session.close()
                        throw error
                    }
                }
            } catch {
                status = Task.isCancelled ? "诊断已取消，连接已关闭。" : error.localizedDescription
                if !Task.isCancelled, let station = error as? CameraStationError, case .pairingCompleted = station {
                    publishProduct("paired", message: error.localizedDescription)
                } else {
                    publishProduct(Task.isCancelled ? "idle" : "failed", message: Task.isCancelled ? nil : error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        sessionReady = false
        if running { publishProduct("closing") }
        automaticTransfer?.close()
        filesPage?.close(); filesPage = nil
        queuePage?.close(); queuePage = nil
        stopDiscovery()
        downloadTask?.cancel(); photoImportTask?.cancel(); catalogTask?.cancel()
        directoryTask?.cancel()
        queueShareTask?.cancel()
        metadataTask?.cancel()
        previewTask?.cancel(); queueObserver?.cancel(); task?.cancel()
    }

    func previewSample(_ index: Int) {
        guard running, !loadingPreview, sampleObjects.indices.contains(index),
              let previewStore, let connection = apConnection else { return }
        let info = sampleObjects[index]
        loadingPreview = true
        previewImage = nil; previewPNG = nil
        previewStatus = "正在读取相机预览…"
        previewTask = Task {
            defer { loadingPreview = false; previewTask = nil }
            do {
                guard let data = try await previewStore.preview(info: info) else {
                    previewStatus = "相机当前没有可用预览。"; return
                }
                let image = try await imageDecoder.decode(data)
                let png = try await imageDecoder.singlePhotoPNG(image)
                try Task.checkCancellation()
                guard apConnection?.connectionID == connection.connectionID else { return }
                previewImage = UIImage(cgImage: image)
                previewPNG = png
                previewStatus = "\(info.fileName ?? "相机文件") · \(image.width)×\(image.height)"
            } catch {
                if apConnection?.connectionID == connection.connectionID { previewStatus = error.localizedDescription }
            }
        }
    }

    func previewSavedFilter(index: Int32 = 0) {
        guard !loadingPreview, let url = savedURL,
              let selection = NativePhotoFilterCatalog.shared.selection(index: index, intensityPercent: 80) else { return }
        loadingPreview = true; previewImage = nil; previewPNG = nil
        previewStatus = "正在用共享内核生成滤镜预览；原片不变…"
        previewTask = Task {
            defer { loadingPreview = false; previewTask = nil }
            do {
                let source = try await imageDecoder.decodeFile(url, maximumPixelSize: 2048)
                let filtered = try await filterRenderer.render(source, selection: selection)
                let png = try await imageDecoder.singlePhotoPNG(filtered)
                try Task.checkCancellation()
                guard savedURL == url else { return }
                previewImage = UIImage(cgImage: filtered)
                previewPNG = png
                previewStatus = "\(selection.preset.name) · 80% · 仅预览，未导出成片。"
            } catch {
                if !Task.isCancelled && savedURL == url { previewStatus = "滤镜预览失败：\(error)" }
            }
        }
    }

    func releasePreviewMemory() {
        previewTask?.cancel()
        previewImage = nil; previewPNG = nil
        if let previewStore { Task { await previewStore.clearForMemoryPressure() } }
    }

    func refreshCatalog() {
        guard running, !scanningCatalog, let catalog else { return }
        scanningCatalog = true
        catalogStatus = "正在按共享双卡规则读取完整目录…"
        catalogTask = Task {
            defer { scanningCatalog = false; catalogTask = nil }
            do {
                let result = try await catalog.refresh()
                guard let connection = apConnection, connection.connectionID == result.connectionID else { return }
                catalogStatus = "已扫描 \(result.totalHandles) 个对象，\(result.files.count) 个去重文件。"
                    + (result.metadataComplete ? "元数据读取完整。" : "部分元数据失败；不能用于删除判断。")
                    + (result.changedWhileScanning ? "扫描期间有相机事件，请刷新。" : "")
                // Diagnostic renders at most 20, but the coordinator has enumerated the whole card.
                // Never replace the sample backing array while buttons refer to its old indices.
                if !downloading {
                    sampleObjects = result.files.prefix(20).compactMap { result.objectInfos[$0.handle] }
                    samples = sampleObjects.map { "\($0.fileName ?? "未命名") · \($0.size) 字节" }
                }
            } catch { catalogStatus = error.localizedDescription }
        }
    }

    func saveToPhotos() {
        guard let url = savedURL, !importingPhoto else { return }
        importingPhoto = true
        photoImportStatus = "正在请求图库接收文件…"
        photoImportTask = Task {
            defer { importingPhoto = false; photoImportTask = nil }
            do {
                try await photoImporter.save(url)
                photoImportStatus = "\(url.lastPathComponent) 已加入系统图库，应用内原文件仍保留。"
            } catch {
                photoImportStatus = error is CancellationError ? "已取消尚未提交的图库导入。" : error.localizedDescription
            }
        }
    }

    func disconnect() {
        sessionReady = false
        if running { publishProduct("closing") }
        automaticTransfer?.close()
        queueShareTask?.cancel()
        directoryTask?.cancel()
        downloadTask?.cancel()
        guard let connection = apConnection else { cancel(); return }
        guard closingTask == nil else { return }
        closingTask = Task {
            defer { closingTask = nil }
            await connection.disconnect()
        }
    }

    func canDownload(_ index: Int) -> Bool {
        running && !downloading && queueSnapshot?.running != true &&
        sampleObjects.indices.contains(index) && sampleObjects[index].identityComplete
    }

    func enqueueSample(_ index: Int) {
        guard let queue = originalQueue, sampleObjects.indices.contains(index) else { return }
        let info = sampleObjects[index]
        let transfer = filesPage?.model.currentTransferPreferences()
            ?? transferPreferences.read() ?? NativeTransferPreferences.companion.defaults()
        let dayKey = OriginalFilesPageBridge.localDayKey(at: Date(), timeZone: .current)
        Task { await queue.enqueue(info, byDate: transfer.organizeByDate, dayKey: dayKey, deferred: transfer.deferStart) }
    }
    func openSharedQueue() {
        guard running, !downloading, let queue = originalQueue, let connection = apConnection,
              let previews = previewStore else { return }
        workspaceNavigation &+= 1
        queuePage?.close()
        filesPage?.close(); filesPage = nil
        let page = OriginalQueuePageBridge(connectionID: connection.connectionID, queue: queue, previews: previews, stationMode: connection.stationMode)
        queuePage = page
        Task {
            let snapshot = await queue.snapshot()
            let state = await connection.snapshot()
            guard queuePage === page else { return }
            page.publish(snapshot)
            page.setConnected(state.phase == .ready)
        }
    }
    func startQueue() { if let queue = originalQueue, !downloading { Task { await queue.start() } } }
    func configureQueueDirectory(_ enabled: Bool) {
        guard !directoryBusy, let queue = originalQueue else { return }
        directoryBusy = true
        directoryTask = Task {
            defer { directoryBusy = false; directoryTask = nil }
            do {
                let target: ProviderOriginalStore?
                if enabled { target = try providerStore() } else { target = nil }
                guard try await queue.configureDestination(target) else {
                    directoryStatus = "当前队列仍在执行，请传完当前并暂停后再切换保存目标。"
                    return
                }
                // The configuration is committed. Mirror it even if cancellation arrives just afterwards.
                let remembered = destinationPreferences.save(enabled ? .provider : .sandbox)
                guard originalQueue === queue else { return }
                transferDestination = target; savesToSelectedDirectory = enabled
                queueDestinationError = nil
                workspaceNavigation &+= 1
                filesPage?.close(); filesPage = nil
                directoryStatus = enabled
                    ? "队列已使用所选目录：下载后校验发布才完成，应用内原片保留；已有待传任务使用此目标。"
                    : "队列已切回应用沙盒；所选目录中的已有文件不变。"
                if !remembered { directoryStatus += " 本次目标已生效，但偏好保存失败；下次连接可能需重选。" }
            } catch {
                if !Task.isCancelled { directoryStatus = "保存目标未改变：\(error.localizedDescription)" }
            }
        }
    }

    func openSharedProviderFiles() {
        guard canOpenSharedWorkspace, !scanningCatalog, !directoryBusy, let connection = apConnection else { return }
        let navigation = workspaceNavigation
        directoryBusy = true
        directoryTask = Task {
            defer { directoryBusy = false; directoryTask = nil }
            do {
                let source = try providerStore()
                try await source.validateSelection() // Freeze the grant before publishing a page, without a double scan.
                try Task.checkCancellation()
                guard canOpenSharedWorkspace, !scanningCatalog, workspaceNavigation == navigation,
                      apConnection?.connectionID == connection.connectionID else { return }
                directoryStatus = savesToSelectedDirectory
                    ? "文件页与队列使用同一所选目录；任务在副本校验发布后完成。"
                    : "文件页仅查看所选目录；当前新下载仍写应用沙盒。可先启用队列保存到所选目录。"
                openSharedFiles(originals: source)
            } catch {
                if !Task.isCancelled { directoryStatus = "所选目录无法打开：\(error.localizedDescription)" }
            }
        }
    }
    func openSharedFiles(originals: OriginalFilesReading? = nil) {
        guard running, !downloading, !scanningCatalog, let queue = originalQueue, let connection = apConnection,
              let catalog, let previews = previewStore else { return }
        workspaceNavigation &+= 1
        queuePage?.close(); queuePage = nil
        filesPage?.close()
        let page = OriginalFilesPageBridge(connectionID: connection.connectionID, catalog: catalog,
            queue: queue, previews: previews, exifSource: connection, exifCache: exifCache, stationMode: connection.stationMode,
            originals: originals ?? transferDestination, transferPreferences: transferPreferences,
            directoryDescription: queueDestinationSummary, directoryMessage: queueDestinationError,
            selectDirectory: { [weak self] url, completion in
                guard let self else { completion("连接已关闭，请重新连接后选择目录。"); return }
                self.selectQueueDirectory(url, completion: completion)
            }, automaticTransfer: automaticTransfer,
            automaticTransferTargetAvailable: savesToSelectedDirectory && queueDestinationError == nil)
        filesPage = page
        Task {
            let snapshot = await queue.snapshot()
            let initialCatalog = await catalog.snapshot()
            // Validate AFTER reading the baseline: a newer event revision invalidates its reuse.
            let state = await connection.snapshot()
            guard filesPage === page, apConnection === connection, self.catalog === catalog else { return }
            page.publishQueue(snapshot)
            page.setConnected(state.phase == .ready)
            page.loadInitialCatalog(initialCatalog, state: state)
        }
    }
    func pauseQueue() { if let queue = originalQueue { Task { await queue.pauseAfterCurrent() } } }
    func withdrawQueueTask(_ id: Int64) { if let queue = originalQueue { Task { await queue.withdraw(id) } } }
    func retryQueueTask(_ id: Int64) { if !downloading, let queue = originalQueue { Task { await queue.retry(id) } } }
    func clearQueueHistory() { if let queue = originalQueue { Task { await queue.clearTerminal() } } }
    func shareQueueTask(_ id: Int64) {
        queueShareTask?.cancel()
        if let queue = originalQueue {
            savedURL = nil; savedOriginal = nil; savedCaptureDate = nil
            queueShareTask = Task {
                do {
                    let captureDate = (await queue.snapshot()).rows.first { $0.id == id }?.captureDate
                    guard let saved = try await queue.prepareSavedFile(id), !Task.isCancelled,
                          originalQueue === queue else { return }
                    let state = await queue.snapshot()
                    guard !Task.isCancelled, originalQueue === queue, state.rows.contains(where: { $0.id == id }) else { return }
                    savedURL = saved.url; savedOriginal = saved; savedCaptureDate = captureDate
                } catch {
                    guard !Task.isCancelled, originalQueue === queue else { return }
                    directoryStatus = "准备原片分享失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func downloadSample(_ index: Int) {
        guard canDownload(index), let connection = apConnection, let previews = previewStore else { return }
        let info = sampleObjects[index]
        downloading = true
        let attempt = UUID()
        downloadAttempt = attempt
        savedURL = nil; savedOriginal = nil; savedCaptureDate = nil
        downloadStatus = "正在下载 \(info.fileName ?? "原文件")…"
        downloadTask = Task {
            let foreground = await previews.beginForegroundUse()
            defer { downloading = false; downloadTask = nil; downloadAttempt = nil }
            do {
                let store = try CameraOriginalStore.applicationStore()
                let saved = try await store.download(camera: connection, info: info, byDate: false, dayKey: 0) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.downloadAttempt == attempt, self.savedURL == nil else { return }
                        self.downloadStatus = "已写入 \(progress.downloaded) 字节 / \(progress.total > 0 ? String(progress.total) : "未知总长")，\(progress.bytesPerSecond) B/s"
                    }
                }
                savedURL = saved.url; savedOriginal = saved; savedCaptureDate = info.captureDate
                downloadStatus = "已保存 \(saved.url.lastPathComponent)，\(saved.bytes) 字节。SHA-256：\(saved.sha256)"
            } catch {
                downloadStatus = Task.isCancelled ? "下载已取消；未发布不完整文件。" : error.localizedDescription
            }
            await previews.endForegroundUse(foreground)
        }
    }

    private func inspectPersistentConnection(host: String, stationMode: Bool, allowPairing: Bool,
                                             forcePairing: Bool, expectedResponder: String?, service: CameraBonjourService?) async throws {
        let command: CameraTCPStream
        let event: CameraTCPStream
        if let service {
            command = CameraTCPStream(service: service); event = CameraTCPStream(service: service)
        } else {
            command = try CameraTCPStream(host: host, port: UInt16(PtpConstants.shared.PTP_PORT))
            event = try CameraTCPStream(host: host, port: UInt16(PtpConstants.shared.PTP_PORT))
        }
        let connection = CameraWiFiConnection(command: command, event: event, stationMode: stationMode)
        let previews = CameraPreviewStore(source: connection, connectionID: connection.connectionID)
        directoryBusy = true
        let restored: RestoredOriginalDestination
        do { restored = try await destinationPreferences.restore() }
        catch { directoryBusy = false; throw error }
        directoryBusy = false
        try Task.checkCancellation()
        let queue = CameraOriginalQueue(camera: connection, store: try CameraOriginalStore.applicationStore(), destination: restored.destination)
        providerOriginals = restored.provider; transferDestination = restored.destination
        savesToSelectedDirectory = restored.selected == .provider; queueDestinationError = restored.failure
        directoryStatus = restored.failure ?? (savesToSelectedDirectory ? "已恢复所选目录保存目标。" : "队列使用应用沙盒。")
        originalQueue = queue
        let sessionAutomatic = CameraAutomaticTransferCoordinator(connectionID: connection.connectionID,
            queue: queue, preferences: transferPreferences)
        automaticTransfer = sessionAutomatic
        queueObserver = Task {
            for await snapshot in queue.updates {
                if Task.isCancelled { break }
                await previews.setTransfersBusy(snapshot.running)
                publishQueueSnapshot(snapshot)
            }
        }
        apConnection = connection
        let sessionCatalog = CameraCatalog(source: connection, stationMode: stationMode, previews: previews,
            onAddition: { [weak self] addition in await self?.receiveCatalogAddition(addition) },
            onChange: { [weak self] snapshot in await self?.receiveCatalogChange(snapshot) })
        catalog = sessionCatalog
        previewStore = previews
        defer {
            sessionAutomatic.close(); automaticTransfer = nil
            sessionReady = false
            filesPage?.close(); filesPage = nil
            queuePage?.close(); queuePage = nil
            catalogTask?.cancel(); catalogTask = nil; scanningCatalog = false; catalog = nil
            previewTask?.cancel(); previewStore = nil; previewImage = nil; previewPNG = nil
            apConnection = nil; originalQueue = nil; queueObserver?.cancel(); queueObserver = nil
            transferDestination = nil; savesToSelectedDirectory = false
            queueDestinationError = nil
        }
        do {
            let profiles: StationProfileStore?
            if stationMode { profiles = try StationProfileStore.applicationStore() } else { profiles = nil }
            let options = StationConnectionOptions(expectedResponderGUID: expectedResponder,
                                                    allowPairing: allowPairing, forceProfilePairing: forcePairing)
            let identity = try await connection.connect(guid: profiles?.identity ?? Self.probeIdentity(), stationOptions: options,
                hasPairingMarker: { try profiles?.isPaired($0) ?? false },
                onPairingAcknowledged: { responder in
                    guard let profiles else { throw CameraStationError.missingIdentity }
                    try profiles.markPaired(responder)
                })
            let description = identity.map { "\($0.manufacturer) \($0.model)" } ?? "相机（机型信息不可用）"
            let diskReady: Bool
            if let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
               let key = await connection.thumbnailCacheKey() {
                diskReady = await previews.openDiskCache(root: root.appendingPathComponent("ZTransferThumbs", isDirectory: true),
                                                         cameraIdentity: key)
            } else { diskReady = false }
            let browse = BrowsePreferencesStore().read() ?? NativeBrowsePreferences.companion.defaults()
            await previews.startBackgroundFill(startDay: browse.startDay, endDay: browse.endDay,
                                               revision: BrowsePreferencesStore.nextUpdateRevision())
            var stores: [Int32] = [], handles: [Int32] = []
            if productState == nil {
            stores = try await connection.storageIDs()
            // Raw wildcard diagnostic only, not a replacement for shared dual-card catalog rules.
            handles = try await connection.objectHandles(storageID: -1)
            for handle in handles.prefix(20) {
                try Task.checkCancellation()
                let info = try await connection.objectInfo(handle: handle)
                if !info.isAssociation {
                    let size = info.size == PtpConstants.shared.SIZE_UNKNOWN ? "大小未知" : "\(info.size) 字节"
                    let incomplete = info.identityComplete ? "" : "（元数据不完整）"
                    samples.append("\(info.fileName ?? "未命名") · \(size)\(incomplete)")
                    sampleObjects.append(info)
                }
            }
            }
            let summary = (productState == nil ? "\(description)：原始存储 ID \(stores.count) 个、对象 \(handles.count) 个；仅抽样前 20 个对象，不代表完整照片列表。" : "\(description)：") +
                (diskReady ? "" : "缩略图磁盘缓存不可用，当前仅使用内存缓存。")
            try Task.checkCancellation()
            let readyState = await connection.snapshot()
            guard readyState.phase == .ready, productState?.phase != "closing" else { throw CameraStreamError.closed }
            var readyMessage = description
            if productState != nil {
                let responder = await connection.responderGUID()
                let resolvedHost = await connection.resolvedRemoteHost()
                let historyState = await connection.snapshot()
                try Task.checkCancellation()
                guard historyState.phase == .ready, apConnection === connection,
                      productState?.phase != "closing" else { throw CameraStreamError.closed }
                do {
                    try Self.recordVerifiedStationEndpoint(stationMode: stationMode, service: service, host: host,
                        responderGUID: responder, displayName: description, resolvedHost: resolvedHost,
                        history: CameraEndpointHistory.applicationStore)
                } catch {
                    readyMessage += "（地址历史未保存：\(error.localizedDescription)）"
                }
            }
            try Task.checkCancellation()
            let finalReadyState = await connection.snapshot()
            guard finalReadyState.phase == .ready, productState?.phase != "closing" else { throw CameraStreamError.closed }
            sessionReady = true
            publishProduct("ready", message: readyMessage)
            status = summary + "连接保持中。"
            // This owner existed before connect; revision zero includes opening events still retained.
            var eventCursor = CameraEventCursor(connectionID: connection.connectionID, revision: 0)
            // Establish the old-photo baseline even when the user never opens the files page.
            // This task is separate from the ONE event observer so events during scanning are retained.
            scanningCatalog = true
            catalogTask = Task { [weak self] in
                defer {
                    if self?.catalog === sessionCatalog {
                        self?.scanningCatalog = false; self?.catalogTask = nil
                    }
                }
                do {
                    let first = try await sessionCatalog.refresh()
                    guard let self, !Task.isCancelled, self.catalog === sessionCatalog else { return }
                    self.receiveCatalogChange(first)
                } catch {
                    guard let self, !Task.isCancelled, self.catalog === sessionCatalog else { return }
                    self.catalogStatus = "首次目录读取未完成，请在文件页刷新；不会把旧照片当作自动传输新增。"
                }
            }
            var terminalMessage: String?
            for await state in connection.updates {
                try Task.checkCancellation()
                if state.phase == .closed {
                    sessionAutomatic.close(); sessionReady = false
                    terminalMessage = state.errorDescription
                    publishProduct("closing", message: state.errorDescription)
                }
                await previews.setConnected(state.phase == .ready)
                queuePage?.setConnected(state.phase == .ready)
                filesPage?.setConnected(state.phase == .ready)
                if state.phase == .closed {
                    status = state.errorDescription ?? "相机会话已关闭。"
                } else if state.phase == .ready {
                    let batch = try await connection.events(after: eventCursor)
                    eventCursor = batch.cursor
                    await sessionCatalog.receiveEvents(batch)
                    status = summary + "连接保持中，已收到 \(state.eventRevision) 个有效事件。"
                }
            }
            try Task.checkCancellation()
            sessionAutomatic.close()
            await sessionCatalog.close()
            await previews.close()
            await queue.stop()
            await connection.abort()
            publishProduct(terminalMessage == nil ? "idle" : "failed", message: terminalMessage)
        } catch {
            sessionAutomatic.close()
            await sessionCatalog.close()
            await previews.close()
            await queue.stop()
            await connection.abort(error: error)
            throw error
        }
    }

    /// One queue subscription drives both pages, including automatic admissions and terminal rows.
    /// Ignore obsolete connection/sequence values after suspension; never infer a saved-file badge.
    private func publishQueueSnapshot(_ snapshot: OriginalQueueSnapshot) {
        guard apConnection?.connectionID == snapshot.connectionID else { return }
        if let previous = queueSnapshot, previous.connectionID == snapshot.connectionID,
           previous.sequence > snapshot.sequence { return }
        queueSnapshot = snapshot
        queuePage?.publish(snapshot)
        filesPage?.publishQueue(snapshot)
    }

    private func receiveCatalogAddition(_ addition: CameraCatalogAddition) {
        guard apConnection?.connectionID == addition.snapshot.connectionID else { return }
        filesPage?.publishAddition(addition.snapshot)
        if let media = addition.newMedia { catalogStatus = "已发现新文件：\(media.fileName)" }
        automaticTransfer?.receive(addition, transfer: filesPage?.model.currentTransferPreferences())
    }

    /// This history belongs to standard STA. An AP hotspot must not overwrite the same camera's
    /// LAN address, and a Bonjour service name is never guessed to be a resolved host address.
    nonisolated static func recordVerifiedStationEndpoint(stationMode: Bool, service: CameraBonjourService?, host: String,
        responderGUID: String?, displayName: String, resolvedHost: String? = nil,
        history: () throws -> CameraEndpointHistory) throws {
        guard stationMode, let responderGUID, let address = service == nil ? host : resolvedHost else { return }
        try history().recordSuccessful(responderGUID: responderGUID, displayName: displayName,
            address: CameraEndpointAddress.parse(address))
    }

    private func receiveCatalogChange(_ snapshot: CameraCatalogSnapshot) {
        guard apConnection?.connectionID == snapshot.connectionID else { return }
        filesPage?.publishAddition(snapshot)
    }

    nonisolated static func inspectAPSession(
        _ session: PtpIPCommandSession,
        eventChannel: PtpIPChannel,
        connectionNumber: Int32
    ) async throws -> String {
        // Event reads run concurrently on their own socket; any event-channel failure aborts
        // the diagnostic instead of reporting success for a half-broken two-channel session.
        let lifetime = APProbeLifetime()
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let codes = PtpConstants.shared
                let opened = try await session.execute(operationCode: codes.OPEN_SESSION, parameters: [connectionNumber])
                guard opened.code == codes.RESPONSE_OK || opened.code == codes.SESSION_ALREADY_OPEN else {
                    throw PtpIPSessionError.openRejected(opened.code)
                }
                let result = try await session.execute(operationCode: codes.GET_DEVICE_INFO)
                let identity: String
                if result.code == codes.RESPONSE_OK, let data = result.payload,
                   let info = PtpIPChannel.deviceInfo(data) {
                    identity = "\(info.manufacturer) \(info.model)，固件 \(info.deviceVersion)"
                } else {
                    // Android tolerates unavailable DeviceInfo after a successful OpenSession.
                    identity = String(format: "会话可打开，但未取得有效机型数据（响应 0x%04X）", result.code)
                }
                await lifetime.beginClosing()
                let closed = try await session.execute(operationCode: codes.CLOSE_SESSION)
                let cleanup = closed.code == codes.RESPONSE_OK
                    ? "相机会话已正常关闭。"
                    : String(format: "CloseSession 响应 0x%04X，将关闭网络连接。", closed.code)
                return "AP 诊断：\(identity)。\(cleanup)照片列表和传输仍待实现/验收。"
            }
            group.addTask {
                do {
                    while !Task.isCancelled {
                        let packet = try await eventChannel.readControlPacket(timeout: 60)
                        if packet.type == PtpConstants.shared.PING {
                            try await eventChannel.sendPong(timeout: 15)
                        } else if packet.type == PtpConstants.shared.EVENT {
                            // Product event delivery/file updates/reconnect remain IOS-N06/D04.
                            _ = PtpIPChannel.event(packet.payload)
                        }
                    }
                } catch {
                    // Some cameras end the event socket immediately on CloseSession, before its
                    // command response arrives. Let that bounded response decide cleanup success.
                    if (error as? CameraStreamError) == .endOfStream, await lifetime.isClosing() {
                        while !Task.isCancelled { try await Task.sleep(nanoseconds: 1_000_000_000) }
                    } else {
                        throw error
                    }
                }
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CameraStreamError.closed }
            return result
        }
    }

    private static func probeIdentity() -> Data {
        let key = "ios.handshakeProbe.guid"
        if let saved = UserDefaults.standard.data(forKey: key), saved.count == 16 { return saved }
        var uuid = UUID().uuid
        let bytes = withUnsafeBytes(of: &uuid) { Data($0) }
        UserDefaults.standard.set(bytes, forKey: key)
        return bytes
    }
}

#if DEBUG
struct CameraHandshakeProbeView: View {
    @ObservedObject var probe: CameraHandshakeProbe
    @State private var address = PtpConstants.shared.CAMERA_IP
    @State private var stationMode = false
    @State private var persistentAP = true
    @State private var allowPairing = false
    @State private var forcePairing = false
    @State private var expectedResponder = ""
    @State private var documentRequest: ProbeDocumentRequest?
    @State private var sharedPhotoRequest: SharedPhotoProbeRequest?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("开发诊断：相机连接").font(.headline)
            TextField("相机 IP 地址", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .disabled(probe.running)
            Toggle("STA 标准握手", isOn: $stationMode).disabled(probe.running)
            if stationMode && !probe.running {
                Button("查找局域网 Bonjour 相机服务") { probe.discover() }.disabled(probe.downloading)
                if let discovery = probe.discoverySnapshot {
                    if discovery.searching { Text("正在查找（最多8秒）…").font(.caption) }
                    if let message = discovery.message { Text(message).font(.caption) }
                    ForEach(discovery.services) { service in
                        Button("连接候选：\(service.name)") {
                            probe.start(host: "", stationMode: true, persistentAP: true,
                                        allowPairing: allowPairing, forcePairing: forcePairing,
                                        expectedResponder: expectedResponder.isEmpty ? nil : expectedResponder, service: service)
                        }.disabled(probe.downloading)
                    }
                }
            }
            Toggle("持续会话、文件抽样与原片下载", isOn: $persistentAP).disabled(probe.running)
            if stationMode && persistentAP {
                TextField("预期机身 GUID（可选，32位十六进制）", text: $expectedResponder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(probe.running)
                Toggle("允许电脑模式配对", isOn: $allowPairing).disabled(probe.running)
                if allowPairing {
                    Toggle("完成新建电脑档案的配对向导", isOn: $forcePairing).disabled(probe.running)
                    Text("配对会向相机提交确认；请先在相机进入连接电脑的配对流程。成功后需重新连接。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("AP/STA 标准相册路径可保持连接、抽样和原文件下载。STA 专用兼容模式尚未接入；此页仅用于开发验收，不是正式文件浏览器。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("开始诊断") {
                    probe.start(host: address, stationMode: stationMode, persistentAP: persistentAP,
                                allowPairing: allowPairing, forcePairing: forcePairing,
                                expectedResponder: expectedResponder.isEmpty ? nil : expectedResponder)
                }
                    .disabled(probe.running || probe.downloading)
                if probe.running {
                    ProgressView()
                    Button("断开 / 取消") { probe.disconnect() }
                }
            }
            Text(probe.status).font(.footnote).textSelection(.enabled)
            Button("扫描完整标准目录（只展示前20行）") { probe.refreshCatalog() }
                .disabled(!probe.running || probe.scanningCatalog || probe.downloading)
            if !probe.catalogStatus.isEmpty { Text(probe.catalogStatus).font(.caption) }
            ForEach(Array(probe.samples.enumerated()), id: \.offset) { index, sample in
                HStack {
                    Text(sample).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("下载") { probe.downloadSample(index) }.disabled(!probe.canDownload(index))
                    Button("入队") { probe.enqueueSample(index) }.disabled(!probe.running)
                    Button("预览") { probe.previewSample(index) }.disabled(!probe.running || probe.loadingPreview)
                }
            }
            if !probe.downloadStatus.isEmpty { Text(probe.downloadStatus).font(.caption).textSelection(.enabled) }
            if let image = probe.previewImage { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 300) }
            if let png = probe.previewPNG {
                Button("检查原版单图缩放/旋转（真实预览）") {
                    sharedPhotoRequest = SharedPhotoProbeRequest(png: png, title: probe.previewStatus)
                }
            }
            if !probe.previewStatus.isEmpty { Text(probe.previewStatus).font(.caption) }
            if let url = probe.savedURL {
                HStack {
                    ShareLink("分享已保存原文件", item: url)
                    Button("导出到文件") { documentRequest = ProbeDocumentRequest(purpose: .exportCopy(url)) }
                    Button("加入系统图库") { probe.saveToPhotos() }.disabled(probe.importingPhoto)
                    Button("读取照片元数据") { probe.inspectSavedMetadata() }.disabled(probe.readingMetadata)
                    Button("共享滤镜预览（首个预设）") { probe.previewSavedFilter() }.disabled(probe.loadingPreview)
                }
                HStack {
                    Button("写入已选目录") { probe.publishSavedToDirectory(byDate: false) }
                    Button("按拍摄日期写入已选目录") { probe.publishSavedToDirectory(byDate: true) }
                }.font(.caption).disabled(probe.directoryBusy)
            }
            if !probe.exportStatus.isEmpty { Text(probe.exportStatus).font(.caption) }
            if !probe.metadataStatus.isEmpty { Text(probe.metadataStatus).font(.caption) }
            HStack {
                Button("选择导出目录授权") { documentRequest = ProbeDocumentRequest(purpose: .chooseDirectory) }
                Button("检查已存目录") { probe.useDirectory() }
                Button("检查目标原片索引") { probe.inspectProviderOriginals() }
                Button("忘记目录授权") { probe.useDirectory(forget: true) }
            }.font(.caption).disabled(probe.directoryBusy)
            if !probe.directoryStatus.isEmpty { Text(probe.directoryStatus).font(.caption) }
            if !probe.photoImportStatus.isEmpty { Text(probe.photoImportStatus).font(.caption) }
            Button("打开共享文件浏览（真实目录）") { probe.openSharedFiles() }
                .disabled(!probe.canOpenSharedWorkspace || probe.scanningCatalog)
            Button("打开共享文件浏览（已选原片目录）") { probe.openSharedProviderFiles() }
                .disabled(!probe.canOpenSharedWorkspace || probe.scanningCatalog || probe.directoryBusy)
            HStack {
                Button("队列保存到所选目录") { probe.configureQueueDirectory(true) }
                Button("队列切回应用沙盒") { probe.configureQueueDirectory(false) }
            }.font(.caption).disabled(!probe.canOpenSharedWorkspace || probe.directoryBusy || probe.queueSnapshot?.running == true)
            Text(probe.queueDestinationSummary)
                .font(.caption)
            Button("打开共享队列（真实任务）") { probe.openSharedQueue() }
                .disabled(!probe.canOpenSharedWorkspace)
            if let queue = probe.queueSnapshot {
                HStack {
                    Button("开始 / 继续队列") { probe.startQueue() }.disabled(queue.running || probe.downloading || !probe.running)
                    Button("传完当前暂停") { probe.pauseQueue() }.disabled(!queue.running)
                    Button("清理已结束记录") { probe.clearQueueHistory() }
                }.font(.caption)
                ForEach(queue.rows, id: \.id) { row in
                    HStack {
                        Text("\(row.name) · \(row.status)").font(.caption)
                        if row.status == "TRANSFERING" {
                            ProgressView(value: Double(row.fraction))
                            Text("\(row.downloaded) B · \(row.bytesPerSecond) B/s").font(.caption2)
                        }
                        if row.status == "WAITING" { Button("撤回") { probe.withdrawQueueTask(row.id) } }
                        if row.status == "FAILED" || row.status == "CANCELLED" {
                            Button("重试") { probe.retryQueueTask(row.id) }.disabled(!probe.running || probe.downloading)
                        }
                        if row.status == "COMPLETED" { Button("取出分享") { probe.shareQueueTask(row.id) } }
                    }
                    if let error = row.error { Text(error).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .sheet(item: $probe.queuePage) { page in OriginalQueuePage(bridge: page) }
        .sheet(item: $probe.filesPage) { page in OriginalFilesPage(bridge: page) }
        .sheet(item: $sharedPhotoRequest) { request in SharedPhotoProbeView(request: request).ignoresSafeArea() }
        .onDisappear { probe.cancel() }
        .sheet(item: $documentRequest) { request in
            SystemDocumentPicker(purpose: request.purpose) { urls in
                switch request.purpose {
                case .exportCopy: probe.exported(urls)
                case .chooseDirectory: if let url = urls?.first { probe.useDirectory(url) }
                }
                documentRequest = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            sharedPhotoRequest = nil
            probe.releasePreviewMemory()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { sharedPhotoRequest = nil; probe.cancel() }
        }
    }
}
#endif
