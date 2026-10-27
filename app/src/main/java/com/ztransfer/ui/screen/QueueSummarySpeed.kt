package com.ztransfer.ui.screen

import com.ztransfer.viewmodel.ActiveTransferProgress
import com.ztransfer.viewmodel.TransferTask

/** Display-only speed. A new download may borrow its batch's last sample, never its progress. */
internal fun queueSummarySpeed(
    displayed: TransferTask?,
    completed: TransferTask?,
    progress: ActiveTransferProgress?,
    state: QueueActivityState,
): Long? {
    if (completed != null) {
        return completed.downloadMBps.takeIf { it.isFinite() && it > 0f }
            ?.let { (it * 1024 * 1024).toLong() }?.takeIf { it > 0L }
            ?: completed.speed.takeIf { it > 0L }
    }
    if (displayed != null) {
        val own = progress?.takeIf { it.taskId == displayed.taskId }
        return own?.bytesPerSecond?.takeIf { it > 0L }
            ?: own?.retainedBytesPerSecond?.takeIf { it > 0L }
            ?: displayed.speed.takeIf { it > 0L }
    }
    // Keep the label through the batch's short preparation gaps, but not while idle/paused.
    return progress?.retainedBytesPerSecond?.takeIf { state == QueueActivityState.WAITING && it > 0L }
}
