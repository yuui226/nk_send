import Foundation

/// Android JpegThumbnailFallback.kt / NikonCamera.getThumbnail. A grid miss
/// can read one bounded JPEG EXIF prefix, never the original or FHD preview.
enum JpegThumbnailFallback {
    static let maximumHeaderBytes = 128 * 1024

    static func headerBytes(responseCode: UInt16, hasThumbnail: Bool, file: CameraFile?) -> Int {
        guard !hasThumbnail, let file,
              file.fileExtension == ".jpg" || file.fileExtension == ".jpeg",
              responseCode == PTPConstants.noThumbnailPresent || responseCode == PTPConstants.responseOK else { return 0 }
        return Int(min(file.size, UInt64(maximumHeaderBytes)))
    }

    /// The caller retains the original visible/background camera transaction.
    /// Negative partial-read responses are misses; cancellation and transport
    /// errors propagate through PTPSession without becoming negative caches.
    static func read(session: PTPSession, handle: UInt32, file: CameraFile?,
                     response: PTPResponse) async throws -> Data {
        let original = response.code == PTPConstants.responseOK ? response.data : Data()
        let count = headerBytes(responseCode: response.code, hasThumbnail: !original.isEmpty,
                                file: file?.id == handle ? file : nil)
        guard count > 0 else { return original }
        let header = try await session.executeResponse(operation: PTPConstants.getPartialObjectEx,
            parameters: [handle, 0, 0, UInt32(count), 0])
        guard header.code == PTPConstants.responseOK, !header.data.isEmpty else { return original }
        return NEFExifThumbnail.readJPEG(Data(header.data.prefix(count))) ?? original
    }
}
