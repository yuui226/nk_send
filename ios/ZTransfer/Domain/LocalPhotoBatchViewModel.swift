import Photos
import PhotosUI
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import CoreTransferable

/// Requests a file representation from PhotosPicker and copies it during the
/// provider callback, while the security-scoped temporary URL is guaranteed to
/// remain valid. Callers own and remove the returned private temporary file.
struct PhotoPickerTemporaryFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let fileManager = FileManager.default
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("ZTransferPhotoPicker", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let suffix = received.file.pathExtension
            let name = suffix.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(suffix)"
            let destination = directory.appendingPathComponent(name)
            try fileManager.copyItem(at: received.file, to: destination)
            return PhotoPickerTemporaryFile(url: destination)
        }
    }
}

func importPhotoPickerWatermarkImage(_ item: PhotosPickerItem) async -> String? {
    guard let file = try? await item.loadTransferable(type: PhotoPickerTemporaryFile.self) else {
        return nil
    }
    return await Task.detached(priority: .userInitiated) { () -> String? in
        defer { try? FileManager.default.removeItem(at: file.url) }
        return PhotoEffectsStore.importWatermarkImageFile(file.url)
    }.value
}

/// Owns references to picker items, never an array of full-resolution UIImages.
/// A batch snapshots both sources and effects before any worker starts.
@MainActor
final class LocalPhotoBatchViewModel: ObservableObject {
    @Published private(set) var state = LocalPhotoBatchState<PhotosPickerItem>()
    private var generationTask: Task<Void, Never>?
    private var idleTimerHold: UUID?
    private let screenAwake: ScreenAwakeCoordinator
    private var idleTimerGeneration: UInt64?
    private let premiumAccess: PremiumAccess
    private let requestAuthorization: @Sendable () async -> PHAuthorizationStatus
    private let generatePhoto: @Sendable (PhotosPickerItem, PhotoEffectsSettings) async throws -> Void

    // Keep the system authorization/output boundaries replaceable so tests can
    // hold the permission prompt while exercising the real batch lifecycle.
    init(premiumAccess: PremiumAccess = .shared,
         screenAwake: ScreenAwakeCoordinator = .shared,
         requestAuthorization: @escaping @Sendable () async -> PHAuthorizationStatus = {
             await PHPhotoLibrary.requestAuthorization(for: .addOnly)
         },
         generatePhoto: @escaping @Sendable (PhotosPickerItem, PhotoEffectsSettings) async throws -> Void = {
             try await LocalPhotoOutput.generate(item: $0, settings: $1)
         }) {
        self.screenAwake = screenAwake
        self.premiumAccess = premiumAccess
        self.requestAuthorization = requestAuthorization
        self.generatePhoto = generatePhoto
    }

    func select(_ items: [PhotosPickerItem]) {
        // Android launches an image/* picker and lets each selected image reach
        // the decoder; failures are counted per item instead of being silently
        // removed before the batch begins. PhotosPicker already requests images,
        // while this guard only rejects an unexpected non-image provider item.
        let supportedItems = items.filter { isSupportedLocalPhoto($0.supportedContentTypes) }
        guard state.select(supportedItems) else { return }
        // A terminal result may still have its 2400 ms timer running. A fresh
        // picker selection must never be replaced by that older timer.
        generationTask?.cancel()
        generationTask = nil
    }

    func generate(settings: PhotoEffectsSettings) {
        // Snapshot before Photos authorization suspends this task. Upgrades,
        // refunds and edits only affect batches created after this one.
        let settings = effectivePhotoEffectsSettings(settings, isPro: premiumAccess.isPro)
        guard settings.hasEffect, let generation = state.begin() else { return }
        let selected = state.photos
        idleTimerHold = screenAwake.acquire()
        idleTimerGeneration = generation
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Authorization is requested once for the immutable selection.
                let status = await requestAuthorization()
                try Task.checkCancellation()
                let canSave = status == .authorized || status == .limited
                let result = try await PhotoEffectsBatchRunner.generate(photos: selected, onProgress: { [weak self] progress in
                    await self?.record(progress, generation: generation)
                }, generate: { item in
                    guard canSave else {
                        throw LocalPhotoExportError(stage: "save", underlying: CocoaError(.fileWriteNoPermission))
                    }
                    try await self.generatePhoto(item, settings)
                    return true
                })
                try Task.checkCancellation()
                state.finish(result, generation: generation)
                restoreIdleTimer(generation: generation)
                let finished = state
                try await Task.sleep(for: .milliseconds(2400))
                state.returnToReady(ifUnchanged: finished)
            } catch is CancellationError {
                if state.generation == generation { state.cancel() }
                restoreIdleTimer(generation: generation)
            } catch {
                // The runner counts individual load/render/save errors. Only a
                // batch-wide failure reaches here; preserve the settled counts.
                var progress = state.progress
                progress.completed = selected.count
                state.finish(progress, generation: generation)
                restoreIdleTimer(generation: generation)
            }
        }
    }

    private func record(_ progress: PhotoEffectsBatchProgress, generation: UInt64) {
        state.update(progress, generation: generation)
    }

    private func restoreIdleTimer(generation: UInt64? = nil) {
        if let generation, idleTimerGeneration != generation { return }
        guard let idleTimerHold else { return }
        screenAwake.release(idleTimerHold)
        self.idleTimerHold = nil
        idleTimerGeneration = nil
    }

    deinit {
        let hold = idleTimerHold
        let screenAwake = screenAwake
        generationTask?.cancel()
        if let hold { Task { @MainActor in screenAwake.release(hold) } }
    }
}

func isSupportedLocalPhoto(_ contentTypes: [UTType]) -> Bool {
    contentTypes.isEmpty || contentTypes.contains { $0.conforms(to: .image) }
}

enum LocalPhotoOutput {
    static func generate(item: PhotosPickerItem, settings: PhotoEffectsSettings) async throws {
        var stage = "prepare"
        do {
            let sourceURL = try await stagedSource(item: item)
            defer { try? FileManager.default.removeItem(at: sourceURL) }
            stage = "render"
            let output = try await render(sourceURL: sourceURL, settings: settings)
            try Task.checkCancellation()
            stage = "save"
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: output, options: nil)
            }
            // Photos writes already accepted by the system cannot be rolled back by
            // task cancellation. The runner suppresses any late UI progress.
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LocalPhotoExportError(stage: stage, underlying: error)
        }
    }

    /// Shared file-to-JPEG path; the caller owns the staged source and decides
    /// where to save the result. No entitlement reads occur during rendering.
    static func render(sourceURL: URL, settings: PhotoEffectsSettings,
                       availableMemory: @escaping @Sendable () -> Int64 = PhotoAllocationBudget.availableMemory) async throws -> Data {
        try Task.checkCancellation()
        let renderer = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try autoreleasepool {
                // Rendering follows Android's URI/file-backed lifetime and does
                // not retain the entire compressed source beside bitmaps.
                let image = try PhotoAllocationBudget.loadOriginalImage(sourceURL, availableMemory: availableMemory)
                let metadata = PhotoExifParser.parse(sourceURL).map(PhotoFrameMetadata.init)
                let output = try PhotoEffectsRenderer.render(image, settings: settings, metadata: metadata, availableMemory: availableMemory)
                try Task.checkCancellation()
                // Match Android's JPEG output; retain only compressed data while
                // waiting for the photo-library write to settle.
                guard let encoded = PhotoEffectsJPEGEncoder.encode(
                    output, copyingMetadataFrom: sourceURL
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return encoded
            }
        }
        return try await withTaskCancellationHandler {
            try await renderer.value
        } onCancel: { renderer.cancel() }
    }

    private static func stagedSource(item: PhotosPickerItem) async throws -> URL {
        guard let file = try await item.loadTransferable(type: PhotoPickerTemporaryFile.self) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        do {
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: file.url)
            throw error
        }
        return file.url
    }

    static func decodePreview(item: PhotosPickerItem) async throws -> LocalPhotoDecodedSource {
        let sourceURL = try await stagedSource(item: item)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try Task.checkCancellation()
        let metadata = PhotoExifParser.parse(sourceURL).map(PhotoFrameMetadata.init)
        let renderer = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1280,
                        kCGImageSourceShouldCacheImmediately: true,
                      ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
                return LocalPhotoDecodedSource(image: UIImage(cgImage: cgImage), metadata: metadata)
            }
        }
        return try await withTaskCancellationHandler {
            let result = try await renderer.value
            try Task.checkCancellation()
            return result
        } onCancel: { renderer.cancel() }
    }

    static func filteredSource(image: UIImage, selection: PhotoFilterSelection?) async throws -> UIImage {
        guard let selection else { return image }
        let renderer = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await PhotoEffectsPreviewRenderGate.shared.withPermit {
                try autoreleasepool {
                    var filterOnly = PhotoEffectsSettings()
                    filterOnly.photoFilterEnabled = true
                    filterOnly.selectedFilter = selection
                    let output = try PhotoEffectsRenderer.render(image, settings: filterOnly, filterExecution: .preview)
                    try Task.checkCancellation()
                    return output
                }
            }
        }
        return try await withTaskCancellationHandler {
            let result = try await renderer.value
            try Task.checkCancellation()
            return result
        } onCancel: { renderer.cancel() }
    }

    static func preview(image: UIImage, settings: PhotoEffectsSettings, metadata: PhotoFrameMetadata? = nil,
                        filteredSource: UIImage? = nil) async throws -> LocalPhotoPreviewImages {
        let renderer = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await PhotoEffectsPreviewRenderGate.shared.withPermit {
                try autoreleasepool {
                    // Android keeps the expensive filter result separate from the
                    // frame/watermark preview. Reuse that intermediate whenever a
                    // wheel changes only decoration settings.
                    var decorationOnly = settings
                    decorationOnly.photoFilterEnabled = false
                    let filteredInput = filteredSource ?? image
                    let filtered = try PhotoEffectsRenderer.render(
                        filteredInput, settings: decorationOnly, metadata: metadata,
                        previewPlaceholders: true, backdropSource: image,
                        previewLongEdge: 1_920
                    )
                    try Task.checkCancellation()
                    // The comparison frame is deliberately deferred by the view
                    // until the filtered frame is visible, matching Android's
                    // delayed long-press baseline and avoiding a blank preview
                    // while the second full composition is running.
                    return LocalPhotoPreviewImages(filtered: filtered, unfiltered: filtered)
                }
            }
        }
        return try await withTaskCancellationHandler {
            let result = try await renderer.value
            try Task.checkCancellation()
            return result
        } onCancel: { renderer.cancel() }
    }

    static func unfilteredPreview(image: UIImage, settings: PhotoEffectsSettings,
                                  metadata: PhotoFrameMetadata? = nil) async throws -> UIImage {
        let renderer = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await PhotoEffectsPreviewRenderGate.shared.withPermit {
                try autoreleasepool {
                    var comparison = settings
                    comparison.photoFilterEnabled = false
                    let output = try PhotoEffectsRenderer.render(
                        image, settings: comparison, metadata: metadata,
                        previewPlaceholders: true, previewLongEdge: 1_920
                    )
                    try Task.checkCancellation()
                    return output
                }
            }
        }
        return try await withTaskCancellationHandler {
            let result = try await renderer.value
            try Task.checkCancellation()
            return result
        } onCancel: { renderer.cancel() }
    }
}

struct LocalPhotoDecodedSource: Sendable {
    let image: UIImage
    let metadata: PhotoFrameMetadata?
}

struct LocalPhotoPreviewImages: Sendable {
    let filtered: UIImage
    let unfiltered: UIImage
}

/// Android PhotoEffectsPreviewCache: the cache owns work, callers only await it.
/// Cancelling a prefetch waiter must not cancel work promoted to the current frame.
private struct PhotoPreviewObsolete: Error {}

actor PhotoPreviewFrameCache<Value: Sendable> {
    private var completed: Value?
    private var running: (id: UUID, task: Task<Void, Never>)?
    private var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]
    private var closed = false
    private var requested = true

    func getOrRender(_ render: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard requested else { throw PhotoPreviewObsolete() }
        if let completed { return completed }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !closed else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard requested else {
                    continuation.resume(throwing: PhotoPreviewObsolete())
                    return
                }
                waiters[waiterID] = continuation
                guard running == nil else { return }
                let id = UUID()
                let task = Task.detached { [weak self] in
                    let result: Result<Value, Error>
                    do {
                        try Task.checkCancellation()
                        let value = try await render()
                        try Task.checkCancellation()
                        result = .success(value)
                    } catch { result = .failure(error) }
                    await self?.finish(id: id, result: result)
                }
                running = (id, task)
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func finish(id: UUID, result: Result<Value, Error>) {
        guard running?.id == id, !closed else { return }
        running = nil
        if case .success(let value) = result { completed = value }
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values { continuation.resume(with: result) }
    }

    func setRequested(_ requested: Bool) {
        self.requested = requested
        guard !requested else { return }
        running?.task.cancel()
        running = nil
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values { continuation.resume(throwing: PhotoPreviewObsolete()) }
    }

    func close() {
        closed = true
        running?.task.cancel()
        running = nil
        completed = nil
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }
    }

    deinit { running?.task.cancel() }
}

/// One instance belongs to one source/decoration identity. Android retains the
/// three most recently accessed complete previews; eviction closes shared work.
actor PhotoPreviewCacheSet<Key: Hashable & Sendable, Value: Sendable> {
    private let capacity: Int
    private var entries: [Key: PhotoPreviewFrameCache<Value>] = [:]
    private var order: [Key] = []
    private var closed = false
    private var requested: Set<Key>?
    private var demandRevision = UUID()

    init(capacity: Int = 3) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var count: Int { entries.count }

    func replaceRequested(_ keys: Set<Key>) async {
        guard !closed else { return }
        requested = keys
        let revision = UUID()
        demandRevision = revision
        let snapshot = entries
        for (key, entry) in snapshot {
            guard demandRevision == revision, !closed else { return }
            await entry.setRequested(keys.contains(key))
        }
    }

    func getOrRender(key: Key, render: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard !closed, requested?.contains(key) != false else { throw CancellationError() }
        let entry: PhotoPreviewFrameCache<Value>
        if let existing = entries[key] {
            entry = existing
            order.removeAll { $0 == key }
            order.append(key)
        } else {
            entry = PhotoPreviewFrameCache()
            entries[key] = entry
            order.append(key)
            if order.count > capacity {
                let oldest = order.removeFirst()
                let evicted = entries.removeValue(forKey: oldest)
                await evicted?.close()
            }
        }
        while true {
            try Task.checkCancellation()
            guard !closed, requested?.contains(key) != false, entries[key] === entry else { throw CancellationError() }
            do {
                let result = try await entry.getOrRender(render)
                try Task.checkCancellation()
                return result
            } catch is PhotoPreviewObsolete {
                try Task.checkCancellation()
                guard !closed, requested?.contains(key) != false, entries[key] === entry else {
                    throw CancellationError()
                }
                // A previously obsolete frame was promoted while cancellation
                // was being delivered. Re-enable and retry the same cache entry.
                await entry.setRequested(true)
            }
        }
    }

    func close() async {
        closed = true
        let old = Array(entries.values)
        entries.removeAll()
        order.removeAll()
        for entry in old { await entry.close() }
    }
}

/// Page-owned preview cache. Source/decoration changes replace the entire scope;
/// filter changes share the three recent frames and their in-flight work.
@MainActor final class LocalPhotoPreviewCache: ObservableObject {
    private var frames = PhotoPreviewCacheSet<String, LocalPhotoPreviewImages>()
    private var source: UIImage?
    private var metadata: PhotoFrameMetadata?
    private var decoration: PhotoEffectsSettings?
    private var generation = UUID()
    private var currentFilter: PhotoFilterSelection?
    private var filtered: (selection: PhotoFilterSelection, image: UIImage)?

    private static func decorationSettings(_ settings: PhotoEffectsSettings) -> PhotoEffectsSettings {
        var value = photoEffectsPreviewPixelSettings(settings)
        value.photoFilterEnabled = false
        value.selectedFilter = nil
        return value
    }

    private static func key(_ settings: PhotoEffectsSettings) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(photoEffectsPreviewPixelSettings(settings)), as: UTF8.self)
    }

    func configure(image: UIImage, settings: PhotoEffectsSettings, metadata: PhotoFrameMetadata?,
                   prefetchEnabled: Bool = true) async {
        guard !Task.isCancelled else { return }
        let nextDecoration = Self.decorationSettings(settings)
        if source !== image || self.metadata != metadata || decoration != nextDecoration {
            let old = frames
            frames = PhotoPreviewCacheSet()
            generation = UUID()
            if source !== image { filtered = nil }
            source = image
            self.metadata = metadata
            decoration = nextDecoration
            Task { await old.close() }
        }
        currentFilter = settings.photoFilterEnabled ? settings.selectedFilter : nil
        if currentFilter == nil { filtered = nil }
        var wanted = [settings]
        if prefetchEnabled, settings.photoFilterEnabled {
            wanted += nextPhotoFilterSelections(for: settings).map { selection in
                var next = settings
                next.photoFilterEnabled = true
                next.selectedFilter = selection
                return next
            }
        }
        await frames.replaceRequested(Set(wanted.compactMap { try? Self.key($0) }))
    }

    func render(image: UIImage, settings: PhotoEffectsSettings,
                metadata: PhotoFrameMetadata?) async throws -> LocalPhotoPreviewImages {
        try Task.checkCancellation()
        guard source === image, self.metadata == metadata,
              decoration == Self.decorationSettings(settings) else { throw CancellationError() }
        let token = generation
        let selection = settings.photoFilterEnabled ? settings.selectedFilter : nil
        let cachedSource = filtered.flatMap { $0.selection == selection ? $0.image : nil }
        let value = try await frames.getOrRender(key: Self.key(settings)) { [weak self] in
            let prepared: UIImage?
            if let selection {
                if let cachedSource { prepared = cachedSource }
                else { prepared = try await LocalPhotoOutput.filteredSource(image: image, selection: selection) }
            } else { prepared = nil }
            try Task.checkCancellation()
            if let selection, let prepared {
                await self?.remember(prepared, selection: selection, generation: token)
            }
            return try await LocalPhotoOutput.preview(image: image, settings: settings,
                metadata: metadata, filteredSource: prepared)
        }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        return value
    }

    private func remember(_ image: UIImage, selection: PhotoFilterSelection, generation: UUID) {
        guard self.generation == generation, currentFilter == selection else { return }
        filtered = (selection, image)
    }

    func close() {
        let old = frames
        frames = PhotoPreviewCacheSet()
        generation = UUID()
        source = nil
        metadata = nil
        decoration = nil
        currentFilter = nil
        filtered = nil
        Task { await old.close() }
    }
}
