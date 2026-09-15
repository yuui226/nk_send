import Foundation

let cameraExifHeaderCaptureBytes = 256 * 1024

struct TransferFileOperations: Sendable {
    let exists: @Sendable (URL) -> Bool
    let move: @Sendable (URL, URL) throws -> Void
    let copy: @Sendable (URL, URL) throws -> Void
    let remove: @Sendable (URL) throws -> Void
    let size: @Sendable (URL) throws -> UInt64

    static let system = TransferFileOperations(
        exists: { FileManager.default.fileExists(atPath: $0.path) },
        move: { try FileManager.default.moveItem(at: $0, to: $1) },
        copy: { try FileManager.default.copyItem(at: $0, to: $1) },
        remove: { try FileManager.default.removeItem(at: $0) },
        size: { UInt64(max(0, try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)) }
    )
}

struct CameraDownloadResult: Sendable {
    let url: URL
    let bytes: UInt64
    let transferredBytes: UInt64
    let startedAt: ContinuousClock.Instant
    let headerPrefix: Data?
}

extension PhotoFrameMetadata {
    static func cameraSnapshot(_ header: Data) -> PhotoFrameMetadata? {
        guard let exif = PhotoExifParser.parse(header) else { return nil }
        let metadata = PhotoFrameMetadata(exif)
        let cameraFields = [metadata.make, metadata.model, metadata.aperture, metadata.shutter,
                            metadata.iso, metadata.focalLength, metadata.lensModel, metadata.dateTime]
        let hasField = cameraFields.contains { !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
        let coordinates = metadata.latitude.map { $0.isFinite && $0 != 0 && (-90...90).contains($0) } == true &&
            metadata.longitude.map { $0.isFinite && $0 != 0 && (-180...180).contains($0) } == true
        let altitude = metadata.altitude.map { $0.isFinite && $0 != 0 } == true
        return hasField || coordinates || altitude ? metadata : nil
    }
}

extension PhotoFrameMetadataSettings {
    var hasVisibleMetadata: Bool {
        showDate || showTime || showFocalLength || showExposure || showBrand || showModel ||
            showLensModel || showCoordinates || showAltitude
    }
}

enum CameraDownloadError: Error, Equatable, LocalizedError, Sendable {
    case incomplete(received: UInt64, expected: UInt64)
    case copyIncomplete(received: UInt64, expected: UInt64)
    case save(String)
    case response(UInt16)
    case write(String)

    var errorDescription: String? {
        switch self {
        case let .incomplete(received, expected):
            return AppLocalized.formattedResource("error_incomplete_data", ["%1$d": "\(received)", "%2$d": "\(expected)"])
        case let .copyIncomplete(received, expected):
            return AppLocalized.formattedResource("error_copy_incomplete", ["%1$d": "\(received)", "%2$d": "\(expected)"])
        case .save(let reason):
            return AppLocalized.formattedResource("error_save_failed", ["%1$s": reason])
        case .write(let reason):
            return AppLocalized.formattedResource("error_write_file", ["%1$s": reason])
        case .response(let code):
            return AppLocalized.formattedResource("error_transfer_failed_reason", ["%1$s": Self.responseMessage(code)])
        }
    }

    // PtpConstants.RESPONSE_MESSAGES / translateResponse, without new text.
    private static func responseMessage(_ code: UInt16) -> String {
        let key: String?
        switch code {
        case 0x2003: key = "ptp_session_not_open"
        case 0x2005, 0x200A: key = "ptp_operation_not_supported"
        case 0x2006, 0x201D: key = "ptp_invalid_parameter"
        case 0x2009: key = "ptp_object_not_exist"
        case 0x200B, 0x2014: key = "ptp_incompatible_spec"
        case 0x200C: key = "ptp_storage_full"
        case 0x200D, 0x200E: key = "ptp_file_protected"
        case 0x2013, 0xA802: key = "ptp_storage_unavailable"
        case 0x2015: key = "ptp_no_object"
        case 0x2019: key = "ptp_device_busy"
        case 0x201A: key = "ptp_no_parent"
        case 0x201E: key = "ptp_session_already_open"
        case 0x201F: key = "ptp_transfer_cancelled"
        case 0xA801: key = "ptp_firmware_error"
        default: key = nil
        }
        if let key { return AppLocalized.resource(key) }
        let fallback: String
        switch code & 0xFF00 {
        case 0x2000: fallback = "ptp_general_error"
        case 0xA000: fallback = "ptp_device_error"
        case 0xA800: fallback = "ptp_firmware_error_code"
        default: fallback = "ptp_unknown_error"
        }
        return AppLocalized.formattedResource(fallback, ["%1$s": String(code, radix: 16).uppercased()])
    }
}

/// Owns the output stream through one file download. Packet callbacks can run
/// off the repository actor; the lock also protects against late callbacks
/// after timeout closing the file. Only the bounded JPEG prefix is retained.
final class CameraDownloadWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let output: FileHandle
    private let resumeOffset: UInt64
    private let totalHint: UInt64
    private let captureHeader: Bool
    private let onProgress: (@Sendable (TransferDownloadProgress) -> Void)?
    let startedAt: ContinuousClock.Instant
    private var lastProgressAt: ContinuousClock.Instant
    private var total: UInt64
    private var written: UInt64
    private var header = Data()
    private var closed = false

    init(output: FileHandle, resumeOffset: UInt64, totalHint: UInt64, captureHeader: Bool,
         startedAt: ContinuousClock.Instant, onProgress: (@Sendable (TransferDownloadProgress) -> Void)?) {
        self.output = output; self.resumeOffset = resumeOffset
        self.totalHint = totalHint; self.total = totalHint; self.written = resumeOffset
        self.captureHeader = captureHeader && resumeOffset == 0
        self.startedAt = startedAt; self.lastProgressAt = startedAt
        self.onProgress = onProgress
    }

    var sink: PTPDataSink {
        PTPDataSink(started: { [self] expected in begin(expected) }, received: { [self] data in try write(data) })
    }

    private func begin(_ expected: UInt64?) {
        let progress = lock.withLock {
            total = totalHint > 0 ? totalHint : (expected ?? 0)
            return progressSnapshot(force: true)
        }
        if let progress { onProgress?(progress) }
    }

    private func write(_ data: Data) throws {
        try Task.checkCancellation()
        let progress = try lock.withLock {
            guard !closed else { throw CancellationError() }
            do { try output.write(contentsOf: data) }
            catch { throw CameraDownloadError.write(error.localizedDescription) }
            if captureHeader, header.count < cameraExifHeaderCaptureBytes {
                header.append(data.prefix(cameraExifHeaderCaptureBytes - header.count))
            }
            written += UInt64(data.count)
            return progressSnapshot(force: false)
        }
        if let progress { onProgress?(progress) }
    }

    private func progressSnapshot(force: Bool) -> TransferDownloadProgress? {
        let now = ContinuousClock.now
        guard force || lastProgressAt.duration(to: now) >= .milliseconds(200) else { return nil }
        lastProgressAt = now
        let duration = startedAt.duration(to: now).components
        let elapsedMs = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        let transferred = written >= resumeOffset ? written - resumeOffset : 0
        let speed = elapsedMs >= 1 ? Int64(min(Double(Int64.max), Double(transferred) * 1000 / elapsedMs.rounded(.down))) : 0
        return TransferDownloadProgress(fraction: total > 0 ? min(1, Double(written) / Double(total)) : 0,
                                        downloaded: written, total: total, bytesPerSecond: speed)
    }

    var bytes: UInt64 { lock.withLock { written } }

    func result(url: URL) -> CameraDownloadResult {
        lock.withLock {
            CameraDownloadResult(url: url, bytes: written, transferredBytes: written - resumeOffset,
                                 startedAt: startedAt, headerPrefix: header.isEmpty ? nil : header)
        }
    }

    func close() throws {
        try lock.withLock {
            guard !closed else { return }
            closed = true
            try output.close()
        }
    }
}
