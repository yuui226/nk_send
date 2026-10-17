package com.ztransfer.ui.screen

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * One shared render per target. Cancelling an awaiter preserves work that another preview can use;
 * closing the cache cancels that work permanently. Displayed bitmaps are never recycled here.
 * Generic output keeps the scheduling/cancellation contract testable without Android graphics.
 */
internal class PhotoEffectsPreviewCache<T : Any>(
    private val renderMutex: Mutex,
    dispatcher: CoroutineDispatcher = Dispatchers.Default,
) : AutoCloseable {
    private val lifetime = SupervisorJob()
    private val scope = CoroutineScope(lifetime + dispatcher)
    private val mutex = Mutex()
    private var completed: T? = null
    private var running: Deferred<T>? = null

    suspend fun getOrRender(
        isObsolete: () -> Boolean = { false },
        serializeWithOtherPreviews: Boolean = true,
        render: suspend (isCancelled: () -> Boolean) -> T,
    ): T {
        while (true) {
            currentCoroutineContext().ensureActive()
            lifetime.ensureActive()
            var createdForThisRequest = false
            val task = mutex.withLock {
                lifetime.ensureActive()
                completed?.let { return it }
                running?.takeUnless { it.isCancelled } ?: scope.async {
                    val renderNow: suspend () -> T = {
                        ensureActive()
                        if (isObsolete()) throw SupersededRender()
                        var observedObsolete = false
                        try {
                            render {
                                isObsolete().also { if (it) observedObsolete = true } || !isActive
                            }.also { ensureActive() }
                        } catch (cancelled: CancellationException) {
                            // Only our own obsolete-work cancellation is retryable. In particular,
                            // a closed intermediate cache must release the complete-frame lock.
                            if (observedObsolete && isActive) throw SupersededRender()
                            throw cancelled
                        }
                    }
                    if (serializeWithOtherPreviews) {
                        renderMutex.withLock { renderNow() }
                    } else {
                        renderNow()
                    }
                }.also {
                    running = it
                    createdForThisRequest = true
                }
            }
            val result = try {
                task.await()
            } catch (error: Throwable) {
                if (task.isCancelled) {
                    mutex.withLock {
                        if (running === task) running = null
                    }
                    // A target can become obsolete, then be selected again before cancellation is
                    // delivered. A new caller may also have joined an old task whose intermediate
                    // cache was closed; retry once with this caller's current render dependencies.
                    // A fresh render's unrelated cancellation must propagate instead of looping.
                    if (error is CancellationException &&
                        (error is SupersededRender || !createdForThisRequest) && lifetime.isActive &&
                        currentCoroutineContext().isActive && !isObsolete()
                    ) {
                        continue
                    }
                }
                throw error
            }
            return mutex.withLock {
                lifetime.ensureActive()
                completed ?: result.also {
                    if (running === task) running = null
                    completed = it
                }
            }
        }
    }

    override fun close() {
        lifetime.cancel()
    }

    private class SupersededRender : CancellationException("Preview render superseded")
}
