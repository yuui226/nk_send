package com.ztransfer.ui.screen

import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import com.ztransfer.viewmodel.isQueuedForFrameGeneration

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
    /** All admitted jobs: running work first, then waiting. The UI renders only a bounded window. */
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
    val waitingGenerations = ArrayList<TransferTask>()
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
            // Existing-output checks remain busy, but are not confirmed generation work yet.
            if (!task.isQueuedForFrameGeneration) continue
            generationRemaining++
            if (task.frameGenerationStartedAtElapsedMs != null) {
                runningGenerations.add(task)
            } else {
                waitingGenerations.add(task)
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

    // Sort only admitted waiting jobs, on structural changes, never on byte/clock updates.
    waitingGenerations.sortBy { it.taskId }
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
        generationTasks = buildList(generationRemaining) {
            addAll(runningGenerations)
            addAll(waitingGenerations)
        },
        generationState = when {
            runningGenerations.isNotEmpty() -> QueueActivityState.RUNNING
            waitingGenerations.isNotEmpty() -> QueueActivityState.WAITING
            else -> QueueActivityState.IDLE
        },
        generationRemaining = generationRemaining,
    )
}
