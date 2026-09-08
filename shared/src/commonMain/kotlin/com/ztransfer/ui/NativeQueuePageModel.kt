package com.ztransfer.ui

import com.ztransfer.frame.NativePhotoDecimalFormatter
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.screen.TransferQueueUiActions
import com.ztransfer.ui.screen.TransferQueueUiState
import com.ztransfer.viewmodel.*
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.resume

enum class NativeQueueCommand { REMOVE, WITHDRAW, RETRY, RETRY_ALL, WITHDRAW_PENDING, CLEAR, START, PAUSE }
interface NativeQueueActionCompletion { fun complete(succeeded: Boolean) }
interface NativeQueueThumbnailCompletion { fun complete(encodedImage: ByteArray?) }

/** All calls and completions run on the UI thread. Swift awaits its queue actor before completion. */
interface NativeQueuePagePlatform : NativePhotoDecimalFormatter {
    fun showConnectionHelp()
    fun completedSpeed(value: Float): String
    fun execute(command: NativeQueueCommand, taskId: Long, excludedTaskIds: LongArray, completion: NativeQueueActionCompletion)
    fun thumbnail(file: CameraFileInfo, completion: NativeQueueThumbnailCompletion)
    fun cancelRequests()
}

/** Build privately, then publish once. Swift never exposes the actor-owned Kotlin queue itself. */
class NativeQueuePageSnapshot(
    val connectionId: String,
    val sequence: Long,
    val historyRevision: Long,
    val running: Boolean,
    val paused: Boolean,
) {
    private val rows = ArrayList<TransferTask>()
    private val ids = HashSet<Long>()
    private var valid = true

    fun addOriginal(
        taskId: Long, handle: Int, size: Long, name: String, captureDate: String?,
        isProtected: Boolean, storageIds: IntArray, destinationFolderName: String?,
        status: String, downloaded: Long, fraction: Float, bytesPerSecond: Long,
        error: String?, elapsedMs: Long?, downloadMBps: Float, skipped: Boolean = false,
    ): Boolean {
        val state = TransferStatus.entries.firstOrNull { it.name == status }
        if (taskId <= 0 || !ids.add(taskId) || state == null || !fraction.isFinite() ||
            !downloadMBps.isFinite() || downloaded < 0) {
            valid = false
            return false
        }
        rows += TransferTask(
            file = CameraFileInfo(handle, size, name, captureDate, isProtected, storageIds.toSet()),
            taskId = taskId, destinationFolderName = destinationFolderName, status = state,
            downloaded = downloaded, progress = fraction, speed = bytesPerSecond,
            error = error, elapsedMs = elapsedMs, downloadMBps = downloadMBps, skipped = skipped,
        )
        return true
    }

    internal fun validatedRows(): List<TransferTask>? =
        if (valid && rows.count { it.status == TransferStatus.TRANSFERING } <= 1) rows.toList() else null
}

/** Per-page main-thread adapter, not a second transfer executor or persistent app ViewModel. */
class NativeQueuePageModel(val connectionId: String, platform: NativeQueuePagePlatform, val stationMode: Boolean = false) {
    private var platform: NativeQueuePagePlatform? = platform
    private val mutableState = MutableStateFlow(TransferQueueUiState(emptyList(), false, 0L))
    internal val state = mutableState.asStateFlow()
    private val mutableProgress = MutableStateFlow<ActiveTransferProgress?>(null)
    internal val activeProgress = mutableProgress.asStateFlow()
    private val mutableConnected = MutableStateFlow(false)
    internal val connected = mutableConnected.asStateFlow()
    private val mutablePaused = MutableStateFlow(false)
    internal val paused = mutablePaused.asStateFlow()
    private var closed = false
    private var sequence = -1L
    private var historyRevision = -1L
    private var connectionUnavailable = false
    private var retainedSpeed = 0L
    private val actionsPending = HashSet<CancellableContinuation<Boolean>>()
    private val imagesPending = HashSet<CancellableContinuation<ByteArray?>>()

    internal val actions = TransferQueueUiActions(
        removeTask = { execute(NativeQueueCommand.REMOVE, it) },
        withdrawTask = { requireApplied(NativeQueueCommand.WITHDRAW, it) },
        retrySingleTask = { requireApplied(NativeQueueCommand.RETRY, it) },
        retryFailed = { requireApplied(NativeQueueCommand.RETRY_ALL, excluded = it.toLongArray()) },
        withdrawPending = { requireApplied(NativeQueueCommand.WITHDRAW_PENDING) },
        removeCleared = { requireApplied(NativeQueueCommand.CLEAR) },
        currentTasks = { mutableState.value.tasks },
    )

    fun setConnected(value: Boolean) {
        if (closed) return
        mutableConnected.value = value
        connectionUnavailable = !value
        if (!value) {
            retainedSpeed = 0L; mutableProgress.value = null
            mutableState.value = mutableState.value.copy(isTransferring = false)
        }
    }

    fun publish(snapshot: NativeQueuePageSnapshot): Boolean {
        if (closed || snapshot.connectionId != connectionId || snapshot.sequence <= sequence ||
            snapshot.historyRevision < historyRevision) return false
        val rows = snapshot.validatedRows() ?: return false
        val active = rows.firstOrNull { it.status == TransferStatus.TRANSFERING }
        // Swift's single observer forwards history only on low-frequency changes. Byte updates
        // must not churn the page's task list, even though the diagnostic snapshot contains both.
        val running = snapshot.running && !connectionUnavailable
        if (snapshot.historyRevision != historyRevision || mutableState.value.isTransferring != running) {
            mutableState.value = TransferQueueUiState(rows, running, 0L)
        }
        retainedSpeed = if (running) retainLastValidTransferSpeed(retainedSpeed, active?.speed ?: 0) else 0
        mutableProgress.value = if (!running) null else active?.let {
            ActiveTransferProgress(it.taskId, it.progress, it.downloaded, it.speed, retainedSpeed)
        } ?: mutableProgress.value?.copy(bytesPerSecond = 0, retainedBytesPerSecond = retainedSpeed)
        mutablePaused.value = snapshot.paused
        sequence = snapshot.sequence
        historyRevision = snapshot.historyRevision
        return true
    }

    internal suspend fun start() = requireApplied(NativeQueueCommand.START)
    internal suspend fun pause() = requireApplied(NativeQueueCommand.PAUSE)
    internal fun fixed(value: Double, fractionDigits: Int): String = platform?.fixed(value, fractionDigits) ?: value.toString()
    internal fun completedSpeed(value: Float): String = platform?.completedSpeed(value) ?: ""
    internal fun showConnectionHelp() { if (!closed) platform?.showConnectionHelp() }

    private suspend fun requireApplied(command: NativeQueueCommand, taskId: Long = 0, excluded: LongArray = longArrayOf()) {
        if (!execute(command, taskId, excluded)) throw CancellationException("Queue action was not applied")
    }

    private suspend fun execute(command: NativeQueueCommand, taskId: Long = 0, excluded: LongArray = longArrayOf()): Boolean {
        if (closed) throw CancellationException("Queue page closed")
        val owner = platform ?: throw CancellationException("Queue page closed")
        var waiting: CancellableContinuation<Boolean>? = null
        return try {
            withTimeout(15_000L) {
                suspendCancellableCoroutine { continuation ->
                    waiting = continuation
                    actionsPending += continuation
                    owner.execute(command, taskId, excluded, object : NativeQueueActionCompletion {
                        override fun complete(succeeded: Boolean) {
                            if (!closed && continuation.isActive) continuation.resume(succeeded)
                        }
                    })
                }
            }
        } finally { waiting?.let { actionsPending.remove(it) } }
    }

    internal suspend fun thumbnail(file: CameraFileInfo): ByteArray? {
        if (closed) return null
        val owner = platform ?: return null
        var waiting: CancellableContinuation<ByteArray?>? = null
        return try {
            withTimeout(15_000L) {
                suspendCancellableCoroutine { continuation ->
                    waiting = continuation
                    imagesPending += continuation
                    owner.thumbnail(file, object : NativeQueueThumbnailCompletion {
                        override fun complete(encodedImage: ByteArray?) {
                            if (!closed && continuation.isActive) {
                                continuation.resume(encodedImage?.takeIf { it.size <= 1_048_576 })
                            }
                        }
                    })
                }
            }
        } finally { waiting?.let { imagesPending.remove(it) } }
    }

    fun close() {
        if (closed) return
        closed = true
        mutableConnected.value = false
        actionsPending.toList().forEach { it.cancel() }
        imagesPending.toList().forEach { it.cancel() }
        actionsPending.clear(); imagesPending.clear()
        val owner = platform
        platform = null // Break the Swift owner -> model -> owner retain chain.
        owner?.cancelRequests()
    }
}
