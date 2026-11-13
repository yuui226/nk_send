package com.ztransfer.ui.screen

import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask

/** Batch outcomes outlive removed cards; the identity baseline contains only the current snapshot. */
internal data class QueueCompletionState(
    val unresolvedTaskIds: Set<Long> = emptySet(),
    val hadUnsuccessfulResult: Boolean = false,
    val didRealWork: Boolean = false,
    /** Null before the first snapshot, whose terminal tasks establish history rather than outcomes. */
    val knownTaskIds: Set<Long>? = null,
)

internal data class QueueCompletionFeedback(
    val showDone: Boolean,
    val celebrate: Boolean,
)

internal data class QueueCompletionUpdate(
    val nextState: QueueCompletionState,
    val completion: QueueCompletionFeedback? = null,
)

/**
 * Resolve one low-frequency task snapshot without changing UI state. A batch ends only after
 * all observed downloads and generation work settle, including paused/waiting members.
 * Outcomes are folded before terminal cards can be removed, so clearing history cannot turn
 * a failed batch into a success. Work that disappears without a terminal outcome is unsuccessful.
 * The caller commits [QueueCompletionUpdate.nextState] once after consuming this snapshot.
 */
internal fun queueCompletionUpdate(
    previous: QueueCompletionState,
    tasks: List<TransferTask>,
): QueueCompletionUpdate {
    val hadPendingWork = previous.unresolvedTaskIds.isNotEmpty()
    val missingPreviousIds = previous.unresolvedTaskIds.toMutableSet()
    val unfinishedIds = LinkedHashSet<Long>()
    val knownIds = HashSet<Long>()
    var hadUnsuccessfulResult = hadPendingWork && previous.hadUnsuccessfulResult
    var didRealWork = hadPendingWork && previous.didRealWork

    tasks.forEach { task ->
        knownIds += task.taskId
        val wasUnresolved = missingPreviousIds.remove(task.taskId)
        // StateFlow/Compose may coalesce a fast task's entire unfinished phase. A new terminal
        // member belongs to an open batch, including one first observed in this snapshot;
        // without unfinished work the reset below discards it as idle history. IDs can
        // publish out of allocation order, so this must use membership rather than a high-water ID.
        val newlyObservedInBatch = previous.knownTaskIds != null &&
            task.taskId !in previous.knownTaskIds
        val unfinished = task.status == TransferStatus.WAITING ||
            task.status == TransferStatus.TRANSFERING || task.isGeneratingFrame
        if (unfinished) {
            unfinishedIds += task.taskId
        } else if (wasUnresolved || newlyObservedInBatch) {
            val succeeded = task.status == TransferStatus.COMPLETED &&
                task.frameGenerationError == null
            if (succeeded) {
                // Queued generation may merely discover an existing output. Its busy flag
                // alone does not prove that a download or saved generation actually happened.
                didRealWork = didRealWork || task.elapsedMs != null ||
                    task.frameGenerationElapsedMs != null
            } else {
                hadUnsuccessfulResult = true
            }
        }
    }
    if (missingPreviousIds.isNotEmpty()) hadUnsuccessfulResult = true

    if (unfinishedIds.isEmpty()) {
        return QueueCompletionUpdate(
            nextState = QueueCompletionState(knownTaskIds = knownIds),
            completion = if (hadPendingWork) {
                QueueCompletionFeedback(
                    showDone = !hadUnsuccessfulResult,
                    celebrate = !hadUnsuccessfulResult && didRealWork,
                )
            } else null,
        )
    }

    return QueueCompletionUpdate(
        nextState = QueueCompletionState(
            unresolvedTaskIds = unfinishedIds.toSet(),
            hadUnsuccessfulResult = hadUnsuccessfulResult,
            didRealWork = didRealWork,
            knownTaskIds = knownIds,
        ),
    )
}
