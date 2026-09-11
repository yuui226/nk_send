package com.ztransfer.viewmodel

enum class TransferStatus {
    WAITING, TRANSFERING, COMPLETED, FAILED, CANCELLED
}

/** Minimal read-only boundary used by shared queue policies. */
interface TransferQueueItem {
    val taskId: Long
    val status: TransferStatus
}

/**
 * The only high-frequency state for the active download. Keeping it separate avoids copying the
 * complete task history for every protocol progress sample.
 */
data class ActiveTransferProgress(
    val taskId: Long,
    val fraction: Float = 0f,
    val downloaded: Long = 0L,
    val bytesPerSecond: Long = 0L,
    val retainedBytesPerSecond: Long = 0L,
)

/** Queue-wide execution flags and their user-visible pause/resume transitions. */
data class TransferExecutionState(
    val isTransferring: Boolean = false,
    val pauseAfterCurrent: Boolean = false,
) {
    fun started(): TransferExecutionState = copy(
        isTransferring = true,
        pauseAfterCurrent = false,
    )

    fun pauseRequested(): TransferExecutionState =
        if (isTransferring) copy(pauseAfterCurrent = true) else this

    fun resumed(): TransferExecutionState = copy(pauseAfterCurrent = false)

    fun finished(stoppedAfterCurrent: Boolean): TransferExecutionState = TransferExecutionState(
        isTransferring = false,
        pauseAfterCurrent = stoppedAfterCurrent,
    )
}

/**
 * Ordered pending work and preflight-withdrawal state. Callers provide platform synchronization;
 * Android keeps its existing lock and iOS can use its actor/lock boundary.
 */
class TransferTaskQueue<T : TransferQueueItem> {
    private val tasks = LinkedHashMap<Long, T>()
    private val withdrawnClaimedTaskIds = HashSet<Long>()

    fun addAll(newTasks: Collection<T>) {
        newTasks.forEach { tasks[it.taskId] = it }
    }

    fun takeFirst(): T? {
        val iterator = tasks.entries.iterator()
        if (!iterator.hasNext()) return null
        return iterator.next().also { iterator.remove() }.value
    }

    /** Queued items are removed; already claimed preflight items receive a withdrawal marker. */
    fun withdraw(taskIds: Collection<Long>) {
        taskIds.forEach { taskId ->
            if (tasks.remove(taskId) == null) withdrawnClaimedTaskIds += taskId
        }
    }

    fun consumeWithdrawal(taskId: Long): Boolean = withdrawnClaimedTaskIds.remove(taskId)

    fun clear() {
        tasks.clear()
        withdrawnClaimedTaskIds.clear()
    }
}

/**
 * A running queue may keep accepting work unless a pause boundary has been requested. When idle,
 * the deferred-start preference controls whether the first queued item starts itself.
 */
fun shouldRunQueueAfterEnqueue(
    deferTransferStart: Boolean,
    isTransferring: Boolean,
    pauseAfterCurrent: Boolean,
): Boolean = !pauseAfterCurrent && (isTransferring || !deferTransferStart)

/** A local existing-file recheck is still part of the claimed task, not the next queue item. */
fun shouldPauseBeforeNextTransfer(
    pauseAfterCurrent: Boolean,
    isRecheckingCurrentTask: Boolean,
): Boolean = pauseAfterCurrent && !isRecheckingCurrentTask

fun retainLastValidTransferSpeed(previous: Long, sample: Long): Long =
    if (sample > 0L) sample else previous.coerceAtLeast(0L)

fun retryableTransferTaskIds(
    tasks: List<TransferQueueItem>,
    excludedTaskIds: Set<Long>,
): Set<Long> = tasks.asSequence()
    .filter { task ->
        task.taskId !in excludedTaskIds &&
            (task.status == TransferStatus.FAILED || task.status == TransferStatus.CANCELLED)
    }
    .mapTo(HashSet()) { it.taskId }
