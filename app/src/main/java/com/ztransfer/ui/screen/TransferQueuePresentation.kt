package com.ztransfer.ui.screen

import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask

internal enum class QueueActivityState { IDLE, WAITING, RUNNING, PAUSED }

/**
 * Independent summaries of the existing queues, never a second scheduler. Both cards remain
 * mounted even when their summary is idle. Task references come from the current snapshot;
 * completion, removal, and retries cannot retain a previous file or its running statistics.
 * Remaining counts include the current task and admitted waiting tasks, not future effects.
 */
internal data class TransferQueuePresentation(
    /** Only an actual camera download; a waiting task must not look like the next scheduled file. */
    val downloadTask: TransferTask? = null,
    val downloadState: QueueActivityState = QueueActivityState.IDLE,
    val downloadRemaining: Int = 0,
    /** Up to two admitted jobs: actual running work first, then waiting; not two worker claims. */
    val generationTasks: List<TransferTask> = emptyList(),
    val generationState: QueueActivityState = QueueActivityState.IDLE,
    val generationRemaining: Int = 0,
)

internal fun transferQueuePresentation(
    tasks: List<TransferTask>,
    isTransferring: Boolean,
    excludedTaskIds: Set<Long> = emptySet(),
    pauseAfterCurrent: Boolean = false,
): TransferQueuePresentation {
    var download: TransferTask? = null
    var downloadRemaining = 0
    val runningGenerations = ArrayList<TransferTask>(2)
    var waitingGeneration: TransferTask? = null
    var secondWaitingGeneration: TransferTask? = null
    var generationRemaining = 0

    // One pass over structural/status snapshots. High-frequency byte/speed updates stay local
    // to the download UI and do not require another pass through the queue.
    for (task in tasks) {
        // A removal animation may have started before the real task became busy. The execution
        // layer protects busy work, so a stale removal marker cannot hide it in the summaries.
        if (task.taskId in excludedTaskIds &&
            task.status != TransferStatus.TRANSFERING && !task.isGeneratingFrame
        ) continue

        if (task.isGeneratingFrame) {
            // Older crop tasks may still have TRANSFERING status. They belong solely to the
            // generation queue; reporting them as downloads would double-count the same work.
            generationRemaining++
            if (task.frameGenerationStartedAtElapsedMs != null) {
                if (runningGenerations.size < 2) runningGenerations.add(task)
            } else if (waitingGeneration == null || task.taskId < waitingGeneration.taskId) {
                // A stable preparation candidate, not a prediction of which job runs next.
                secondWaitingGeneration = waitingGeneration
                waitingGeneration = task
            } else if (secondWaitingGeneration == null || task.taskId < secondWaitingGeneration.taskId) {
                secondWaitingGeneration = task
            }
        } else when (task.status) {
            TransferStatus.TRANSFERING -> {
                downloadRemaining++
                if (download == null) download = task
            }
            TransferStatus.WAITING -> downloadRemaining++
            else -> Unit
        }
    }

    return TransferQueuePresentation(
        downloadTask = download,
        downloadState = when {
            // Pause is applied after the current file. Until then, live task state wins over
            // the stop request and any batch-flag cleanup occurring around that request.
            download != null -> QueueActivityState.RUNNING
            downloadRemaining == 0 -> QueueActivityState.IDLE
            !isTransferring || pauseAfterCurrent -> QueueActivityState.PAUSED
            else -> QueueActivityState.WAITING
        },
        downloadRemaining = downloadRemaining,
        generationTasks = buildList(2) {
            addAll(runningGenerations)
            if (size < 2) waitingGeneration?.let(::add)
            if (size < 2) secondWaitingGeneration?.let(::add)
        },
        generationState = when {
            runningGenerations.isNotEmpty() -> QueueActivityState.RUNNING
            waitingGeneration != null -> QueueActivityState.WAITING
            else -> QueueActivityState.IDLE
        },
        generationRemaining = generationRemaining,
    )
}

/**
 * Keep a surviving job in its original row. The UI retains IDs only; every returned task comes
 * from the current admitted snapshot, so completion, retry and metadata changes cannot freeze an
 * old filename or stopwatch. A waiting job keeps its row when it starts; its start timestamp,
 * not its row position, determines whether the UI may run a stopwatch.
 */
internal fun stableGenerationSlots(
    previousSlotIds: List<Long?>,
    generationTasks: List<TransferTask>,
): List<TransferTask?> {
    val available = LinkedHashMap<Long, TransferTask>()
    for (task in generationTasks) {
        if (task.isGeneratingFrame) {
            available[task.taskId] = task
        }
    }
    val slots = MutableList<TransferTask?>(2) { index ->
        previousSlotIds.getOrNull(index)?.let { available.remove(it) }
    }
    val newcomers = available.values.iterator()
    for (index in slots.indices) {
        if (slots[index] == null && newcomers.hasNext()) slots[index] = newcomers.next()
    }
    return slots
}
