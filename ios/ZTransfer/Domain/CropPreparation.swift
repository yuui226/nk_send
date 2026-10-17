import Foundation

enum CropPreparationError: Error, Equatable, Sendable {
    case orientation(detail: String = "")
    case previewRead(detail: String = "")
    case connection(detail: String = "")
    case unavailable(detail: String = "")
    var messageKey: String {
        switch self {
        case .orientation: return "crop_orientation_failed"
        case .previewRead: return "crop_preview_read_failed"
        case .connection: return "camera_not_connected"
        case .unavailable: return "crop_unavailable"
        }
    }
    var canRetry: Bool { cropPreparationCanRetry(self) }
}

func cropPreparationCanRetry(_ error: CropPreparationError) -> Bool {
    // Android CropEditor exposes retry for every failed preparation.
    true
}

/// Android prepareCrop reuses EXIF direction before requiring a connection.
/// Check cancellation again after transports that may complete after dismissal.
func cropPreparationOrientation(cached: Int?, connected: Bool,
                                readHeader: @Sendable () async throws -> Data) async throws -> Int {
    try Task.checkCancellation()
    if let cached { return cached }
    guard connected else { throw CropPreparationError.connection() }
    let bytes: Data
    do { bytes = try await readHeader() }
    catch is CancellationError { throw CancellationError() }
    catch {
        try Task.checkCancellation()
        throw CropPreparationError.orientation()
    }
    try Task.checkCancellation()
    guard let orientation = parseJpegCropOrientation(bytes) else {
        throw CropPreparationError.orientation()
    }
    return orientation
}

/// Android FileListScreen crop admission checks directory before connection.
enum CropPreviewAdmission: Equatable {
    case accepted, directoryRequired, disconnected
    init(hasDirectory: Bool, connected: Bool) {
        self = !hasDirectory ? .directoryRequired : !connected ? .disconnected : .accepted
    }
}
