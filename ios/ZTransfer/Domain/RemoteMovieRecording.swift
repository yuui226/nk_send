import Foundation

/// Direct StartMovieRec result from Android's rcStartMovieDetailed. Bit 10 is
/// authoritative when a page reopens while the camera is already recording.
struct RemoteMovieStartResult: Equatable, Sendable {
    let responseCode: UInt16
    let prohibitCondition: UInt32?
    var prohibitExtendedResponse: UInt16? = nil
    var applicationModeResponse: UInt16? = nil
    var applicationModePropertyResponse: UInt16? = nil
    var startCommandResponse: UInt16? = nil

    var indicatesRecording: Bool {
        responseCode == 0x2001 || (prohibitCondition.map { $0 & (1 << 10) != 0 } ?? false)
    }

    var diagnosticSummary: String {
        var result = String(format: "result=0x%04X startOp=0x%04X", responseCode, responseCode)
        if let prohibitCondition {
            result += String(format: " prohibit=0x%08X", prohibitCondition)
        }
        if let prohibitExtendedResponse { result += String(format: " preEx=0x%04X", prohibitExtendedResponse) }
        if let applicationModeResponse { result += String(format: " appOp=0x%04X", applicationModeResponse) }
        if let applicationModePropertyResponse { result += String(format: " appProp=0x%04X", applicationModePropertyResponse) }
        return result
    }

    var needsLiveViewRestart: Bool {
        guard responseCode != PTPConstants.responseOK else { return false }
        let storageMask: UInt32 = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 11)
        let nonRestartable: UInt32 = (1 << 9) | (1 << 10)
        if let prohibitCondition, prohibitCondition & storageMask != 0 { return false }
        if let prohibitCondition, prohibitCondition & nonRestartable != 0 { return false }
        if let prohibitCondition, prohibitCondition != 0 {
            return prohibitCondition & ((1 << 12) | (1 << 14)) != 0
        }
        return responseCode == 0xA004 || responseCode == PTPConstants.deviceBusy
    }

    var requiresApplicationMode: Bool {
        prohibitCondition.map { $0 & (1 << 14) != 0 } ?? false
    }
}

/// Android RemoteLab.cmdBusyRetry sends once, then retries DEVICE_BUSY at most
/// five times with 200 ms between commands. Other responses return unchanged.
enum RemoteMovieCommandRetry {
    static func execute(
        command: @Sendable () async throws -> UInt16,
        pause: @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    ) async throws -> UInt16 {
        try Task.checkCancellation()
        var response = try await command()
        try Task.checkCancellation()
        var retries = 0
        while response == 0x2019 && retries < 5 {
            try await pause()
            try Task.checkCancellation()
            response = try await command()
            try Task.checkCancellation()
            retries += 1
        }
        return response
    }
}

enum RemoteRecordingCommand: Equatable, Sendable { case start, stop }

/// A completion may update the page only while it still owns this request.
/// Cancelling/leaving invalidates the token even if the camera replies later.
struct RemoteRecordingOperationGate: Equatable, Sendable {
    struct Token: Equatable, Sendable {
        fileprivate let sequence: UInt64
        let command: RemoteRecordingCommand
    }

    private var sequence: UInt64 = 0
    private var pending: Token?
    var isBusy: Bool { pending != nil }

    mutating func begin(_ command: RemoteRecordingCommand) -> Token? {
        guard pending == nil else { return nil }
        sequence &+= 1
        let token = Token(sequence: sequence, command: command)
        pending = token
        return token
    }

    func accepts(_ token: Token) -> Bool { pending == token }

    @discardableResult
    mutating func complete(_ token: Token) -> Bool {
        guard accepts(token) else { return false }
        pending = nil
        return true
    }

    mutating func invalidate() { pending = nil }
}

struct RemoteRecordingHint: Equatable, Sendable {
    let message: String
    let durationNanoseconds: UInt64
    let diagnostic: String?

    static func startFailed(_ result: RemoteMovieStartResult?) -> Self {
        Self(message: AppLocalized.resource("remote_rec_start_failed"),
             durationNanoseconds: 12_000_000_000, diagnostic: result?.diagnosticSummary)
    }

    static func stopFailed(responseCode: UInt16 = 0xFFFF) -> Self {
        Self(message: AppLocalized.resource("remote_rec_stop_failed"),
             durationNanoseconds: 6_000_000_000,
             diagnostic: String(format: "stop=0x%04X", responseCode))
    }
}
