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

/// One real render/save operation used by the batch session. It writes a private JPEG first and
/// only then asks Photos to add it; the source URL is never modified and a failed add leaves the
/// generated file available for the host's retry/share policy.
actor PhotoEffectsExportService {
    private let renderer: PhotoFilterPreviewRenderer
    private let importer: PhotoLibraryImporter

    init(renderer: PhotoFilterPreviewRenderer = PhotoFilterPreviewRenderer(),
         importer: PhotoLibraryImporter = PhotoLibraryImporter()) {
        self.renderer = renderer
        self.importer = importer
    }

    func generateAndSave(_ asset: IOSPhotoEffectAsset, selection: IOSPhotoFilterSelection) async throws -> Bool {
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
            .appendingPathComponent("ztransfer-effect-(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: output) }
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
        try await importer.save(output)
        return true
    }
}
