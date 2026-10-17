import Foundation

/// Android collectPhotoEffectsPreviewTransitions: finish the accepted transition,
/// keep only the newest pending frame, and cancel only when the view leaves.
@MainActor
final class ConflatedPreviewUpdates<Value> {
    private var pending: Value?
    private var latest: Value?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func submit(_ value: Value,
                operation: @escaping @MainActor (Value, @escaping @MainActor () -> Value) async -> Void) {
        pending = value; latest = value
        guard task == nil else { return }
        let generation = generation
        task = Task { [self] in
            while !Task.isCancelled, self.generation == generation, let next = pending {
                pending = nil
                await operation(next, { self.latest ?? next })
            }
            if self.generation == generation { task = nil }
        }
    }

    func close() {
        generation = UUID(); task?.cancel(); task = nil; pending = nil; latest = nil
    }
}
