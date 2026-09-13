import Foundation

/// A deadline must also return when a system callback never arrives. A task group
/// cannot do that: leaving its scope waits for even a non-cooperative child.
/// The caller must retire an I/O channel after cancellation/timeout before reusing it.
enum AsyncDeadline {
    static func run<Value: Sendable>(
        nanoseconds: UInt64,
        timeoutError: any Error,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let completion = Completion<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard completion.register(continuation) else { return }
                let work = Task {
                    do {
                        try Task.checkCancellation()
                        completion.resolve(.success(try await operation()))
                    } catch {
                        completion.resolve(.failure(error))
                    }
                }
                let timer = Task {
                    do { try await Task.sleep(nanoseconds: nanoseconds) }
                    catch { return }
                    completion.resolve(.failure(timeoutError))
                }
                completion.attach([work, timer])
            }
        } onCancel: {
            completion.resolve(.failure(CancellationError()))
        }
    }

    /// All state is protected by the lock; resume/cancel happen outside it because
    /// either may synchronously enter a cancellation handler. Resolving before
    /// registration and before attaching the tasks are both valid races.
    private final class Completion<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Value, any Error>?
        private var continuation: CheckedContinuation<Value, any Error>?
        private var tasks: [Task<Void, Never>] = []

        func register(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func attach(_ tasks: [Task<Void, Never>]) {
            lock.lock()
            let finished = result != nil
            if !finished { self.tasks = tasks }
            lock.unlock()
            if finished { tasks.forEach { $0.cancel() } }
        }

        func resolve(_ result: Result<Value, any Error>) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            let tasks = self.tasks
            self.tasks.removeAll()
            lock.unlock()
            tasks.forEach { $0.cancel() }
            continuation?.resume(with: result)
        }
    }
}
