import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ZTransferShared

/// A page adapter, not another camera/queue owner. The diagnostic/session owner forwards its ONE queue observer.
@MainActor
final class OriginalFilesPageBridge: NSObject, ObservableObject, Identifiable, NativeFilesPagePlatform, NativePreviewReadPlatform, NativeDirectorySettingsPlatform, NativeAutomaticTransferSettingsPlatform, UIDocumentPickerDelegate {
    let id = UUID()
    let queuePage: OriginalQueuePageBridge
    private let connectionID: UUID
    private let catalog: CameraCatalog
    private let queue: CameraOriginalQueue
    private let originals: OriginalFilesReading
    private let previews: CameraPreviewStore
    private let exifSource: CameraExifSource
    private let exifCache: NativePreviewExifCache
    private let decoder = PreviewImageDecoder()
    private let preferences: BrowsePreferencesStore
    private let transferPreferences: TransferPreferencesStore
    private let automaticTransfer: CameraAutomaticTransferCoordinator?
    private let automaticTransferTargetAvailable: Bool
    private let directorySelection: ((URL, @escaping (String?) -> Void) -> Void)?
    private let sandboxSelection: ((@escaping (String?) -> Void) -> Void)?
    private let photoEffectsHandler: (() -> Void)?
    private var directoryPicker: (request: Int64, controller: UIDocumentPickerViewController)?
    private var refreshTask: Task<Void, Never>?
    private(set) var originalIndexTask: Task<Void, Never>?
    private var needsOriginalUpdate = false
    private var needsOriginalRescan = false
    private(set) var originalRevision: Int64 = -1
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
    private var lastCatalogPublication: UInt64 = 0
    private var pendingCatalogPublication: CameraCatalogSnapshot?
    private var catalogPublicationTask: Task<Void, Never>?
    private var connected = false
    private var closed = false
    private lazy var originalActions = OriginalActionPresenter(source: originals)
    private let rememberBrowseSession: ((NativeBrowseSession) -> Void)?
    private(set) lazy var model = NativeFilesPageModel(connectionId: connectionID.uuidString, queue: queuePage.model, platform: self)

    init(connectionID: UUID, catalog: CameraCatalog, queue: CameraOriginalQueue, previews: CameraPreviewStore,
         exifSource: CameraExifSource, exifCache: NativePreviewExifCache, stationMode: Bool,
         preferences: BrowsePreferencesStore? = nil, originals: OriginalFilesReading? = nil,
         transferPreferences: TransferPreferencesStore? = nil, directoryDescription: String? = nil,
         directoryMessage: String? = nil, selectDirectory: ((URL, @escaping (String?) -> Void) -> Void)? = nil,
         automaticTransfer: CameraAutomaticTransferCoordinator? = nil, automaticTransferTargetAvailable: Bool = false,
         browseSession: NativeBrowseSession? = nil, rememberBrowseSession: ((NativeBrowseSession) -> Void)? = nil,
         useSandbox: ((@escaping (String?) -> Void) -> Void)? = nil,
         openPhotoEffects: (() -> Void)? = nil) {
        self.connectionID = connectionID; self.catalog = catalog; self.queue = queue; self.previews = previews
        self.exifSource = exifSource; self.exifCache = exifCache
        self.originals = originals ?? queue // One immutable source for the entire page/preview lifetime.
        self.preferences = preferences ?? BrowsePreferencesStore()
        self.transferPreferences = transferPreferences ?? TransferPreferencesStore()
        self.automaticTransfer = automaticTransfer
        self.automaticTransferTargetAvailable = automaticTransferTargetAvailable
        self.directorySelection = selectDirectory
        self.sandboxSelection = useSandbox
        self.photoEffectsHandler = openPhotoEffects
        self.rememberBrowseSession = rememberBrowseSession
        queuePage = OriginalQueuePageBridge(connectionID: connectionID, queue: queue, previews: previews, stationMode: stationMode)
        super.init()
        if let browseSession { _ = model.restoreBrowseSession(value: browseSession) }
        precondition(model.attachPreviewReads(platform: self))
        precondition(model.originalActions.attach(platform: self))
        if automaticTransfer != nil { precondition(model.automaticTransfer.attach(platform: self)) }
        if selectDirectory != nil {
            precondition(model.directory.attach(platform: self, description: directoryDescription, message: directoryMessage))
        }
    }

    func canOpenPhotoEffects() -> Bool { !closed && photoEffectsHandler != nil }
    func openPhotoEffects() { guard !closed else { return }; photoEffectsHandler?() }

    func selectDirectory(requestId: Int64) {
        guard !closed, directoryPicker == nil, directorySelection != nil,
              let presenter = queuePage.presenter, presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil else {
            _ = model.directory.finish(requestId: requestId, message: "@ztr|system_busy")
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false; picker.delegate = self
        directoryPicker = (requestId, picker)
        presenter.present(picker, animated: true)
    }
    func useSandboxAfterConfirmation(requestId: Int64) -> Bool {
        guard !closed, let sandboxSelection else { return false }
        sandboxSelection { [weak self] message in
            guard let self, !self.closed else { return }
            _ = self.model.directory.finish(requestId: requestId, message: message)
        }
        return true
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard let pending = directoryPicker, pending.controller === controller else { return }
        directoryPicker = nil
        _ = model.directory.finish(requestId: pending.request, message: nil)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let pending = directoryPicker, pending.controller === controller else { return }
        guard let url = urls.first, urls.count == 1 else { documentPickerWasCancelled(controller); return }
        directoryPicker = nil
        // Dismiss only this owned system picker before a committed target change closes its old page.
        controller.dismiss(animated: true) { [weak self] in
            guard let self, !self.closed, let choose = self.directorySelection else { return }
            choose(url) { [weak self] message in
                guard let self, !self.closed else { return }
                _ = self.model.directory.finish(requestId: pending.request, message: message)
            }
        }
    }

    func previewDateText(year: Int32, month: Int32, day: Int32) -> String {
        ApplePreviewDateText.date(year: year, month: month, day: day)
    }
    func resetBrowsePreferencesAfterConfirmation() -> Bool {
        guard !closed, preferences.resetAfterUserConfirmation(), let value = preferences.read() else { return false }
        relayPriority(value)
        return true
    }
    func previewTimeText(hour: Int32, minute: Int32, second: Int32) -> String {
        ApplePreviewDateText.time(hour: hour, minute: minute, second: second)
    }

    func publishQueue(_ value: OriginalQueueSnapshot) {
        guard !closed, value.connectionID == connectionID else { return }
        queuePage.publish(value)
        model.observeQueuePublication()
        if completedOriginalRevision == nil || value.completedOriginalRevision > completedOriginalRevision! {
            completedOriginalRevision = value.completedOriginalRevision
            refreshOriginals(rescan: originalRevision < 0)
        }
    }
    func setConnected(_ value: Bool) {
        if !closed { connected = value; queuePage.setConnected(value); model.automaticTransfer.reload() }
    }
    func readBrowsePreferences() -> NativeBrowsePreferences? {
        guard !closed else { return nil }
        let value = preferences.read()
        relayPriority(value ?? NativeBrowsePreferences.companion.defaults())
        return value
    }
    func readTransferPreferences() -> NativeTransferPreferences? {
        guard !closed else { return nil }
        return transferPreferences.read()
    }
    func saveTransferPreferences(value: NativeTransferPreferences) -> Bool {
        guard !closed else { return false }
        let saved = transferPreferences.save(value)
        automaticTransfer?.preferencesDidChange()
        model.automaticTransfer.reload()
        return saved
    }
    func readAutomaticTransfer() -> NativeAutomaticTransferPreferences {
        let enabled = closed ? nil : automaticTransfer?.enabled
        return NativeAutomaticTransferPreferences(enabled: enabled ?? false, valid: enabled != nil,
            canEnable: automaticTransferTargetAvailable && connected)
    }
    func changeAutomaticTransfer(enabled: Bool) -> Bool {
        guard !closed, !enabled || (automaticTransferTargetAvailable && connected) else { return false }
        return automaticTransfer?.setEnabled(enabled) ?? false
    }
    func resetTransferPreferencesAfterConfirmation() -> Bool {
        guard !closed else { return false }
        return automaticTransfer?.resetAfterUserConfirmation() ?? false
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

    /// Initial presentation may reuse the session owner's completed baseline. A current connection
    /// snapshot must be sampled AFTER the catalog value; stale/partial candidates take the normal scan.
    /// This is deliberately separate from refresh(), which always performs a user-requested scan.
    @discardableResult
    func loadInitialCatalog(_ value: CameraCatalogSnapshot?, state: CameraConnectionSnapshot) -> Bool {
        guard !closed, connected, refreshTask == nil, state.connectionID == connectionID, state.phase == .ready else { return false }
        if let value, value.connectionID == connectionID, value.revision == state.eventRevision,
           value.metadataComplete, !value.changedWhileScanning {
            let sequence = model.beginScan()
            if sequence > 0, acceptCatalog(value, sequence: sequence) {
                // publishQueue may already have started this page's initial original-index read.
                // Catalog reuse must not skip local originals or enqueue that same read twice.
                if originalIndexTask == nil { refreshOriginals(rescan: originalRevision < 0) }
                return true
            }
        }
        refresh()
        return false
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
                let snapshot = try await self.catalog.refresh(onBatch: { [weak self] value in
                    await self?.acceptBatch(value, sequence: sequence)
                })
                guard !self.closed, !Task.isCancelled else { return }
                _ = self.acceptCatalog(snapshot, sequence: sequence)
            } catch {
                guard !self.closed else { return }
                self.failScan(sequence: sequence)
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
                    let result = try await self.originals.originals(since: self.originalRevision, rescan: rescan)
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
    func acceptCatalog(_ value: CameraCatalogSnapshot, sequence: Int64, incremental: Bool = false) -> Bool {
        guard !closed else { return false }
        guard value.publicationRevision >= lastCatalogPublication else {
            failScan(sequence: sequence); return false
        }
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
        let accepted = incremental ? model.publishScanBatch(sequence: sequence, snapshot: snapshot)
            : model.finishScan(sequence: sequence, snapshot: snapshot)
        guard accepted else {
            if !incremental { filesByHandle = committedFiles; infosByHandle = committedInfos }
            return false
        }
        if incremental {
            for file in value.files { filesByHandle[file.handle] = file }
            for (handle, info) in value.objectInfos { infosByHandle[handle] = info }
            return true
        }
        scanSequence = sequence
        lastCatalogPublication = value.publicationRevision
        filesByHandle = Dictionary(uniqueKeysWithValues: value.files.map { ($0.handle, $0) })
        infosByHandle = value.objectInfos
        committedFiles = filesByHandle; committedInfos = infosByHandle
        return true
    }

    private var committedFiles: [Int32: CameraFileInfo] = [:]
    private var committedInfos: [Int32: PtpObjectInfo] = [:]
    private func failScan(sequence: Int64) {
        _ = model.finishScan(sequence: sequence, snapshot: nil)
        filesByHandle = committedFiles; infosByHandle = committedInfos
    }
    private func acceptBatch(_ value: CameraCatalogSnapshot, sequence: Int64) {
        guard !closed, !Task.isCancelled else { return }
        _ = acceptCatalog(value, sequence: sequence, incremental: true)
    }
    func followSessionScan(_ value: CameraCatalogSnapshot?, publication: UInt64? = nil) {
        guard !closed, connected, refreshTask == nil else { return }
        if let revision = value?.publicationRevision ?? publication, revision <= lastCatalogPublication { return }
        let existing = model.currentScanSequence()
        let sequence = existing > 0 ? existing : model.beginScan()
        if sequence > 0, let value { acceptBatch(value, sequence: sequence) }
        if originalIndexTask == nil { refreshOriginals(rescan: originalRevision < 0) }
    }
    func sessionScanFailed() {
        guard refreshTask == nil else { return }
        let sequence = model.currentScanSequence()
        if sequence > 0 { failScan(sequence: sequence) }
    }

    /// Coalesce already-resolved snapshots on the UI actor; never start another network scan.
    func publishAddition(_ value: CameraCatalogSnapshot) {
        guard !closed, value.connectionID == connectionID, value.publicationRevision > lastCatalogPublication else { return }
        let active = model.currentScanSequence()
        if refreshTask == nil, active > 0 {
            _ = acceptCatalog(value, sequence: active); return
        }
        if let pendingCatalogPublication, pendingCatalogPublication.publicationRevision >= value.publicationRevision { return }
        pendingCatalogPublication = value
        guard catalogPublicationTask == nil else { return }
        catalogPublicationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.catalogPublicationTask = nil }
            while !self.closed && !Task.isCancelled, let pending = self.pendingCatalogPublication {
                if pending.publicationRevision <= self.lastCatalogPublication { self.pendingCatalogPublication = nil; continue }
                if self.refreshTask == nil && self.commands.isEmpty {
                    let sequence = self.model.beginScan()
                    if sequence > 0 {
                        self.pendingCatalogPublication = nil
                        _ = self.acceptCatalog(pending, sequence: sequence)
                        continue
                    }
                }
                do { try await Task.sleep(nanoseconds: 90_000_000) } catch { return }
            }
        }
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
        let transfer = model.currentTransferPreferences(), dayKey = currentDayKey() // Freeze at admission, before any suspension.
        let token = UUID()
        commands[token] = Task { [weak self] in
            guard let self else { completion.complete(acceptedCount: 0); return }
            var accepted: Int32 = 0
            defer { self.commands.removeValue(forKey: token); completion.complete(acceptedCount: accepted) }
            guard !self.closed, !Task.isCancelled, self.connected else { return }
            accepted = Int32(await self.queue.enqueueCatalog(infos, files: files,
                byDate: transfer.organizeByDate, dayKey: dayKey, deferred: transfer.deferStart))
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
                let png = try await self.decoder.gridThumbnailPNG(data, file: file)
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
                if embeddedRaw { data = try await self.originals.originalRawPreviewData(locator: source) }
                else { data = try await self.originals.originalData(locator: source) }
                guard let data else { completion.complete(image: nil); return }
                try Task.checkCancellation()
                guard !self.closed, self.previewUse?.session == sessionId else { completion.complete(image: nil); return }
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
                let exif = try await self.originals.originalExif(locator: source)
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
        originalActions.close()
        catalogPublicationTask?.cancel(); catalogPublicationTask = nil; pendingCatalogPublication = nil
        if let pending = directoryPicker {
            directoryPicker = nil; pending.controller.delegate = nil
            pending.controller.dismiss(animated: false)
        }
        if let use = previewUse { endPreviewReads(sessionId: use.session) }
        previewRequests.values.forEach { $0.cancel() }
        originalIndexTask?.cancel(); originalIndexTask = nil
        needsOriginalUpdate = false; needsOriginalRescan = false
        commands.values.forEach { $0.cancel() }; commands.removeAll()
        images.values.forEach { $0.cancel() }; images.removeAll()
        filesByHandle.removeAll(); infosByHandle.removeAll()
        committedFiles.removeAll(); committedInfos.removeAll()
    }
    func close() {
        guard !closed else { return }
        rememberBrowseSession?(model.captureBrowseSession())
        model.close()
    }
}

struct OriginalFilesPage: UIViewControllerRepresentable {
    let bridge: OriginalFilesPageBridge
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> OriginalFilesPageBridge { bridge }
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = SharedUiController.shared.originalFiles(model: bridge.model,
            appearance: AppAppearanceSettings.shared.model, onBack: {
                bridge.close(); dismiss(); return KotlinUnit()
            })
        bridge.queuePage.presenter = controller
        return controller
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: UIViewController, coordinator: OriginalFilesPageBridge) { coordinator.close() }
}

extension OriginalFilesPageBridge: NativeOriginalActionsPlatform {
    func performOriginalAction(action: String, items: [NativeOriginalActionItem], completion: NativeOriginalActionCompletion) {
        guard !closed else { completion.complete(succeededIndices: KotlinIntArray(size: 0),
            failedCount: Int32(items.count), cancelled: true, message: nil); return }
        originalActions.perform(action, items: items, presenter: queuePage.presenter, completion: completion)
    }
    func openOriginalActionSettings() {
        guard !closed, let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    func cancelOriginalActions() { originalActions.close() }
}

/// UIKit/PhotoKit adapter for the shared saved-original panel. No camera or queue subscription.
@MainActor
final class OriginalActionPresenter: NSObject, UIDocumentPickerDelegate {
    private let source: OriginalFilesReading
    private let importer: PhotoLibraryImporter
    private var task: Task<Void, Never>?
    private var completion: NativeOriginalActionCompletion?
    private var copies: OriginalActionCopies?
    private var controller: UIViewController?
    private var preparedIndices: [Int] = []
    private var failures = 0
    private var closed = false
    init(source: OriginalFilesReading, importer: PhotoLibraryImporter = PhotoLibraryImporter()) {
        self.source = source; self.importer = importer
    }
    func perform(_ action: String, items: [NativeOriginalActionItem], presenter: UIViewController?,
                 completion: NativeOriginalActionCompletion) {
        guard !closed, self.completion == nil, ["photos", "share", "files"].contains(action),
              !items.isEmpty, items.count <= 500, Set(items.map(\.locator)).count == items.count,
              let source = source as? OriginalFilesReusing,
              let presenter, presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else {
            completion.complete(succeededIndices: KotlinIntArray(size: 0), failedCount: Int32(items.count),
                cancelled: false, message: "@ztr|action_unavailable")
            return
        }
        self.completion = completion; failures = 0; preparedIndices = []
        let copies = OriginalActionCopies(source: source)
        self.copies = copies
        task = Task { [self] in
            var urls: [URL] = [], confirmed: [Int] = []
            for (index, item) in items.enumerated() {
                if Task.isCancelled || closed { break }
                do {
                    let saved = try await copies.prepare(ExistingOriginalReference(name: item.originalName,
                        size: item.originalSize, locator: item.locator))
                    if action == "photos" {
                        try await importer.save(saved.url)
                        confirmed.append(index) // Photos may commit after cancellation; record its real result.
                    } else {
                        urls.append(saved.url); preparedIndices.append(index)
                    }
                } catch {
                    if error is CancellationError || Task.isCancelled { break }
                    failures += 1
                }
            }
            task = nil
            if action == "photos" || Task.isCancelled || closed || urls.isEmpty {
                finish(confirmed, cancelled: Task.isCancelled || closed,
                    message: action == "photos"
                        ? "@ztr|photos_receipt"
                        : "@ztr|export_ended")
                return
            }
            guard presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else {
                failures += urls.count; finish([], cancelled: false, message: "@ztr|system_busy")
                return
            }
            if action == "share" {
                let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
                sheet.completionWithItemsHandler = { [weak self] _, completed, _, error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if error != nil { self.failures += self.preparedIndices.count }
                        self.finish(completed && error == nil ? self.preparedIndices : [],
                            cancelled: !completed && error == nil,
                            message: "@ztr|share_receipt")
                    }
                }
                if let popover = sheet.popoverPresentationController {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
                    popover.permittedArrowDirections = []
                }
                controller = sheet
                presenter.present(sheet, animated: true)
            } else {
                let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
                picker.delegate = self
                controller = picker
                presenter.present(picker, animated: true)
            }
        }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard self.controller === controller else { return }
        finish([], cancelled: true, message: nil)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard self.controller === controller else { return }
        let complete = urls.count == preparedIndices.count && Set(urls).count == urls.count
        // A partial receipt has no stable per-source mapping. Do not invent which file succeeded.
        finish(complete ? preparedIndices : [], cancelled: false,
            message: "@ztr|files_receipt|\(urls.count)/\(preparedIndices.count)")
    }
    private func finish(_ indices: [Int], cancelled: Bool, message: String?) {
        guard let callback = completion else { return }
        completion = nil
        let values = KotlinIntArray(size: Int32(indices.count))
        for (offset, index) in indices.enumerated() { values.set(index: Int32(offset), value: Int32(index)) }
        callback.complete(succeededIndices: values, failedCount: Int32(failures), cancelled: cancelled, message: message)
        let released = copies; copies = nil
        controller = nil; preparedIndices = []
        Task { await released?.release() }
    }
    func close() {
        guard !closed else { return }
        closed = true
        if let task { task.cancel(); return } // Its Photos commit/reader must finish before copy cleanup.
        if let controller {
            controller.dismiss(animated: false) { [self] in finish([], cancelled: true, message: nil) }
        } else { finish([], cancelled: true, message: nil) }
    }
}
