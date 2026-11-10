import Combine
import Foundation

/// RemoteSelfTimer.kt (ca03503c). One owner survives orientation changes.
/// Per-second notifications reach only the shutter; active edges update gates.
@MainActor
final class RemoteSelfTimer: ObservableObject {
    // Android 89018097; restoring the removed 20-second value falls back to off.
    static let options = [0, 2, 3, 5, 10, 30]
    @Published private(set) var active = false
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var focusing = false
    var onActiveChanged: (Bool) -> Void = { _ in }
    private let now: () -> ContinuousClock.Instant
    private let sleep: (Duration) async throws -> Void
    private var worker: Task<Void, Never>?
    private var permission: PTPCommandPermission?

    init(now: @escaping () -> ContinuousClock.Instant = { .now },
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.now = now; self.sleep = sleep
    }

    @discardableResult
    func start(seconds: Int, isValid: @escaping () -> Bool,
               focus: @escaping () async throws -> Bool,
               capture: @escaping (PTPCommandPermission) async throws -> Void,
               onFailure: @escaping (any Error) -> Void) -> Bool {
        guard !active, seconds >= 0, !Task.isCancelled, isValid() else { return false }
        let permission = PTPCommandPermission()
        self.permission = permission
        onActiveChanged(true); active = true
        let deadline = now().advanced(by: .seconds(seconds))
        worker = Task { [self] in
            defer {
                permission.invalidate()
                remainingSeconds = 0; focusing = false; worker = nil; self.permission = nil
                onActiveChanged(false); active = false
            }
            func valid() -> Bool { !Task.isCancelled && permission.isCurrent && isValid() }
            do {
                while valid() {
                    let remaining = now().duration(to: deadline)
                    if remaining <= .zero { break }
                    let parts = remaining.components
                    let count = Int(parts.seconds) + (parts.attoseconds > 0 ? 1 : 0)
                    if remainingSeconds != count { remainingSeconds = count }
                    try await sleep(remaining - .seconds(count - 1))
                }
                guard valid() else { return }
                remainingSeconds = 0; focusing = true
                // An already dispatched AF owns its response even after Cancel.
                let autofocus = Task { try await focus() }
                let focused = try await autofocus.value
                guard valid() else { return }
                focusing = false
                if focused { try await capture(permission) }
            } catch is CancellationError {
            } catch {
                if valid() { onFailure(error) }
            }
        }
        return true
    }

    func cancel() {
        permission?.invalidate()
        remainingSeconds = 0; focusing = false
        worker?.cancel()
        // Keep active until an accepted AF/shutter response has drained.
    }

    func cancelAndWait() async {
        let pending = worker
        cancel()
        await pending?.value
    }
}
