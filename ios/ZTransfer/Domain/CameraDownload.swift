import Foundation
import Darwin

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
    /// Android wraps the destination in a 1 MiB BufferedOutputStream. iOS can
    /// also target a File Provider-backed URL, where issuing one write for
    /// every small PTP/IP packet adds avoidable provider/syscall overhead.
    private static let outputBufferBytes = 1024 * 1024
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
    private var pendingOutput = Data()
    private var closed = false
    private let diagnostics: PTPTransferDiagnostics?

    init(output: FileHandle, resumeOffset: UInt64, totalHint: UInt64, captureHeader: Bool,
         startedAt: ContinuousClock.Instant, onProgress: (@Sendable (TransferDownloadProgress) -> Void)?,
         diagnostics: PTPTransferDiagnostics? = nil) {
        self.output = output; self.resumeOffset = resumeOffset
        self.totalHint = totalHint; self.total = totalHint; self.written = resumeOffset
        self.captureHeader = captureHeader && resumeOffset == 0
        self.startedAt = startedAt; self.lastProgressAt = startedAt
        self.onProgress = onProgress
        self.diagnostics = diagnostics
        self.pendingOutput.reserveCapacity(Self.outputBufferBytes)
    }

    var sink: PTPDataSink {
        PTPDataSink(started: { [self] expected in begin(expected) }, received: { [self] data in
            try data.withUnsafeBytes { try write($0) }
        }, diagnostics: diagnostics, receivedBorrowed: { [self] bytes in try write(bytes) })
    }

    private func begin(_ expected: UInt64?) {
        let progress = lock.withLock {
            total = totalHint > 0 ? totalHint : (expected ?? 0)
            return progressSnapshot(force: true)
        }
        if let progress { onProgress?(progress) }
    }

    private func write(_ data: UnsafeRawBufferPointer) throws {
        try Task.checkCancellation()
        let progress = try lock.withLock {
            guard !closed else { throw CancellationError() }
            try writeBuffered(data)
            if captureHeader, header.count < cameraExifHeaderCaptureBytes {
                header.append(contentsOf: data.prefix(cameraExifHeaderCaptureBytes - header.count))
            }
            written += UInt64(data.count)
            return progressSnapshot(force: false)
        }
        if let progress { onProgress?(progress) }
    }

    private func writeBuffered(_ data: UnsafeRawBufferPointer) throws {
        guard !data.isEmpty else { return }
        // A packet at least as large as the buffer is already suitably
        // batched. Flush older small packets, then avoid copying this one into
        // another 1 MiB staging allocation.
        if data.count >= Self.outputBufferBytes {
            try flushPendingOutput()
            try writeToOutput(data)
            return
        }
        if pendingOutput.count + data.count > Self.outputBufferBytes {
            try flushPendingOutput()
        }
        pendingOutput.append(contentsOf: data)
        if pendingOutput.count == Self.outputBufferBytes {
            try flushPendingOutput()
        }
    }

    private func flushPendingOutput() throws {
        guard !pendingOutput.isEmpty else { return }
        try pendingOutput.withUnsafeBytes { try writeToOutput($0) }
        pendingOutput.removeAll(keepingCapacity: true)
    }

    private func writeToOutput(_ data: UnsafeRawBufferPointer) throws {
        let start = diagnostics.map { _ in ContinuousClock.now }
        defer {
            if let start { diagnostics?.write(bytes: data.count, elapsedMS: PTPTransferDiagnostics.milliseconds(since: start)) }
        }
        // Android BufferedOutputStream writes a large borrowed byte[] directly.
        // Consume synchronously without constructing an owning Data or letting
        // a no-copy wrapper escape. Retry partial writes/EINTR like FileHandle.
        var offset = 0
        while offset < data.count {
            let count = Darwin.write(output.fileDescriptor, data.baseAddress!.advanced(by: offset), data.count - offset)
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw CameraDownloadError.write(NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription)
            }
            guard count > 0 else {
                throw CameraDownloadError.write(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)).localizedDescription)
            }
            offset += count
        }
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
            do {
                try flushPendingOutput()
                try output.close()
            } catch let error as CameraDownloadError {
                try? output.close()
                throw error
            } catch {
                try? output.close()
                throw CameraDownloadError.write(error.localizedDescription)
            }
        }
    }
}
