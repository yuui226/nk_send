package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraFileInfo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** UI-confined optional asynchronous acknowledgement. Does not own or roll back the queue. */
internal class PreviewQueueAcceptance {
    private var closed = false
    private var token: Any? = null
    private var job: Job? = null

    /** True means a request was started, NOT that any file has been accepted. */
    fun request(
        scope: CoroutineScope,
        files: List<CameraFileInfo>,
        isCurrent: () -> Boolean,
        enqueue: suspend (List<CameraFileInfo>) -> Int,
        onAccepted: () -> Unit,
    ): Boolean {
        if (closed || token != null || !scope.isActive || files.isEmpty() || !isCurrent()) return false
        val frozen = files.toList()
        val request = Any()
        token = request
        val work = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                val count = try { enqueue(frozen) }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { return@launch } // Source owns the failure notice; never invent success.
                // A burst ghost depicts the entire group. Partial acceptance is reported by the model,
                // not animated as a full-group success; already accepted queue tasks are never undone.
                if (!closed && token === request && isActive && isCurrent() && count == frozen.size) {
                    onAccepted()
                }
            } finally {
                if (token === request) { token = null; job = null }
            }
        }
        // A synchronous callback may already have finished (or started another request).
        if (token === request) job = work
        return true
    }

    fun cancel() {
        token = null
        val previous = job; job = null
        previous?.cancel()
    }

    fun close() { closed = true; cancel() }
}
