import Foundation

/// Session-scoped EXIF cache matching Android's `exifCache` semantics.
/// A cached nil is intentional: non-image files and confirmed parse failures
/// must not trigger another camera header request when a cell is revisited.
actor PhotoExifStore {
    private var values: [String: PhotoExif] = [:]
    private var negative = Set<String>()

    func reset() {
        values.removeAll(keepingCapacity: true)
        negative.removeAll(keepingCapacity: true)
    }

    func load(file: CameraFile, read: @escaping @Sendable (Int64) async throws -> Data) async throws -> PhotoExif? {
        let captureDate = file.captureDate ?? "0"
        let key = "\(file.fileName)_\(file.size)_\(captureDate)"
        if let value = values[key] { return value }
        if negative.contains(key) { return nil }

        let ext = file.fileExtension
        guard Self.supportedExtensions.contains(ext) else {
            negative.insert(key)
            return nil
        }
        let length: Int64 = Self.largeHeaderExtensions.contains(ext) ? 2 * 1024 * 1024 : 128 * 1024
        let data: Data
        do {
            data = try await read(length)
        } catch {
            // A disconnect, timeout or cancellation is transient. Android
            // does not turn those transport failures into a negative cache hit.
            throw error
        }
        guard !data.isEmpty else {
            negative.insert(key)
            return nil
        }
        let parsed = PhotoExifParser.parse(data)
        if let parsed { values[key] = parsed } else { negative.insert(key) }
        return parsed
    }

    private static let supportedExtensions: Set<String> = [".jpg", ".jpeg", ".nef", ".tif", ".tiff", ".nrw"]
    private static let largeHeaderExtensions: Set<String> = [".nef", ".tif", ".tiff", ".nrw"]
}
