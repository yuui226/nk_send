package com.ztransfer.viewmodel

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import java.util.Collections

class PhotoGenerationQueueTest {
    @Test fun throwingCompletionDoesNotStopLaterWorkOrShutdownCleanup() = runBlocking {
        val done = CompletableDeferred<Unit>()
        val cleaned = java.util.concurrent.atomic.AtomicInteger()
        val queue = PhotoGenerationQueue(this, Dispatchers.Default)
        try {
            queue.submit(1, execute = {}, complete = { error("callback failure") })
            queue.submit(2, execute = {}, complete = { done.complete(Unit) })
            withTimeout(5_000) { done.await() }
            queue.submit(3, ready = false, execute = {}, complete = { error("cleanup failure") })
            queue.submit(4, ready = false, execute = {}, complete = { cleaned.incrementAndGet() })
            queue.close()
            assertEquals(1, cleaned.get())
        } finally { queue.close() }
    }

    @Test fun runtimeGateCanFinishAnUnpreparedTaskWithoutPolling() = runBlocking {
        val disabled = java.util.concurrent.atomic.AtomicBoolean(false)
        val finished = CompletableDeferred<Unit>()
        val queue = PhotoGenerationQueue(this, Dispatchers.Default)
        try {
            queue.submit(1, ready = false, runWhilePreparing = { disabled.get() },
                execute = { assertTrue(disabled.get()) }, complete = { finished.complete(Unit) })
            disabled.set(true)
            queue.reconsider()
            withTimeout(5_000) { finished.await() }
        } finally { queue.close() }
    }

    @Test fun gateRestoredBeforeSelectionDoesNotPermanentlySkipWaitingRecipe() = runBlocking {
        val disabled = java.util.concurrent.atomic.AtomicBoolean(true)
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val firstDone = CompletableDeferred<Unit>()
        val secondDone = CompletableDeferred<Unit>()
        val queue = PhotoGenerationQueue(this, Dispatchers.Default)
        try {
            queue.submit(1, execute = { entered.complete(Unit); release.await() }, complete = { firstDone.complete(Unit) })
            withTimeout(5_000) { entered.await() }
            queue.submit(2, ready = false, runWhilePreparing = { disabled.get() },
                execute = { assertFalse(disabled.get()) }, complete = { secondDone.complete(Unit) })
            disabled.set(false)
            queue.reconsider()
            release.complete(Unit)
            withTimeout(5_000) { firstDone.await() }
            assertFalse(secondDone.isCompleted)
            queue.markReady(2)
            withTimeout(5_000) { secondDone.await() }
        } finally { queue.close() }
    }

    @Test fun readinessArrivingDuringDeferralIsNotLostAndCompletionRunsOnce() = runBlocking {
        val finished = CompletableDeferred<Unit>()
        val executions = java.util.concurrent.atomic.AtomicInteger()
        val completions = java.util.concurrent.atomic.AtomicInteger()
        val queue = PhotoGenerationQueue(this, Dispatchers.Default)
        try {
            queue.submit(1, ready = false, runWhilePreparing = { true }, execute = {
                if (executions.incrementAndGet() == 1) {
                    queue.markReady(1)
                    queue.deferUntilPrepared()
                }
            }, complete = {
                assertNull(it)
                completions.incrementAndGet()
                finished.complete(Unit)
            })
            withTimeout(5_000) { finished.await() }
            assertEquals(2, executions.get())
            assertEquals(1, completions.get())
        } finally { queue.close() }
    }

    @Test fun preparingHeadDoesNotBlockReadyWorkAndReadinessWakesConsumer() = runBlocking {
        val order = Collections.synchronizedList(mutableListOf<Long>())
        val second = CompletableDeferred<Unit>()
        val first = CompletableDeferred<Unit>()
        val queue = PhotoGenerationQueue(this, Dispatchers.Default)
        try {
            queue.submit(1, ready = false, execute = { order.add(1) }, complete = { first.complete(Unit) })
            queue.submit(2, execute = { order.add(2) }, complete = { second.complete(Unit) })
            withTimeout(5_000) { second.await() }
            assertEquals(listOf(2L), order.toList())
            queue.markReady(1)
            queue.markReady(1)
            withTimeout(5_000) { first.await() }
            assertEquals(listOf(2L, 1L), order.toList())
        } finally { queue.close() }
    }

    @Test fun activeJobDoesNotBlockAdmissionAndCapacityIncludesActiveJob() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val finished = CompletableDeferred<Unit>()
        val queue = PhotoGenerationQueue(this, Dispatchers.Default, capacity = 2)
        try {
            assertEquals(PhotoGenerationQueue.Admission.ACCEPTED,
                queue.submit(1, execute = { entered.complete(Unit); release.await() }, complete = {}))
            withTimeout(5_000) { entered.await() }
            assertEquals(PhotoGenerationQueue.Admission.DUPLICATE,
                queue.submit(1, execute = { fail("duplicate executed") }, complete = {}))
            assertEquals(PhotoGenerationQueue.Admission.ACCEPTED,
                queue.submit(2, execute = {}, complete = { finished.complete(Unit) }))
            assertEquals(PhotoGenerationQueue.Admission.FULL,
                queue.submit(3, execute = { fail("overflow executed") }, complete = {}))
            assertFalse(finished.isCompleted)
            release.complete(Unit)
            withTimeout(5_000) { finished.await() }
        } finally { queue.close() }
    }

    @Test fun failedOrCancelledPhotoDoesNotCancelFollowingPhoto() = runBlocking {
        val failures = Collections.synchronizedList(mutableListOf<Throwable?>())
        val finished = CompletableDeferred<Unit>()
        val queue = PhotoGenerationQueue(this, Dispatchers.Default)
        try {
            queue.submit(1, execute = { error("bad photo") }, complete = { failures.add(it) })
            queue.submit(2, execute = { throw CancellationException("photo cancelled") }, complete = { failures.add(it) })
            queue.submit(3, execute = {}, complete = { failures.add(it); finished.complete(Unit) })
            withTimeout(5_000) { finished.await() }
            assertTrue(failures[0] is IllegalStateException)
            assertTrue(failures[1] is CancellationException)
            assertNull(failures[2])
        } finally { queue.close() }
    }

    @Test fun closeFinishesActiveAndPreparingEntriesExactlyOnce() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val completed = CompletableDeferred<Unit>()
        val completions = Collections.synchronizedList(mutableListOf<Long>())
        val queue = PhotoGenerationQueue(this, Dispatchers.Default)
        val done: (Long, Throwable?) -> Unit = { id, cause ->
            assertTrue(cause is CancellationException)
            synchronized(completions) {
                completions.add(id)
                if (completions.size == 2) completed.complete(Unit)
            }
        }
        queue.submit(1, execute = { entered.complete(Unit); CompletableDeferred<Unit>().await() }, complete = { done(1, it) })
        queue.submit(2, ready = false, execute = { fail("preparing entry executed") }, complete = { done(2, it) })
        withTimeout(5_000) { entered.await() }
        queue.close()
        queue.close()
        withTimeout(5_000) { completed.await() }
        assertEquals(listOf(1L, 2L), completions.sorted())
        assertEquals(PhotoGenerationQueue.Admission.CLOSED,
            queue.submit(3, execute = {}, complete = {}))
    }

    @Test fun cancelledParentRejectsNewWork() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        scope.cancel()
        val queue = PhotoGenerationQueue(scope, Dispatchers.Unconfined)
        assertEquals(PhotoGenerationQueue.Admission.CLOSED,
            queue.submit(1, execute = { fail("cancelled parent executed") }, complete = {}))
        queue.close()
    }
}
