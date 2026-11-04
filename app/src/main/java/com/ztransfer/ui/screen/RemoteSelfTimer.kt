package com.ztransfer.ui.screen

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * One countdown, focus and capture operation, owned by the remote screen's main-thread scope.
 * Call [start] and [cancel] on that same thread. The focus callback must have a bounded timeout:
 * cancelling a request drains an already-started camera response before allowing another shot.
 */
@Stable
internal class RemoteSelfTimer(
    private val scope: CoroutineScope,
    private val nowMillis: () -> Long = { System.nanoTime() / 1_000_000L },
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
    /** Includes a cancelled focus operation until its camera response has drained. */
    var active by mutableStateOf(false)
        private set
    var remainingSeconds by mutableIntStateOf(0)
        private set
    var focusing by mutableStateOf(false)
        private set

    private var generation = 0L
    private var worker: Job? = null

    fun start(
        seconds: Int,
        isValid: () -> Boolean,
        focus: suspend () -> Boolean,
        capture: suspend () -> Unit,
        onFailure: (Throwable) -> Unit = {},
    ): Boolean {
        require(seconds >= 0)
        if (active || !scope.isActive || !isValid()) return false

        // Reserve synchronously, before launch can dispatch, so two shutter taps cannot queue shots.
        active = true
        remainingSeconds = seconds
        val request = ++generation
        val deadline = nowMillis() + seconds * 1_000L
        val task = scope.launch(start = CoroutineStart.LAZY) {
            fun requestIsValid() = generation == request && isValid()
            try {
                while (true) {
                    currentCoroutineContext().ensureActive()
                    if (!requestIsValid()) return@launch
                    val remainingMillis = deadline - nowMillis()
                    if (remainingMillis <= 0L) break
                    remainingSeconds = ((remainingMillis + 999L) / 1_000L).toInt()
                    // Recompute from the deadline after every wake-up, including delayed frames.
                    sleep(remainingMillis - (remainingSeconds - 1) * 1_000L)
                }
                remainingSeconds = 0
                focusing = true
                val focused = withContext(NonCancellable) { focus() }
                currentCoroutineContext().ensureActive()
                focusing = false
                if (!focused || !requestIsValid()) return@launch
                capture()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                if (generation == request && currentCoroutineContext().isActive) {
                    onFailure(failure)
                }
            }
        }
        worker = task
        task.invokeOnCompletion {
            if (worker === task) {
                worker = null
                remainingSeconds = 0
                focusing = false
                active = false
            }
        }
        task.start()
        return true
    }

    fun cancel() {
        ++generation
        remainingSeconds = 0
        focusing = false
        worker?.cancel()
    }

    /** Drain camera I/O before the caller releases the remote-control session. */
    suspend fun cancelAndJoin() {
        val task = worker
        cancel()
        task?.join()
    }
}
