package com.ztransfer.protocol

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteFocusTest {
    @Test
    fun sendsAfDriveOnceAndPollsUntilCameraIsReady() = runBlocking {
        var now = 1_000L
        val commands = mutableListOf<Int>()
        val responses = ArrayDeque(listOf(Lab.OK, Lab.DEVICE_BUSY, Lab.OK))

        val result = runAfDriveAndWait(
            startedAt = now,
            deadlineMs = now + 6_000L,
            elapsedRealtime = { now },
            command = { code ->
                commands += code
                responses.removeFirst()
            },
            pause = { now += it }
        )

        assertEquals(
            listOf(Lab.NK_AF_DRIVE, Lab.NK_DEVICE_READY, Lab.NK_DEVICE_READY),
            commands
        )
        assertEquals(Lab.OK, result.responseCode)
        assertEquals(2, result.polls)
        assertEquals(150L, result.elapsedMs)
        assertFalse(result.timedOut)
    }

    @Test
    fun stopsPollingAtDeadlineWithoutSendingAnotherCommand() = runBlocking {
        var now = 2_000L
        val commands = mutableListOf<Int>()

        val result = runAfDriveAndWait(
            startedAt = now,
            deadlineMs = now + 150L,
            elapsedRealtime = { now },
            command = { code ->
                commands += code
                if (code == Lab.NK_AF_DRIVE) Lab.OK else Lab.DEVICE_BUSY
            },
            pause = { now += it }
        )

        assertEquals(listOf(Lab.NK_AF_DRIVE, Lab.NK_DEVICE_READY), commands)
        assertEquals(Lab.DEVICE_BUSY, result.responseCode)
        assertEquals(1, result.polls)
        assertEquals(150L, result.elapsedMs)
        assertTrue(result.timedOut)
    }

    @Test
    fun missingAtomicTransactionMeansTimeoutWithoutRetryingAfDrive() = runBlocking {
        var now = 3_000L
        val commands = mutableListOf<Int>()

        val result = runAfDriveAndWait(
            startedAt = now,
            deadlineMs = now + 6_000L,
            elapsedRealtime = { now },
            command = { code ->
                commands += code
                if (code == Lab.NK_AF_DRIVE) Lab.OK else null
            },
            pause = { now += it }
        )

        assertEquals(listOf(Lab.NK_AF_DRIVE, Lab.NK_DEVICE_READY), commands)
        assertEquals(0, result.polls)
        assertTrue(result.timedOut)
    }
}
