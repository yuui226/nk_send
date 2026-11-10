import Foundation

/// RemoteDelayedCapture.kt: at most six attempts, cancellable 200 ms backoff.
enum RemoteDelayedCapture {
    static func execute(permission: PTPCommandPermission,
                        command: @Sendable () async throws -> UInt16?,
                        pause: @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(200)) }) async throws -> UInt16? {
        for attempt in 0...5 {
            guard !Task.isCancelled, permission.isCurrent else { return nil }
            guard let response = try await command() else { return nil }
            if response != PTPConstants.deviceBusy || attempt == 5 { return response }
            try await pause()
        }
        return nil
    }
}
