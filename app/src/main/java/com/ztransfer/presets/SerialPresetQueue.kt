package com.ztransfer.presets

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One reader across all preset features. Each caller cancels its own obsolete request;
 * cancelling LUT work must not discard another feature's pending folder scan or NP3 read.
 * The signal and dispatchers are injected so ordering/cancellation can be tested without Android.
 */
internal class SerialPresetQueue<S>(
    scope: CoroutineScope,
    private val deliveryDispatcher: CoroutineDispatcher,
    private val cancellationScope: CoroutineScope,
    private val createSignal: () -> S,
    private val cancelSignal: (S) -> Unit,
    private val onCallbackFailure: (Exception) -> Unit,
) {
    internal class Ticket<S>(val signal: S, private val onCancel: (Ticket<S>) -> Unit) {
        val cancelled = AtomicBoolean(false)
        fun cancel() { if (cancelled.compareAndSet(false, true)) onCancel(this) }
    }
    private class Work<S>(
        val ticket: Ticket<S>,
        val run: suspend () -> Any?,
        val deliver: (Result<Any?>) -> Unit,
        val discard: (Result<Any?>) -> Unit,
    )
    private val cleanups = ConcurrentLinkedQueue<() -> Unit>()
    private val pending = ConcurrentLinkedQueue<Work<S>>()
    private val wake = Channel<Unit>(Channel.CONFLATED)

    init {
        scope.launch {
            for (ignored in wake) while (true) {
                val work = pending.poll() ?: break
                if (work.ticket.cancelled.get()) continue
                val result = try { Result.success(work.run()) }
                    catch (failure: Exception) { Result.failure(failure) }
                    catch (failure: OutOfMemoryError) { Result.failure(failure) }
                var delivered = false
                try {
                    if (!work.ticket.cancelled.get()) withContext(deliveryDispatcher) {
                        if (!work.ticket.cancelled.get()) {
                            // The callback may commit preferences before throwing. Never revoke
                            // its grant as if it were an undelivered result after that point.
                            delivered = true
                            guardCallback { work.deliver(result) }
                        }
                    }
                    if (!delivered) guardCallback { work.discard(result) }
                } finally {
                    // A -> B -> A must release old grants before the next scan acquires them.
                    // One failing cleanup must not strand all later requests or other cleanups.
                    while (true) guardCallback(cleanups.poll() ?: break)
                }
            }
        }
    }

    private fun guardCallback(action: () -> Unit) {
        try { action() } catch (failure: Exception) { onCallbackFailure(failure) }
    }

    /** Enqueue from a delivery callback; executed on the reader before the next request. */
    fun cleanup(action: () -> Unit) { cleanups.add(action) }

    fun <T> submit(action: suspend (S) -> T, discard: (Result<T>) -> Unit = {},
        deliver: (Result<T>) -> Unit): Ticket<S> {
        val ticket = Ticket(createSignal()) { cancelled ->
            // Physically remove cancelled work, including while a provider ignores cancellation.
            pending.removeAll { it.ticket === cancelled }
            cancellationScope.launch { guardCallback { cancelSignal(cancelled.signal) } }
        }
        pending.add(Work(ticket, { action(ticket.signal) }, { result ->
            @Suppress("UNCHECKED_CAST")
            deliver(result as Result<T>)
        }, { result ->
            @Suppress("UNCHECKED_CAST")
            discard(result as Result<T>)
        }))
        wake.trySend(Unit)
        return ticket
    }
}
