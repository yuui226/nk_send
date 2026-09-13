import Foundation

/// Direct StartMovieRec result from Android's rcStartMovieDetailed. Bit 10 is
/// authoritative when a page reopens while the camera is already recording.
struct RemoteMovieStartResult: Equatable, Sendable {
    let responseCode: UInt16
    let prohibitCondition: UInt32?

    var indicatesRecording: Bool {
        responseCode == 0x2001 || (prohibitCondition.map { $0 & (1 << 10) != 0 } ?? false)
    }

    var diagnosticSummary: String {
        var result = String(format: "result=0x%04X startOp=0x%04X", responseCode, responseCode)
        if let prohibitCondition {
            result += String(format: " prohibit=0x%08X", prohibitCondition)
        }
        return result
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

    static func startFailed(_ result: RemoteMovieStartResult?) -> Self {
        let detail = result.map { "\n" + $0.diagnosticSummary } ?? ""
        return Self(message: "无法开始录像" + detail, durationNanoseconds: 12_000_000_000)
    }

    static func stopFailed(responseCode: UInt16 = 0xFFFF) -> Self {
        Self(message: String(format: "无法停止录像，请检查相机后重试\nstop=0x%04X", responseCode),
             durationNanoseconds: 6_000_000_000)
    }
}
