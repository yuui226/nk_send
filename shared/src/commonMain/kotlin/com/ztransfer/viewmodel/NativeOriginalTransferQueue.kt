package com.ztransfer.viewmodel

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.protocol.PtpObjectInfo
import com.ztransfer.protocol.endToEndBytesPerSecond

/**
 * Narrow original-file queue adapter for the Apple coordinator. Uses the existing shared queue,
 * execution state and history reducers; contains no sockets, files, scheduling or Apple types.
 * Not the effect/entitlement/export pipeline: those snapshots are still separate integration work.
 * Unsynchronized: a single platform actor must own every call.
 */
class NativeOriginalTransferQueue {
    private val pending = TransferTaskQueue<TransferTask>()
    private var tasks = emptyList<TransferTask>()
    private var execution = TransferExecutionState()
    private var nextId = 1L
    private var activeId: Long? = null
    private var activeProgress: ActiveTransferProgress? = null

    val count: Int get() = tasks.size
    val running: Boolean get() = execution.isTransferring
    val paused: Boolean get() = execution.pauseAfterCurrent
    fun taskAt(index: Int): TransferTask? = tasks.getOrNull(index)?.withActiveProgress(activeProgress)
    /** Low-frequency history, without copying active byte samples into every page update. */
    fun taskSnapshotAt(index: Int): TransferTask? = tasks.getOrNull(index)
    fun progressSnapshot(): ActiveTransferProgress? = activeProgress

    fun progress(taskId: Long, downloaded: Long, total: Long, bytesPerSecond: Long) {
        if (activeId != taskId || downloaded < 0 || downloaded < (activeProgress?.downloaded ?: 0)) return
        // Same presentation arithmetic as TransferViewModel's DownloadProgress adapter. The live
        // sample stays separate from history, and withActiveProgress protects task/status identity.
        activeProgress = ActiveTransferProgress(taskId = taskId,
            fraction = if (total > 0) (downloaded.toDouble() / total).toFloat().coerceIn(0f, 1f) else 0f,
            downloaded = downloaded, bytesPerSecond = bytesPerSecond,
            retainedBytesPerSecond = retainLastValidTransferSpeed(activeProgress?.retainedBytesPerSecond ?: 0, bytesPerSecond))
    }

    fun enqueue(info: PtpObjectInfo, byDate: Boolean, dayKey: Int): TransferTask? {
        if (info.isAssociation || !info.identityComplete || info.fileName == null || nextId == Long.MAX_VALUE) return null
        return enqueueFile(CameraFileInfo(info.handle, info.size, info.fileName, info.captureDate, info.isProtected,
            if (info.storageId == 0 || info.storageId == -1) emptySet() else setOf(info.storageId)), byDate, dayKey)
    }

    /** Preserve the merged catalog's storage membership without admitting a stale/mismatched object. */
    fun enqueueCatalog(info: PtpObjectInfo, file: CameraFileInfo, byDate: Boolean, dayKey: Int): TransferTask? {
        if (info.isAssociation || !info.identityComplete || info.handle != file.handle || info.size != file.size ||
            info.fileName != file.fileName || info.captureDate != file.captureDate || info.isProtected != file.isProtected ||
            nextId == Long.MAX_VALUE) return null
        return enqueueFile(file.copy(storageIds = file.storageIds.toSet()), byDate, dayKey)
    }

    private fun enqueueFile(file: CameraFileInfo, byDate: Boolean, dayKey: Int): TransferTask {
        val task = TransferTask(
            file = file,
            taskId = nextId++,
            destinationFolderName = transferDestinationFolderName(file.captureDate, byDate, dayKey),
        )
        // Like Android manual enqueue: separate requests may export the same file again.
        tasks = tasks + task
        pending.addAll(listOf(task))
        return task
    }

    fun shouldAutoStart(deferred: Boolean): Boolean =
        shouldRunQueueAfterEnqueue(deferred, running, paused)

    fun start(): Boolean {
        if (running || tasks.none { it.status == TransferStatus.WAITING }) return false
        execution = execution.resumed().started()
        return true
    }

    fun pauseAfterCurrent() { execution = execution.pauseRequested() }

    fun takeNext(): TransferTask? {
        if (!running || activeId != null || shouldPauseBeforeNextTransfer(paused, false)) return null
        val task = pending.takeFirst() ?: return null
        if (pending.consumeWithdrawal(task.taskId)) return null
        activeId = task.taskId
        activeProgress = null
        val started = task.copy(status = TransferStatus.TRANSFERING, speed = 0L, error = null)
        tasks = tasks.map { if (it.taskId == task.taskId) started else it }
        return started
    }

    fun completed(taskId: Long, bytes: Long, elapsedMs: Long) {
        if (activeId != taskId) return
        tasks = tasks.map { task ->
            if (task.taskId == taskId) task.copy(status = TransferStatus.COMPLETED, progress = 1f,
                downloaded = bytes, speed = 0L, elapsedMs = elapsedMs,
                downloadMBps = endToEndBytesPerSecond(bytes, elapsedMs) / (1024f * 1024f), error = null) else task
        }
        activeId = null
        activeProgress = null
    }

    fun failed(taskId: Long, message: String?, cancelled: Boolean) {
        if (activeId != taskId) return
        tasks = tasks.map { task ->
            if (task.taskId == taskId) task.withActiveProgress(activeProgress).copy(status = if (cancelled) TransferStatus.CANCELLED else TransferStatus.FAILED,
                speed = 0L, error = message) else task
        }
        activeId = null
        activeProgress = null
    }

    fun finishRun() {
        if (activeId == null) execution = execution.finished(stoppedAfterCurrent = paused)
    }

    fun withdraw(taskId: Long) {
        if (tasks.none { it.taskId == taskId && it.status == TransferStatus.WAITING }) return
        pending.withdraw(listOf(taskId))
        tasks = withdrawWaitingTransferTasks(tasks, taskId)
    }

    fun clearTerminal() { tasks = keepUnclearedTransferTasks(tasks) }

    /** Same withdrawal-before-animation boundary as Android; never interrupts the active file. */
    fun withdrawPending() {
        val waitingIds = tasks.asSequence().filter { it.status == TransferStatus.WAITING }
            .mapTo(HashSet()) { it.taskId }
        pending.withdraw(waitingIds)
        tasks = withdrawWaitingTransferTasks(tasks)
    }

    fun removeTask(taskId: Long): Boolean {
        val kept = removeTransferTaskIfTerminal(tasks, taskId)
        val removed = kept.size != tasks.size
        tasks = kept
        return removed
    }

    /** Iterate the history order, not the unordered retry-id set, to retain FIFO ordering. */
    fun retryFailed(excludedTaskIds: Set<Long>): Int {
        val retryIds = retryableTransferTaskIds(tasks, excludedTaskIds)
        val retryOrder = tasks.filter { it.taskId in retryIds }.map { it.taskId }
        return retryOrder.count { retry(it) != null }
    }

    fun retry(taskId: Long): TransferTask? {
        if (nextId == Long.MAX_VALUE) return null
        val previous = tasks.firstOrNull { it.taskId == taskId } ?: return null
        if (previous.status != TransferStatus.FAILED && previous.status != TransferStatus.CANCELLED) return null
        val attempt = previous.newAttempt(nextId++)
        tasks = replaceRetryableTransferTasks(tasks, mapOf(taskId to attempt))
        pending.addAll(listOf(attempt))
        return attempt
    }
}
