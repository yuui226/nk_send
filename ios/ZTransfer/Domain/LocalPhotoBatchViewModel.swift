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
    private var previousIdleTimerDisabled: Bool?
    private var idleTimerGeneration: UInt64?

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
        guard settings.hasEffect, let generation = state.begin() else { return }
        let selected = state.photos
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        idleTimerGeneration = generation
        UIApplication.shared.isIdleTimerDisabled = true
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Authorization is requested once for the immutable selection.
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                try Task.checkCancellation()
                let canSave = status == .authorized || status == .limited
                let result = try await PhotoEffectsBatchRunner.generate(photos: selected, onProgress: { [weak self] progress in
                    await self?.record(progress, generation: generation)
                }, generate: { item in
                    guard canSave else { return false }
                    try await LocalPhotoOutput.generate(item: item, settings: settings)
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
        guard let previousIdleTimerDisabled else { return }
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        self.previousIdleTimerDisabled = nil
        idleTimerGeneration = nil
    }

    deinit {
        let idleTimerValue = previousIdleTimerDisabled
        generationTask?.cancel()
        if let idleTimerValue {
            Task { @MainActor in
                UIApplication.shared.isIdleTimerDisabled = idleTimerValue
            }
        }
    }
}

func isSupportedLocalPhoto(_ contentTypes: [UTType]) -> Bool {
    contentTypes.isEmpty || contentTypes.contains { $0.conforms(to: .image) }
}

enum LocalPhotoOutput {
    static func generate(item: PhotosPickerItem, settings: PhotoEffectsSettings) async throws {
        let sourceURL = try await stagedSource(item: item)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try Task.checkCancellation()
        let renderer = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try autoreleasepool {
                // Rendering follows Android's URI/file-backed lifetime and does
                // not retain the entire compressed source beside bitmaps.
                guard let image = UIImage(contentsOfFile: sourceURL.path) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let metadata = PhotoExifParser.parse(sourceURL).map(PhotoFrameMetadata.init)
                let output = try PhotoEffectsRenderer.render(image, settings: settings, metadata: metadata)
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
        let output = try await withTaskCancellationHandler {
            try await renderer.value
        } onCancel: { renderer.cancel() }
        try Task.checkCancellation()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: output, options: nil)
        }
        // Photos writes already accepted by the system cannot be rolled back by
        // task cancellation. The runner suppresses any late UI progress.
        try Task.checkCancellation()
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
                    let output = try PhotoEffectsRenderer.render(image, settings: filterOnly)
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
