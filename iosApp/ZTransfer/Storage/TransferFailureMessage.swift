import Foundation
import Darwin

/// Stable presentation codes only; never expose NSError userInfo (paths, URLs or credentials).
/// Shared renders them in the CURRENT app language, including already-visible failed rows.
enum TransferFailureMessage {
    static func describe(_ error: Error) -> String {
        if error is CancellationError { return "@ztr|cancelled" }
        if let value = error as? CameraStreamError {
            switch value {
            case .timedOut: return "@ztr|timeout"
            case .localNetworkDenied: return "@ztr|network_denied"
            case .wifiUnavailable: return "@ztr|wifi"
            case .closed, .endOfStream, .notConnected: return "@ztr|closed"
            case .operationInProgress: return "@ztr|busy"
            default: return "@ztr|protocol"
            }
        }
        if let value = error as? CameraOperationError {
            switch value {
            case .rejected(let operation, let response):
                return "@ztr|rejected|" + String(format: "0x%04X / 0x%04X", operation, response)
            case .malformedDataset: return "@ztr|protocol"
            }
        }
        if error is PtpIPSessionError || error is PtpIPChannelError { return "@ztr|protocol" }
        if let value = error as? PhotoLibraryImportError {
            switch value {
            case .permissionDenied: return "@ztr|photo_denied"
            case .unsupportedType: return "@ztr|photo_unsupported"
            case .invalidFile: return "@ztr|source_changed"
            case .importFailed: return "@ztr|photo_failed"
            }
        }
        if let value = error as? SandboxTransferError {
            switch value {
            case .unsafeName, .nameExhausted: return "@ztr|unsafe"
            case .lengthMismatch: return "@ztr|verify"
            case .invalidState: return "@ztr|source_changed"
            }
        }
        if let value = error as? ProviderPublicationError {
            switch value {
            case .unsafePath: return "@ztr|unsafe"
            case .sourceChanged: return "@ztr|source_changed"
            case .verificationFailed: return "@ztr|verify"
            case .coordinationFailed: return "@ztr|permission"
            }
        }
        if error is OriginalIndexError { return "@ztr|source_changed" }
        let ns = error as NSError
        if (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) ||
            (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError) { return "@ztr|disk_full" }
        if ns.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code) {
            return "@ztr|permission"
        }
        if ns.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(ns.code) { return "@ztr|permission" }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError { return "@ztr|source_changed" }
        return "@ztr|failed|" + String(ns.code)
    }
}
