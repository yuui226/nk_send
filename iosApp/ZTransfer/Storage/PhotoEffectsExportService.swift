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
    private let file: PhotoEffectsOwnedFile
    var url: URL { file.url }

    /// Takes ownership of a newly generated private file, never a user-owned original.
    init(assetID: String, ownedURL: URL) {
        self.assetID = assetID
        self.file = PhotoEffectsOwnedFile(url: ownedURL)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.assetID == rhs.assetID && lhs.url == rhs.url }
}

private final class PhotoEffectsOwnedFile: @unchecked Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Rendering may run in parallel, but one owner requests Photos permission and publishes each
/// file in turn. A queued save can be cancelled; a submitted save waits for its real receipt.
actor PhotoEffectsPhotosPublisher {
    private let importer: PhotoLibraryImporter
    private var busy = false
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(importer: PhotoLibraryImporter = PhotoLibraryImporter()) { self.importer = importer }

    func save(_ url: URL) async throws {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await importer.save(url)
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if busy { waiting.append((id, continuation)) }
                else { busy = true; continuation.resume() }
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiting.isEmpty { busy = false }
        else { waiting.removeFirst().continuation.resume() }
    }
}

/// One real render/save operation used by the batch session. It writes a private JPEG first and
/// only then asks Photos to add it; the source URL is never modified. Hosts that need Files/share
/// output retain the returned artifact through their provider's receipt; its last owner cleans up.
actor PhotoEffectsExportService {
    private let renderer: PhotoFilterPreviewRenderer
    private let publisher: PhotoEffectsPhotosPublisher

    init(renderer: PhotoFilterPreviewRenderer = PhotoFilterPreviewRenderer(),
         publisher: PhotoEffectsPhotosPublisher = PhotoEffectsPhotosPublisher()) {
        self.renderer = renderer
        self.publisher = publisher
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
              ] as CFDictionary) else { throw PhotoEffectsExportError.invalidSource }

        let catalog = NativePhotoFilterCatalog.shared
        guard catalog.id(index: selection.index) == selection.filterID,
              catalog.catalogKey(index: selection.index) == selection.catalogKey,
              let filter = catalog.selection(
            index: selection.index, intensityPercent: Int32(selection.intensityPercent)
        ) else { throw PhotoEffectsExportError.unsupportedFilter }

        let rendered = try await renderer.renderExport(image, selection: filter)
        try Task.checkCancellation()
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ztransfer-effect-\(UUID().uuidString).jpg")
        // This lease also removes a partial destination on every error or cancellation path.
        let artifact = PhotoEffectsRenderedFile(assetID: asset.id, ownedURL: output)
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
        return artifact
    }

    func saveToPhotos(_ rendered: PhotoEffectsRenderedFile) async throws {
        defer { withExtendedLifetime(rendered) {} }
        try Task.checkCancellation()
        guard rendered.url.isFileURL else { throw PhotoEffectsExportError.invalidSource }
        try await publisher.save(rendered.url)
    }

    func generateAndSave(_ asset: IOSPhotoEffectAsset, selection: IOSPhotoFilterSelection) async throws -> Bool {
        let rendered = try await render(asset, selection: selection)
        try await saveToPhotos(rendered)
        withExtendedLifetime(rendered) {}
        return true
    }
}
