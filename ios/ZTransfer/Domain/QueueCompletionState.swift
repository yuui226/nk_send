import Foundation

/// Android QueueCompletionState.kt. Only current-batch outcomes survive card
/// removal; terminal history on first observation never emits a completion.
struct QueueCompletionState: Equatable {
    var unresolvedTaskIDs: Set<UUID> = []
    var hadUnsuccessfulResult = false
    var didRealWork = false
    var knownTaskIDs: Set<UUID>?
}

struct QueueCompletionFeedback: Equatable {
    let showDone: Bool
    let celebrate: Bool
}

struct QueueCompletionUpdate: Equatable {
    let state: QueueCompletionState
    var feedback: QueueCompletionFeedback?
}

func queueCompletionUpdate(previous: QueueCompletionState, items: [TransferQueueItem]) -> QueueCompletionUpdate {
    let hadPending = !previous.unresolvedTaskIDs.isEmpty
    var missing = previous.unresolvedTaskIDs
    var unfinished = Set<UUID>(), known = Set<UUID>()
    var unsuccessful = hadPending && previous.hadUnsuccessfulResult
    var worked = hadPending && previous.didRealWork
    for item in items {
        known.insert(item.id)
        let wasPending = missing.remove(item.id) != nil
        let newlyObserved = previous.knownTaskIDs.map { !$0.contains(item.id) } ?? false
        // Pending existence checks are unfinished even though visible counts
        // omit them. A coalesced new terminal result still belongs to this batch.
        if item.status == .waiting || item.status == .transferring || item.isGeneratingFrame {
            unfinished.insert(item.id)
        } else if wasPending || newlyObserved {
            if item.status == .completed && item.frameError == nil {
                worked = worked || item.elapsedMs != nil || item.frameGenerationElapsedMs != nil
            } else { unsuccessful = true }
        }
    }
    if !missing.isEmpty { unsuccessful = true }
    if unfinished.isEmpty {
        return .init(state: .init(knownTaskIDs: known), feedback: hadPending
            ? .init(showDone: !unsuccessful, celebrate: !unsuccessful && worked) : nil)
    }
    return .init(state: .init(unresolvedTaskIDs: unfinished, hadUnsuccessfulResult: unsuccessful,
                             didRealWork: worked, knownTaskIDs: known))
}

/// Read-only-to-SwiftUI memoization: structural inputs advance the reducer
/// once; speed, width and display frames reuse the same result and event ID.
/// The View consumes that event separately, never from inside this cache.
final class QueueCompletionTracker {
    struct Observation: Equatable {
        let revision: UInt64
        let update: QueueCompletionUpdate
    }
    private var items: [TransferQueueItem]?
    private var observation = Observation(revision: 0, update: .init(state: .init()))
    func observe(_ next: [TransferQueueItem]) -> Observation {
        guard items != next else { return observation }
        items = next
        observation = .init(revision: observation.revision &+ 1,
            update: queueCompletionUpdate(previous: observation.update.state, items: next))
        return observation
    }
}
