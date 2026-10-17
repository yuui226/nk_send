package com.ztransfer.protocol

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class RemoteMovieApplicationStateTest {
    @Test
    fun exitWaitsForStopCleanupAndDoesNotResendAcknowledgedCommands() = runBlocking {
        val state = RemoteMovieApplicationState().apply { operationSet = true; propertySet = true }
        val commandStarted = CompletableDeferred<Unit>()
        val response = CompletableDeferred<Int>()
        val calls = mutableListOf<String>()
        val stop = launch(start = CoroutineStart.UNDISPATCHED) {
            state.clear({ true }, {
                calls += "stop-op"
                commandStarted.complete(Unit)
                response.await()
            }, { calls += "stop-prop"; Lab.OK })
        }
        commandStarted.await()
        var exitDone = false
        val exit = launch(start = CoroutineStart.UNDISPATCHED) {
            assertTrue(state.clear({ true }, { calls += "exit-op"; Lab.OK }, { calls += "exit-prop"; Lab.OK }))
            exitDone = true
        }
        assertFalse(exitDone)
        stop.cancel() // Simulate disposal cancelling the stop button's job.
        response.complete(Lab.OK)
        stop.join()
        exit.join()
        assertTrue(exitDone)
        assertFalse(state.operationSet)
        assertFalse(state.propertySet)
        assertEquals(listOf("stop-op", "stop-prop"), calls)
    }

    @Test
    fun failureRetainsOnlyTheUnreleasedFlagForTheExitRetry() = runBlocking {
        val state = RemoteMovieApplicationState().apply { operationSet = true; propertySet = true }
        val calls = mutableListOf<String>()
        assertFalse(state.clear({ true }, { Lab.ACCESS_DENIED }, { Lab.OK }))
        assertTrue(state.operationSet)
        assertFalse(state.propertySet)
        assertTrue(state.clear({ true }, { calls += "op"; Lab.OK }, { calls += "prop"; Lab.OK }))
        assertEquals(listOf("op"), calls)
    }

    @Test
    fun busyRetryIsBoundedAndNeverFalselyMarksTheModeReleased() = runBlocking {
        val state = RemoteMovieApplicationState().apply { operationSet = true }
        var attempts = 0
        val pauses = mutableListOf<Long>()
        assertFalse(state.clear({ true }, { attempts++; Lab.DEVICE_BUSY }, { error("unused") },
            pause = { pauses += it }))
        assertEquals(3, attempts)
        assertEquals(listOf(200L, 200L), pauses)
        assertTrue(state.operationSet)
        attempts = 0
        assertTrue(state.clear({ true }, { if (++attempts == 2) Lab.OK else Lab.DEVICE_BUSY },
            { error("unused") }, pause = {}))
        assertEquals(2, attempts)
        assertFalse(state.operationSet)
    }

    @Test
    fun usbStandbyDoesNotClearModesOwnedByPcButExitCanReleaseThem() = runBlocking {
        val state = RemoteMovieApplicationState().apply { propertySet = true }
        assertFalse(state.clear({ false }, { error("must not run") }, { error("must not run") }))
        assertTrue(state.propertySet)
        assertTrue(state.clear({ true }, { error("unused") }, { Lab.OK }))
        assertFalse(state.propertySet)
    }

    @Test
    fun cancelledWaiterDoesNotInterruptTheActiveCleanupOrLeakItsLock() = runBlocking {
        val state = RemoteMovieApplicationState().apply { operationSet = true }
        val response = CompletableDeferred<Int>()
        val first = launch(start = CoroutineStart.UNDISPATCHED) {
            state.clear({ true }, { response.await() }, { error("unused") })
        }
        val waiting = launch(start = CoroutineStart.UNDISPATCHED) {
            state.clear({ true }, { error("cancelled waiter ran") }, { error("unused") })
        }
        waiting.cancelAndJoin()
        assertTrue(state.operationSet)
        response.complete(Lab.OK)
        first.join()
        assertTrue(state.clear({ true }, { error("already released") }, { error("unused") }))
    }
}
