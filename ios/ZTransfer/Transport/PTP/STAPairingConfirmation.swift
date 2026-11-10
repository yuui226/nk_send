import Foundation

/// NikonCamera / CameraViewModel (ca03503c): Result ACK creates an in-memory,
/// same-camera receipt. Trust still requires album access and a real LV frame.
struct STAPairingConfirmation: Equatable, Sendable {
    let responderGUID: String
    var remotePermissionVerified = false
    var resultAcknowledgedAt: ContinuousClock.Instant? = nil

    func remainingRestartDelay(now: ContinuousClock.Instant = .now) -> UInt64 {
        guard let resultAcknowledgedAt else { return 6_600_000_000 }
        let remaining = min(.milliseconds(6_600), max(.zero,
            now.duration(to: resultAcknowledgedAt.advanced(by: .milliseconds(6_600)))))
        let parts = remaining.components
        return UInt64(parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000)
    }
}

struct STAPairingCompleted: Error, Equatable, Sendable {
    let confirmation: STAPairingConfirmation
    var isRecovery = false
}

struct STAPairingCleanupFailure: Error {
    let confirmation: STAPairingConfirmation
    let cause: any Error
}

struct STAPairingConfirmationMissing: Error {
    var cause: (any Error)? = nil
}

struct STAPairingVerificationFailure: Error {
    let cause: any Error
    var remoteRequestAttempted = false
    var pairingOnly = false
}

enum STAFailurePolicy {
    static func isUnconfirmed(_ error: any Error) -> Bool {
        error is STAPairingVerificationFailure || (error as? STAConnectionError) == .pairingNotConfirmed
    }
    static func requiresExplicitRetry(_ error: any Error) -> Bool {
        ((error as? STAConnectionFailure)?.cause ?? error) is STAPairingConfirmationMissing
    }
    static func messageResource(_ error: any Error, knownCamera: Bool) -> String? {
        let root = (error as? STAConnectionFailure)?.cause ?? error
        var current: (any Error)? = root
        for _ in 0..<8 {
            guard let value = current else { break }
            let code: UInt16?
            switch value {
            case STAConnectionError.albumUnavailable(let rc), STAConnectionError.initializationFailed(let rc),
                 STAConnectionError.pairingQueryFailed(let rc), STAConnectionError.pairingResultFailed(let rc),
                 PTPSessionError.responseCode(let rc): code = rc
            default: code = nil
            }
            if code == 0x201F { return "sta_camera_check_photos" }
            if let missing = value as? STAPairingConfirmationMissing { current = missing.cause }
            else if let failed = value as? STAPairingVerificationFailure { current = failed.cause }
            else if let cleanup = value as? STAPairingCleanupFailure { current = cleanup.cause }
            else { current = nil }
        }
        if root is STAPairingConfirmationMissing { return "sta_pairing_incomplete" }
        if (root as? STAConnectionError) == .cameraRefused {
            return knownCamera ? "sta_camera_refused_retrying" : "sta_camera_refused_repair"
        }
        return nil
    }
}
