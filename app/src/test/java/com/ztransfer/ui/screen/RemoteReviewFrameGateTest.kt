package com.ztransfer.ui.screen

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class RemoteReviewFrameGateTest {
    @Test fun pauseWaitsForInFlightFrameAndPreventsTheNextRequest() = runBlocking {
        val gate = RemoteReviewFrameGate()
        val finishFrame = CompletableDeferred<Unit>()
        val frame = launch(start = CoroutineStart.UNDISPATCHED) { gate.withFrame { finishFrame.await() } }
        gate.pause()
        val idle = async(start = CoroutineStart.UNDISPATCHED) { gate.awaitIdle() }
        var nextStarted = false
        val next = launch(start = CoroutineStart.UNDISPATCHED) { gate.withFrame { nextStarted = true } }
        assertFalse(idle.isCompleted)
        finishFrame.complete(Unit)
        frame.join()
        idle.await()
        assertFalse(nextStarted)
        gate.resume()
        next.join()
        assertTrue(nextStarted)
    }

    @Test fun cancellingAPausedSessionDoesNotSendAFrameOrBlockTheReplacement() = runBlocking {
        val gate = RemoteReviewFrameGate()
        gate.pause()
        var calls = 0
        val old = launch(start = CoroutineStart.UNDISPATCHED) { gate.withFrame { calls++ } }
        old.cancelAndJoin()
        gate.resume()
        gate.withFrame { calls++ }
        assertEquals(1, calls)
    }

    @Test fun failureReleasesFrameBarrier() = runBlocking {
        val gate = RemoteReviewFrameGate()
        try { gate.withFrame { error("disconnected") } } catch (_: IllegalStateException) { }
        gate.pause()
        gate.awaitIdle()
        gate.resume()
        assertEquals(5, gate.withFrame { 5 })
    }
}
