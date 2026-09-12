import CoreGraphics
import Foundation
import ImageIO
import UIKit
import Combine
import ZTransferShared

enum PhotoEffectsImageDecoder {
    /// Decodes a bounded, orientation-correct thumbnail without asking ImageIO for original pixels.
    static func previewImage(at url: URL, maximumPixelSize: Int = 2000) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}

private struct PhotoEffectsPreviewKey: Hashable {
    let assetID: String
    let path: String
    let catalogKey: String
    let intensity: Int
}

/// Main-actor image cache for the workbench. Every new selection cancels the previous render and
/// replaces only the matching asset, so a late preview can never overwrite another page.
@MainActor
final class PhotoEffectsPreviewStore: ObservableObject {
    @Published private(set) var images: [String: UIImage] = [:]
    @Published private(set) var renderingID: String?

    private let renderer: PhotoFilterPreviewRenderer
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var cache: [PhotoEffectsPreviewKey: UIImage] = [:]
    private var recency: [PhotoEffectsPreviewKey] = []
    private let cacheLimit = 6

    init(renderer: PhotoFilterPreviewRenderer = PhotoFilterPreviewRenderer()) {
        self.renderer = renderer
    }

    func image(for asset: IOSPhotoEffectAsset) -> UIImage? {
        images[asset.id]
    }

    func render(_ asset: IOSPhotoEffectAsset, selection: IOSPhotoFilterSelection) {
        generation &+= 1
        let token = generation
        task?.cancel()
        let key = PhotoEffectsPreviewKey(assetID: asset.id, path: asset.url.standardizedFileURL.path,
                                         catalogKey: selection.catalogKey, intensity: selection.intensityPercent)
        if let cached = cache[key] {
            touch(key)
            images[asset.id] = cached
            renderingID = nil
            task = nil
            return
        }
        renderingID = asset.id
        let renderer = renderer
        task = Task { [weak self] in
            do {
                let image = await Task.detached(priority: .userInitiated) {
                    PhotoEffectsImageDecoder.previewImage(at: asset.url)
                }.value
                try Task.checkCancellation()
                guard let image,
                      let filter = NativePhotoFilterCatalog.shared.selection(
                    index: selection.index, intensityPercent: Int32(selection.intensityPercent)
                ) else { throw PreviewError.invalidSource }
                let rendered = try await renderer.render(image, selection: filter)
                try Task.checkCancellation()
                guard let self, token == self.generation else { return }
                let output = UIImage(cgImage: rendered)
                self.cache[key] = output
                self.touch(key)
                self.trimCache()
                self.images = self.images.filter { $0.key == asset.id }
                self.images[asset.id] = output
                self.renderingID = nil; self.task = nil
            } catch is CancellationError {
                if let self, token == self.generation { self.renderingID = nil; self.task = nil }
            } catch {
                if let self, token == self.generation { self.renderingID = nil; self.task = nil }
            }
        }
    }

    func remove(_ asset: IOSPhotoEffectAsset) {
        images.removeValue(forKey: asset.id)
        if renderingID == asset.id { task?.cancel(); renderingID = nil; task = nil }
    }

    func clear() {
        generation &+= 1
        task?.cancel(); task = nil; renderingID = nil; images.removeAll()
        cache.removeAll(); recency.removeAll()
    }

    deinit { task?.cancel() }
    private func touch(_ key: PhotoEffectsPreviewKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func trimCache() {
        while recency.count > cacheLimit {
            cache.removeValue(forKey: recency.removeFirst())
        }
    }
    private enum PreviewError: Error { case invalidSource }
}
