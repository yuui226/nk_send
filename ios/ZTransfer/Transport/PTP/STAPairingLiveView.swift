import Foundation
import ImageIO

/// StaPairingLiveView.kt: new pairing only. This unpublished session has no
/// monitoring/keepalive owner; PTPSession serializes every probe and cleanup.
enum STAPairingLiveView {
    static func verify(session: PTPSession, operations: Set<UInt16>, trace: STAConnectionTrace,
                       confirmation: STAPairingConfirmation? = nil,
                       abort: @escaping @Sendable () -> Void = {},
                       now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                       sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws {
        let deadline = now().advanced(by: .seconds(8))
        var startedHere = false, streamUsable = true, valid = false, remoteRequestAttempted = false
        func command(_ code: UInt16, _ params: [UInt32] = []) async throws -> PTPResponse {
            try Task.checkCancellation()
            let remaining = now().duration(to: deadline)
            guard remaining > .zero else { throw PTPSessionError.timeout }
            let parts = min(remaining, .seconds(5)).components
            let timeout = UInt64(max(1, parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000))
            if code == 0x9201 || code == 0x9428 || code == 0x9203 { remoteRequestAttempted = true }
            do {
                // Await a fully delivered response even if the caller cancels,
                // so ownership of a just-started monitor is not lost. A later
                // cancellation check rejects its result after safe cleanup.
                let request = Task { try await session.executeResponse(operation: code, parameters: params, timeoutNanoseconds: timeout) }
                let reply = try await request.value
                trace.note(String(format: "pairing live-view op=0x%04X rc=0x%04X bytes=%d", code, reply.code, reply.data.count))
                return reply
            } catch {
                streamUsable = false; abort(); _ = await session.invalidate(); throw error
            }
        }
        var failure: (any Error)?
        do {
            let status = try await command(0x1015, [0xD1A2])
            guard status.code == 0x2001, status.data.count == 1, status.data[0] <= 1 else { throw STAConnectionError.pairingNotConfirmed }
            if status.data[0] == 0 {
                var start = try await command(0x9201).code
                for _ in 0..<5 where start == 0x2019 || start == 0xA004 {
                    try await sleep(.milliseconds(200)); start = try await command(0x9201).code
                }
                guard start == 0x2001 else { throw PTPSessionError.responseCode(start) }
                startedHere = true
                var ready = try await command(0x90C8).code
                for _ in 0..<20 where ready == 0x2019 {
                    try await sleep(.milliseconds(100)); ready = try await command(0x90C8).code
                }
            }
            var operation: UInt16 = operations.contains(0x9428) ? 0x9428 : 0x9203
            var enhancedFailures = 0
            while now() < deadline {
                let frame = try await command(operation)
                if frame.code == 0x2001, validFrame(frame.data) {
                    valid = true; trace.note("pairing live-view=VALID_FRAME"); break
                }
                let warming = frame.code == 0x2019 || frame.code == 0xA00B
                if operation == 0x9428 && !warming {
                    enhancedFailures += 1
                    if frame.code == 0x2005 || enhancedFailures >= 2 { operation = 0x9203; continue }
                } else if operation == 0x9203 && frame.code != 0x2001 && !warming {
                    throw PTPSessionError.responseCode(frame.code)
                }
                try await sleep(.milliseconds(100))
            }
            guard valid else { throw STAConnectionError.pairingNotConfirmed }
        } catch { failure = error }
        var cleanupFailed = false
        if startedHere && streamUsable {
            do {
                let cleanup = Task.detached { try await session.executeResponse(operation: 0x9202, timeoutNanoseconds: 5_000_000_000) }
                let reply = try await cleanup.value
                trace.note(String(format: "pairing live-view end=0x%04X", reply.code))
                guard reply.code == 0x2001 || reply.code == 0xA00B else { throw PTPSessionError.responseCode(reply.code) }
            } catch { abort(); _ = await session.invalidate(); failure = error; cleanupFailed = true }
        }
        try Task.checkCancellation()
        if let failure {
            if failure is CancellationError { throw failure }
            if valid && cleanupFailed, var receipt = confirmation {
                receipt.remotePermissionVerified = true
                throw STAPairingCleanupFailure(confirmation: receipt, cause: failure)
            }
            trace.note("pairing live-view=UNCONFIRMED reason=\(failure)")
            throw STAPairingVerificationFailure(cause: failure, remoteRequestAttempted: remoteRequestAttempted)
        }
    }

    /// Finish a previously interrupted cleanup exactly once, before browsing.
    /// The validated frame remains proof: do not re-pair or start another LV.
    static func finishCleanup(session: PTPSession, confirmation: STAPairingConfirmation,
                              responderGUID: String?, trace: STAConnectionTrace,
                              abort: @escaping @Sendable () -> Void,
                              now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                              sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws {
        let deadline = STAHandshakeDeadline(nanoseconds: 5_000_000_000, now: now)
        func command(_ code: UInt16, _ params: [UInt32] = []) async throws -> PTPResponse {
            try Task.checkCancellation()
            let reply = try await session.executeResponse(operation: code, parameters: params,
                timeoutNanoseconds: deadline.remainingNanoseconds())
            trace.note(String(format: "pairing cleanup op=0x%04X rc=0x%04X", code, reply.code))
            return reply
        }
        do {
            guard confirmation.remotePermissionVerified, confirmation.responderGUID == responderGUID else {
                throw STAConnectionError.pairingNotConfirmed
            }
            var endSent = false
            while true {
                let status = try await command(0x1015, [0xD1A2])
                guard status.code == 0x2001, status.data.count == 1, status.data[0] <= 1 else {
                    throw STAConnectionError.pairingNotConfirmed
                }
                if status.data[0] == 0 { try Task.checkCancellation(); return }
                if !endSent {
                    endSent = true
                    let end = try await command(0x9202)
                    guard end.code == 0x2001 || end.code == 0xA00B else { throw PTPSessionError.responseCode(end.code) }
                    continue
                }
                try await sleep(.nanoseconds(Int64(try deadline.remainingNanoseconds(idleLimit: 100_000_000))))
            }
        } catch {
            abort(); _ = await session.invalidate()
            try Task.checkCancellation()
            throw STAPairingCleanupFailure(confirmation: confirmation, cause: error)
        }
    }

    static func validFrame(_ data: Data) -> Bool {
        guard let jpeg = STAMediaMetadata.largestEmbeddedJPEG(data),
              let source = CGImageSourceCreateWithData(data.subdata(in: jpeg.offset..<(jpeg.offset + jpeg.length)) as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = values[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = values[kCGImagePropertyPixelHeight] as? NSNumber else { return false }
        return width.intValue > 0 && height.intValue > 0
    }
}
