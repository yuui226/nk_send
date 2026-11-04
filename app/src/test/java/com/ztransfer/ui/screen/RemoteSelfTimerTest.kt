package com.ztransfer.ui.screen

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteSelfTimerTest {
    @Test(timeout = 5_000)
    fun doubleTapReservesOneRequestAndStaysBusyThroughCapture() = runBlocking {
        val clock = ManualClock()
        val timer = RemoteSelfTimer(this, clock::now, clock::sleep)
        val captureStarted = CompletableDeferred<Unit>()
        val finishCapture = CompletableDeferred<Unit>()
        var focusCalls = 0
        var captureCalls = 0
        assertTrue(timer.start(2, { true }, { focusCalls++; true }, {
            captureCalls++
            captureStarted.complete(Unit)
            finishCapture.await()
        }))
        assertFalse(timer.start(2, { true }, { error("Duplicate focus") }, {}))
        assertEquals(2, timer.remainingSeconds)
        clock.wakeAfter(2_000)
        captureStarted.await()
        assertTrue(timer.active)
        assertEquals(0, timer.remainingSeconds)
        assertFalse(timer.focusing)
        assertFalse(timer.start(2, { true }, { true }, {}))
        finishCapture.complete(Unit)
        timer.awaitIdle()
        assertEquals(1, focusCalls)
        assertEquals(1, captureCalls)
    }

    @Test(timeout = 5_000)
    fun delayedWakeUpsUseTheOriginalDeadlineInsteadOfAddingTickDrift() = runBlocking {
        val clock = ManualClock()
        val timer = RemoteSelfTimer(this, clock::now, clock::sleep)
        var capturedAt: Long? = null
        timer.start(5, { true }, { true }, { capturedAt = clock.now() })
        assertEquals(1_000L, clock.wakeAfter(2_500))
        val nextSleep = clock.nextSleep()
        assertEquals(3, timer.remainingSeconds)
        assertEquals(500L, nextSleep.millis)
        clock.wake(nextSleep, 2_500)
        timer.awaitIdle()
        assertEquals(5_000L, capturedAt)
    }

    @Test(timeout = 5_000)
    fun cancellingCountdownNeverFocusesOrCapturesAndAllowsAnotherRequest() = runBlocking {
        val clock = ManualClock()
        val timer = RemoteSelfTimer(this, clock::now, clock::sleep)
        var cancelledFocusCalls = 0
        var cancelledShots = 0
        timer.start(10, { true }, { cancelledFocusCalls++; true }, { cancelledShots++ })
        clock.nextSleep()
        timer.cancel()
        assertEquals(0, timer.remainingSeconds)
        assertFalse(timer.focusing)
        timer.awaitIdle()
        assertEquals(0, cancelledFocusCalls)
        assertEquals(0, cancelledShots)
        var shots = 0
        assertTrue(timer.start(0, { true }, { true }, { shots++ }))
        timer.awaitIdle()
        assertEquals(1, shots)
    }

    @Test(timeout = 5_000)
    fun cancellingFocusDrainsTheResponseButCannotFireOrAcceptAnotherShot() = runBlocking {
        val timer = RemoteSelfTimer(this)
        val focusStarted = CompletableDeferred<Unit>()
        val finishFocus = CompletableDeferred<Boolean>()
        var shots = 0
        timer.start(0, { true }, {
            focusStarted.complete(Unit)
            finishFocus.await()
        }, { shots++ })
        focusStarted.await()
        assertTrue(timer.focusing)
        timer.cancel()
        assertTrue(timer.active)
        assertFalse(timer.focusing)
        assertFalse(timer.start(0, { true }, { true }, { shots++ }))
        finishFocus.complete(true)
        timer.awaitIdle()
        assertEquals(0, shots)
        assertTrue(timer.start(0, { true }, { true }, { shots++ }))
        timer.awaitIdle()
        assertEquals(1, shots)
    }

    @Test(timeout = 5_000)
    fun staleSessionAfterFocusAndInvalidInitialGateNeverFire() = runBlocking {
        val timer = RemoteSelfTimer(this)
        var valid = false
        var focusCalls = 0
        var shots = 0
        assertFalse(timer.start(0, { valid }, { focusCalls++; true }, { shots++ }))
        assertFalse(timer.active)
        valid = true
        timer.start(0, { valid }, { focusCalls++; valid = false; true }, { shots++ })
        timer.awaitIdle()
        assertEquals(1, focusCalls)
        assertEquals(0, shots)
        assertFalse(timer.focusing)
        assertEquals(0, timer.remainingSeconds)
    }

    @Test(timeout = 5_000)
    fun invalidSessionDuringCountdownStopsBeforeFocus() = runBlocking {
        val clock = ManualClock()
        val timer = RemoteSelfTimer(this, clock::now, clock::sleep)
        var valid = true
        var focusCalls = 0
        var shots = 0
        timer.start(3, { valid }, { focusCalls++; true }, { shots++ })
        val waiting = clock.nextSleep()
        valid = false
        clock.wake(waiting, 1_000)
        timer.awaitIdle()
        assertEquals(0, focusCalls)
        assertEquals(0, shots)
    }

    @Test(timeout = 5_000)
    fun failedFocusAbortsAndACompletedRequestResetsForTheNextShot() = runBlocking {
        val timer = RemoteSelfTimer(this)
        var shots = 0
        timer.start(0, { true }, { false }, { shots++ })
        timer.awaitIdle()
        assertEquals(0, shots)
        assertEquals(0, timer.remainingSeconds)
        assertFalse(timer.focusing)
        timer.start(0, { true }, { true }, { shots++ })
        timer.awaitIdle()
        assertEquals(1, shots)
    }

    @Test(timeout = 5_000)
    fun failureReportsOnceAndResetsState() = runBlocking {
        val timer = RemoteSelfTimer(this)
        val expected = IllegalStateException("Focus failed")
        val failures = mutableListOf<Throwable>()
        timer.start(0, { true }, { throw expected }, { error("Failed focus shot") }, failures::add)
        timer.awaitIdle()
        assertEquals(1, failures.size)
        // Coroutine stack-trace recovery may copy the exception across a suspension boundary.
        assertEquals(expected.javaClass, failures.single().javaClass)
        assertEquals(expected.message, failures.single().message)
        assertFalse(timer.focusing)
        assertEquals(0, timer.remainingSeconds)
    }

    @Test(timeout = 5_000)
    fun cancelledParentBeforeDispatchReleasesReservationAndDoesNotAcceptWork() = runBlocking {
        val scope = CoroutineScope(coroutineContext + Job())
        val timer = RemoteSelfTimer(scope)
        var focusCalls = 0
        var shots = 0
        timer.start(3, { true }, { focusCalls++; true }, { shots++ })
        scope.cancel()
        timer.awaitIdle()
        assertEquals(0, focusCalls)
        assertEquals(0, shots)
        assertFalse(timer.start(3, { true }, { true }, {}))
    }

    private suspend fun RemoteSelfTimer.awaitIdle() {
        while (active) yield()
    }

    private class ManualClock {
        private var time = 0L
        private val sleeps = Channel<PendingSleep>(Channel.UNLIMITED)

        fun now(): Long = time

        suspend fun sleep(millis: Long) {
            val pending = PendingSleep(millis)
            sleeps.send(pending)
            pending.finished.await()
        }

        suspend fun nextSleep(): PendingSleep = sleeps.receive()

        suspend fun wakeAfter(elapsedMillis: Long): Long {
            val pending = nextSleep()
            wake(pending, elapsedMillis)
            return pending.millis
        }

        fun wake(pending: PendingSleep, elapsedMillis: Long) {
            time += elapsedMillis
            pending.finished.complete(Unit)
        }
    }

    private class PendingSleep(val millis: Long) {
        val finished = CompletableDeferred<Unit>()
    }
}
