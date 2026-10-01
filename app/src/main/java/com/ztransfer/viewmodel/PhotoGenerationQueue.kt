package com.ztransfer.viewmodel

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch

/**
 * One consumer, no coroutine per waiting photo. Registration never waits for image processing.
 * Waiting entries contain recipes/URIs only: callers must not capture bitmaps or file headers.
 * A preparing entry can be bypassed; ready entries retain registration order.
 */
internal class PhotoGenerationQueue(
    scope: CoroutineScope,
    dispatcher: CoroutineDispatcher,
    private val capacity: Int = 4096,
) {
    enum class Admission { ACCEPTED, DUPLICATE, FULL, CLOSED }

    private class Entry(
        val id: Long,
        val order: Long,
        val runWhilePreparing: () -> Boolean,
        var ready: Boolean,
        val execute: suspend () -> Unit,
        val complete: (Throwable?) -> Unit,
    )

    private val lock = Any()
    private val pending = java.util.TreeMap<Long, Entry>()
    private val entries = HashMap<Long, Entry>()
    private var nextOrder = 0L
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private var closed = false

    init { require(capacity > 0) }

    private val consumer = scope.launch(dispatcher) {
        try {
            for (signal in wake) {
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val entry = synchronized(lock) {
                        pending.values.firstOrNull { it.ready || it.runWhilePreparing() }?.also {
                            pending.remove(it.order)
                        }
                    } ?: break
                    var failure: Throwable? = null
                    var deferred = false
                    try {
                        entry.execute()
                    } catch (error: Throwable) {
                        if (error === PreparationPending) deferred = true else failure = error
                    } finally {
                        val requeued = synchronized(lock) {
                            if (deferred && !closed) {
                                pending[entry.order] = entry
                                true
                            } else {
                                entries.remove(entry.id)
                                false
                            }
                        }
                        if (!requeued) notifyPhotoCompletion {
                            entry.complete(failure ?: if (deferred)
                                CancellationException("Photo generation queue closed") else null)
                        }
                    }
                    // Per-photo cancellation/failure must not discard unrelated work. A scope
                    // cancellation, however, must stop draining before another photo starts.
                    currentCoroutineContext().ensureActive()
                }
            }
        } finally {
            closePending()
        }
    }.also { job ->
        // Also covers a parent scope cancelled before the consumer was ever dispatched.
        job.invokeOnCompletion { closePending() }
    }

    fun submit(
        id: Long,
        ready: Boolean = true,
        runWhilePreparing: () -> Boolean = { false },
        execute: suspend () -> Unit,
        complete: (Throwable?) -> Unit,
    ): Admission {
        val result = synchronized(lock) {
            when {
                closed -> Admission.CLOSED
                id in entries -> Admission.DUPLICATE
                entries.size >= capacity -> Admission.FULL
                else -> {
                    val entry = Entry(id, nextOrder++, runWhilePreparing, ready, execute, complete)
                    pending[entry.order] = entry
                    entries[id] = entry
                    Admission.ACCEPTED
                }
            }
        }
        if (result == Admission.ACCEPTED) wake.trySend(Unit)
        return result
    }

    fun markReady(id: Long) {
        val changed = synchronized(lock) {
            entries[id]?.takeUnless { it.ready }?.also { it.ready = true } != null
        }
        if (changed) wake.trySend(Unit)
    }

    /** The runtime gate changed; reconsider pending entries without polling or mass skipping. */
    fun reconsider() { wake.trySend(Unit) }

    /** Yield the compute slot if a gate changed after selection; keep identity and queue order. */
    fun deferUntilPrepared(): Nothing = throw PreparationPending

    private object PreparationPending : RuntimeException(null, null, false, false)

    fun close() {
        closePending()
        consumer.cancel()
    }

    private fun closePending() {
        val abandoned = synchronized(lock) {
            closed = true
            pending.values.toList().also { abandoned ->
                pending.clear()
                abandoned.forEach { entries.remove(it.id) }
            }
        }
        wake.close()
        val cause = CancellationException("Photo generation queue closed")
        abandoned.forEach { entry -> notifyPhotoCompletion { entry.complete(cause) } }
    }
}

/** Completion bookkeeping is independent for each photo, including during queue shutdown. */
internal inline fun notifyPhotoCompletion(callback: () -> Unit) {
    try { callback() }
    catch (error: Exception) {
        java.util.logging.Logger.getLogger("PhotoGenerationQueue")
            .log(java.util.logging.Level.WARNING, "Photo completion callback failed", error)
    }
}
