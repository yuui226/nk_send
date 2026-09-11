import CoreGraphics
import Foundation
import ImageIO
import UIKit
import ZTransferShared

/// Main-actor image cache for the workbench. Every new selection cancels the previous render and
/// replaces only the matching asset, so a late preview can never overwrite another page.
@MainActor
final class PhotoEffectsPreviewStore: ObservableObject {
    @Published private(set) var images: [String: UIImage] = [:]
    @Published private(set) var renderingID: String?

    private let renderer: PhotoFilterPreviewRenderer
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(renderer: PhotoFilterPreviewRenderer = PhotoFilterPreviewRenderer()) {
        self.renderer = renderer
    }

    func image(for asset: IOSPhotoEffectAsset) -> UIImage? {
        images[asset.id] ?? UIImage(contentsOfFile: asset.url.path)
    }

    func render(_ asset: IOSPhotoEffectAsset, selection: IOSPhotoFilterSelection) {
        generation &+= 1
        let token = generation
        task?.cancel()
        renderingID = asset.id
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let source = CGImageSourceCreateWithURL(asset.url as CFURL, [
                    kCGImageSourceShouldCache: false,
                ] as CFDictionary), let image = CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCache: false,
                ] as CFDictionary), let filter = NativePhotoFilterCatalog.shared.selection(
                    index: selection.index, intensityPercent: Int32(selection.intensityPercent)
                ) else { throw PreviewError.invalidSource }
                let rendered = try await renderer.render(image, selection: filter)
                try Task.checkCancellation()
                guard token == self.generation else { return }
                self.images[asset.id] = UIImage(cgImage: rendered)
                self.renderingID = nil
                self.task = nil
            } catch is CancellationError {
                if token == self.generation { self.renderingID = nil; self.task = nil }
            } catch {
                if token == self.generation { self.renderingID = nil; self.task = nil }
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
    }

    deinit { task?.cancel() }
    private enum PreviewError: Error { case invalidSource }
}
