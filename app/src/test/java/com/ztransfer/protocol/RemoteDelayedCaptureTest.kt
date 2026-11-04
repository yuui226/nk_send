package com.ztransfer.protocol

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RemoteDelayedCaptureTest {
    @Test
    fun anInvalidatedRequestNeverEntersTheCommandQueue() = runBlocking {
        var commands = 0
        val response = runDelayedCapture(
            isCurrent = { false },
            command = { commands++; Lab.OK },
            pause = { error("No retry should be scheduled") },
        )
        assertNull(response)
        assertEquals(0, commands)
    }

    @Test
    fun cancellationDuringBusyBackoffNeverSendsTheNextShutter() = runBlocking {
        var current = true
        var commands = 0
        val response = runDelayedCapture(
            isCurrent = { current },
            command = { commands++; if (commands == 1) Lab.DEVICE_BUSY else Lab.OK },
            pause = { millis ->
                assertEquals(200L, millis)
                current = false
            },
        )
        assertNull(response)
        assertEquals(1, commands)
    }

    @Test
    fun aRequestInvalidatedWhileQueuedDoesNotRetry() = runBlocking {
        var attempts = 0
        var pauses = 0
        val response = runDelayedCapture(
            isCurrent = { true },
            // The transaction's final pre-send guard can invalidate a previously current request.
            command = { attempts++; null },
            pause = { pauses++ },
        )
        assertNull(response)
        assertEquals(1, attempts)
        assertEquals(0, pauses)
    }

    @Test
    fun persistentBusyStopsAfterFiveRetries() = runBlocking {
        var commands = 0
        var pauses = 0
        val response = runDelayedCapture(
            isCurrent = { true },
            command = { commands++; Lab.DEVICE_BUSY },
            pause = { pauses++ },
        )
        assertEquals(Lab.DEVICE_BUSY, response)
        assertEquals(6, commands)
        assertEquals(5, pauses)
    }
}
