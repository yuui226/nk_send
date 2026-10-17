import Foundation

/// CameraViewModel.startKeepalive: a successful/busy probe resets failures;
/// first failure adds 1s before the next regular 10s interval, second loses it.
enum WiFiKeepaliveLoop {
    static func run(
        probe: @Sendable () async -> Bool,
        sleep: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        onLost: @Sendable () async -> Void
    ) async {
        var failures = 0
        do {
            while !Task.isCancelled {
                try await sleep(10_000_000_000)
                try Task.checkCancellation()
                let alive = await probe()
                try Task.checkCancellation()
                if alive { failures = 0; continue }
                failures += 1
                if failures >= 2 {
                    await onLost()
                    return
                }
                try await sleep(1_000_000_000)
            }
        } catch {
            // Cancelled timers do not report transport loss. The session owner
            // handles explicit teardown/replacement independently.
        }
    }
}
