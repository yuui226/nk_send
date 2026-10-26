package com.ztransfer.ui.screen

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import com.ztransfer.ui.theme.Motion
import com.ztransfer.viewmodel.ActiveTransferProgress
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.launch

/** A single visible download, with a bounded finish animation that never queues camera work. */
@Stable
internal class QueueDownloadDisplay internal constructor(initialTask: TransferTask?) {
    var task by mutableStateOf(initialTask)
        internal set
    var completing by mutableStateOf(false)
        internal set
    internal val animation = Animatable(0f)
    val progress: State<Float> = animation.asState()
}

private data class QueueDownloadInput(
    val tasks: List<TransferTask>,
    val activeTask: TransferTask?,
    val activeProgress: ActiveTransferProgress?,
    val animate: Boolean,
)

internal fun queueDownloadActiveTask(task: TransferTask?): TransferTask? = task?.takeIf {
    it.status == TransferStatus.TRANSFERING && !it.isGeneratingFrame
}

/** An old progress sample must never advance a new file or create progress for local effects. */
internal fun queueDownloadTargetProgress(task: TransferTask?, progress: ActiveTransferProgress?): Float {
    val active = queueDownloadActiveTask(task) ?: return 0f
    return normalizedTransferProgress(progress?.takeIf { it.taskId == active.taskId }?.fraction ?: active.progress)
}

/** Only a download actually presented by this UI can earn a successful completion animation. */
internal fun queueDownloadCompletedTask(
    displayedTaskId: Long?,
    activeTask: TransferTask?,
    tasks: List<TransferTask>,
): TransferTask? {
    if (displayedTaskId == null || displayedTaskId == queueDownloadActiveTask(activeTask)?.taskId) return null
    return tasks.firstOrNull { it.taskId == displayedTaskId }?.takeIf {
        it.status == TransferStatus.COMPLETED ||
            // Legacy crop work retains TRANSFERING while its already-downloaded bytes are
            // processed. This is a successful download boundary, not another download.
            (it.status == TransferStatus.TRANSFERING && it.isGeneratingFrame)
    }
}

/**
 * The pill and queue summary share this display-only handoff. Normal byte updates animate in
 * a cancellable child; only a successful visible file holds its identity for 120ms of fill and
 * 40ms at full. During that hold the input is conflated, then the latest actual download wins.
 * No queue of visual transitions, transfer delay, generation-derived progress, or stale owner.
 */
@Composable
internal fun rememberQueueDownloadDisplay(
    tasks: List<TransferTask>,
    activeTask: TransferTask?,
    activeProgress: ActiveTransferProgress?,
    animate: Boolean = true,
): QueueDownloadDisplay {
    val latest by rememberUpdatedState(QueueDownloadInput(tasks, activeTask, activeProgress, animate))
    val display = remember { QueueDownloadDisplay(queueDownloadActiveTask(activeTask)) }

    LaunchedEffect(display) {
        var progressJob: Job? = null
        var acceptedFraction = 0f
        try {
            snapshotFlow { latest }.conflate().collect {
                // Read the latest value rather than a buffered event: a newer file may already
                // have started/finished while the previous visible file was filling to 100%.
                var input = latest
                val current = queueDownloadActiveTask(input.activeTask)
                if (!input.animate) {
                    // A fully hidden capsule follows the current download without running
                    // progress springs or retaining invisible completion animations.
                    progressJob?.cancelAndJoin()
                    progressJob = null
                    val target = queueDownloadTargetProgress(current, input.activeProgress)
                    acceptedFraction = if (display.task?.taskId == current?.taskId)
                        maxOf(acceptedFraction, target) else target
                    display.animation.snapTo(acceptedFraction)
                    display.task = current
                    display.completing = false
                    return@collect
                }
                if (display.task?.taskId != current?.taskId) {
                    progressJob?.cancelAndJoin()
                    progressJob = null
                    val completed = queueDownloadCompletedTask(display.task?.taskId, current, input.tasks)
                    if (completed != null) {
                        display.task = completed
                        display.completing = true
                        display.animation.animateTo(1f, tween(120, easing = FastOutSlowInEasing))
                        delay(40L)
                    }
                    input = latest
                    display.animation.snapTo(0f)
                    display.task = queueDownloadActiveTask(input.activeTask)
                    display.completing = false
                    acceptedFraction = 0f
                }

                val actual = queueDownloadActiveTask(input.activeTask)
                display.task = actual
                val fraction = queueDownloadTargetProgress(actual, input.activeProgress)
                // Generation/count changes do not restart a download animation with the same
                // target. Protocol samples may momentarily regress; visible progress may not.
                if (fraction > acceptedFraction) {
                    acceptedFraction = fraction
                    val velocity = display.animation.velocity
                    progressJob?.cancelAndJoin()
                    progressJob = launch {
                        display.animation.animateTo(fraction, Motion.progress, initialVelocity = velocity)
                    }
                }
            }
        } finally {
            progressJob?.cancel()
        }
    }
    return display
}
