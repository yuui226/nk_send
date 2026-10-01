package com.ztransfer.lut

import android.os.CancellationSignal
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Process-wide single consumer: an uncooperative document provider cannot cause each retry/page
 * to create another blocked reader. At most one active operation and one latest pending operation.
 * UI owns timeout/generation checks; cancelling a request never waits for the provider.
 */
internal object LutIoQueue {
    internal class Ticket {
        val signal = CancellationSignal()
        val cancelled = AtomicBoolean(false)
        fun cancel() {
            if (!cancelled.compareAndSet(false, true)) return
            // Provider cancellation may itself call Binder. Keep it off the UI thread.
            cancellationScope.launch { signal.cancel() }
        }
    }
    private class Work(val ticket: Ticket, val run: suspend () -> Any?, val deliver: (Result<Any?>) -> Unit, val discard: (Result<Any?>) -> Unit)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    private val cancellationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO.limitedParallelism(1))
    private val cleanups = ConcurrentLinkedQueue<() -> Unit>()
    private val queue = Channel<Work>(Channel.CONFLATED, onUndeliveredElement = { it.ticket.cancel() })
    init {
        scope.launch {
            for (work in queue) {
                if (work.ticket.cancelled.get()) continue
                val result = try { Result.success(work.run()) }
                    catch (failure: Exception) { Result.failure(failure) }
                    catch (failure: OutOfMemoryError) { Result.failure(failure) }
                var delivered = false
                if (!work.ticket.cancelled.get()) withContext(Dispatchers.Main.immediate) {
                    if (!work.ticket.cancelled.get()) {
                        work.deliver(result)
                        delivered = true
                    }
                }
                if (!delivered) work.discard(result)
                // Run committed permission cleanup before the next folder can acquire its grant.
                // Otherwise quickly choosing A -> B -> A could revoke A after it is selected again.
                while (true) (cleanups.poll() ?: break).invoke()
            }
        }
    }

    /** Called from a delivery callback; drained by the same actor before its next operation. */
    fun cleanup(action: () -> Unit) { cleanups.add(action) }

    fun <T> submit(action: suspend (CancellationSignal) -> T, discard: (Result<T>) -> Unit = {}, deliver: (Result<T>) -> Unit): Ticket {
        val ticket = Ticket()
        queue.trySend(Work(ticket, { action(ticket.signal) }, { result ->
            @Suppress("UNCHECKED_CAST")
            deliver(result as Result<T>)
        }, { result ->
            @Suppress("UNCHECKED_CAST")
            discard(result as Result<T>)
        }))
        return ticket
    }
}
