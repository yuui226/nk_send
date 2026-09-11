import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZTransferShared

enum PhotoEffectsExportError: Error {
    case invalidSource
    case unsupportedFilter
    case unableToCreateDestination
    case unableToFinalizeDestination
}

struct PhotoEffectsRenderedFile: Sendable, Equatable {
    let assetID: String
    let url: URL
}

/// One real render/save operation used by the batch session. It writes a private JPEG first and
/// only then asks Photos to add it; the source URL is never modified. Hosts that need Files/share
/// output can retain the returned artifact and call `remove` after their provider has acknowledged it.
actor PhotoEffectsExportService {
    private let renderer: PhotoFilterPreviewRenderer
    private let importer: PhotoLibraryImporter

    init(renderer: PhotoFilterPreviewRenderer = PhotoFilterPreviewRenderer(),
         importer: PhotoLibraryImporter = PhotoLibraryImporter()) {
        self.renderer = renderer
        self.importer = importer
    }

    func render(_ asset: IOSPhotoEffectAsset, selection: IOSPhotoFilterSelection) async throws -> PhotoEffectsRenderedFile {
        try Task.checkCancellation()
        guard asset.url.isFileURL,
              (try? asset.url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let source = CGImageSourceCreateWithURL(asset.url as CFURL, [
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary),
              let filter = NativePhotoFilterCatalog.shared.selection(
                  index: selection.index, intensityPercent: Int32(selection.intensityPercent)
              ) else { throw PhotoEffectsExportError.invalidSource }

        let rendered = try await renderer.renderExport(image, selection: filter)
        try Task.checkCancellation()
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztransfer-effect-\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw PhotoEffectsExportError.unableToCreateDestination }
        var options: [CFString: Any] = (properties as? [CFString: Any]) ?? [:]
        options[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImage(destination, rendered, options as CFDictionary)
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoEffectsExportError.unableToFinalizeDestination
        }
        try Task.checkCancellation()
        return PhotoEffectsRenderedFile(assetID: asset.id, url: output)
    }

    func saveToPhotos(_ rendered: PhotoEffectsRenderedFile) async throws {
        try Task.checkCancellation()
        guard rendered.url.isFileURL else { throw PhotoEffectsExportError.invalidSource }
        try await importer.save(rendered.url)
    }

    func remove(_ rendered: PhotoEffectsRenderedFile) {
        try? FileManager.default.removeItem(at: rendered.url)
    }

    func generateAndSave(_ asset: IOSPhotoEffectAsset, selection: IOSPhotoFilterSelection) async throws -> Bool {
        let rendered = try await render(asset, selection: selection)
        defer { remove(rendered) }
        try await saveToPhotos(rendered)
        return true
    }
}
