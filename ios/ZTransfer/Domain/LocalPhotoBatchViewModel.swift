import Photos
import PhotosUI
import SwiftUI
import UIKit
import ImageIO

/// Owns references to picker items, never an array of full-resolution UIImages.
/// A batch snapshots both sources and effects before any worker starts.
@MainActor
final class LocalPhotoBatchViewModel: ObservableObject {
    @Published private(set) var state = LocalPhotoBatchState<PhotosPickerItem>()
    private var generationTask: Task<Void, Never>?
    private var previousIdleTimerDisabled: Bool?
    private var idleTimerGeneration: UInt64?

    func select(_ items: [PhotosPickerItem]) {
        guard state.select(items) else { return }
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

    func dispose() {
        generationTask?.cancel()
        generationTask = nil
        state.cancel()
        restoreIdleTimer()
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

    deinit { generationTask?.cancel() }
}

enum LocalPhotoOutput {
    static func generate(item: PhotosPickerItem, settings: PhotoEffectsSettings) async throws {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        let renderer = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try autoreleasepool {
                guard let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                let metadata = PhotoExifParser.parse(data).map(PhotoFrameMetadata.init)
                let output = try PhotoEffectsRenderer.render(image, settings: settings, metadata: metadata)
                try Task.checkCancellation()
                // Match Android's JPEG output; retain only compressed data while
                // waiting for the photo-library write to settle.
                guard let encoded = output.jpegData(compressionQuality: 1) else {
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

    static func decodePreview(item: PhotosPickerItem) async throws -> LocalPhotoDecodedSource {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        let metadata = PhotoExifParser.parse(data).map(PhotoFrameMetadata.init)
        let renderer = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try autoreleasepool {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
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
            return try autoreleasepool {
                var filterOnly = PhotoEffectsSettings()
                filterOnly.photoFilterEnabled = true
                filterOnly.selectedFilter = selection
                let output = try PhotoEffectsRenderer.render(image, settings: filterOnly)
                try Task.checkCancellation()
                return output
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
            return try autoreleasepool {
                // Android keeps the expensive filter result separate from the
                // frame/watermark preview. Reuse that intermediate whenever a
                // wheel changes only decoration settings.
                var decorationOnly = settings
                decorationOnly.photoFilterEnabled = false
                let filteredInput = filteredSource ?? image
                let filtered = try PhotoEffectsRenderer.render(filteredInput, settings: decorationOnly, metadata: metadata)
                try Task.checkCancellation()
                // The comparison frame is deliberately deferred by the view
                // until the filtered frame is visible, matching Android's
                // delayed long-press baseline and avoiding a blank preview
                // while the second full composition is running.
                return LocalPhotoPreviewImages(filtered: filtered, unfiltered: filtered)
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
            return try autoreleasepool {
                var comparison = settings
                comparison.photoFilterEnabled = false
                let output = try PhotoEffectsRenderer.render(image, settings: comparison, metadata: metadata)
                try Task.checkCancellation()
                return output
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
