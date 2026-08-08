package com.ztransfer.protocol

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteFocusTest {
    @Test
    fun trackingProbeRequiresSeveralFramesAndMaterialCameraFrameMotion() {
        val still = listOf(
            LiveViewFocusFrame(0.500f, 0.500f, 0.1f, 0.1f),
            LiveViewFocusFrame(0.504f, 0.497f, 0.1f, 0.1f),
            LiveViewFocusFrame(0.499f, 0.503f, 0.1f, 0.1f)
        )
        val moving = still + LiveViewFocusFrame(0.535f, 0.510f, 0.1f, 0.1f)

        assertFalse(trackingMotionDetected(still.take(2)))
        assertFalse(trackingMotionDetected(still))
        assertTrue(trackingMotionDetected(moving))
    }

    @Test
    fun tapFocusStartsTrackingAtCoordinatesThenDrivesAfOnce() = runBlocking {
        var now = 0L
        val calls = mutableListOf<Triple<Int, List<Int>, Long>>()

        val result = runTapFocusStart(
            trackingX = 4_120,
            trackingY = 960,
            focusX = 758,
            focusY = 176,
            tryTracking = true,
            command = { code, params ->
                calls += Triple(code, params.toList(), now)
                Lab.OK
            },
            pause = { now += it }
        )

        assertNull(result.moveResponseCode)
        assertEquals(Lab.OK, result.trackingResponseCode)
        assertEquals(Lab.OK, result.afStartResponseCode)
        assertEquals(
            listOf(
                Triple(Lab.NK_START_TRACKING, listOf(4_120, 960), 0L),
                Triple(Lab.NK_AF_DRIVE, emptyList(), 80L)
            ),
            calls
        )
    }

    @Test
    fun unsupportedTrackingDoesNotStartAfWhenFallbackAreaMoveFails() = runBlocking {
        val commands = mutableListOf<Int>()
        var paused = false

        val result = runTapFocusStart(
            trackingX = 544,
            trackingY = 1_092,
            focusX = 100,
            focusY = 200,
            tryTracking = true,
            command = { code, _ ->
                commands += code
                if (code == Lab.NK_START_TRACKING) {
                    PtpConstants.OPERATION_NOT_SUPPORTED
                } else {
                    Lab.DEVICE_BUSY
                }
            },
            pause = { paused = true }
        )

        assertEquals(Lab.DEVICE_BUSY, result.moveResponseCode)
        assertEquals(PtpConstants.OPERATION_NOT_SUPPORTED, result.trackingResponseCode)
        assertNull(result.afStartResponseCode)
        assertEquals(listOf(Lab.NK_START_TRACKING, Lab.NK_CHANGE_AF_AREA), commands)
        assertFalse(paused)
    }

    @Test
    fun tapFocusReportsMissingTrackingResponseWithoutFallingBack() = runBlocking {
        var now = 0L
        val commands = mutableListOf<Int>()

        val result = runTapFocusStart(
            trackingX = 2_784,
            trackingY = 1_856,
            focusX = 512,
            focusY = 340,
            tryTracking = true,
            command = { code, _ ->
                commands += code
                if (code == Lab.NK_CHANGE_AF_AREA) Lab.OK else null
            },
            pause = { now += it }
        )

        assertNull(result.moveResponseCode)
        assertEquals(Lab.DEVICE_BUSY, result.trackingResponseCode)
        assertNull(result.afStartResponseCode)
        assertEquals(0L, now)
        assertEquals(listOf(Lab.NK_START_TRACKING), commands)
    }

    @Test
    fun explicitlyUnsupportedTrackingFallsBackToOneShotAf() = runBlocking {
        val calls = mutableListOf<Pair<Int, List<Int>>>()

        val result = runTapFocusStart(
            trackingX = 2_175,
            trackingY = 1_638,
            focusX = 400,
            focusY = 300,
            tryTracking = true,
            command = { code, params ->
                calls += code to params.toList()
                if (code == Lab.NK_START_TRACKING) {
                    PtpConstants.OPERATION_NOT_SUPPORTED
                } else {
                    Lab.OK
                }
            },
            pause = {}
        )

        assertEquals(PtpConstants.OPERATION_NOT_SUPPORTED, result.trackingResponseCode)
        assertEquals(Lab.OK, result.afStartResponseCode)
        assertEquals(
            listOf(
                Lab.NK_START_TRACKING to listOf(2_175, 1_638),
                Lab.NK_CHANGE_AF_AREA to listOf(400, 300),
                Lab.NK_AF_DRIVE to emptyList()
            ),
            calls
        )
    }

    @Test
    fun transientTrackingFailureDoesNotSilentlyBecomeOneShotAf() = runBlocking {
        val commands = mutableListOf<Int>()

        val result = runTapFocusStart(
            trackingX = 2_175,
            trackingY = 1_638,
            focusX = 400,
            focusY = 300,
            tryTracking = true,
            command = { code, _ ->
                commands += code
                if (code == Lab.NK_START_TRACKING) Lab.DEVICE_BUSY else Lab.OK
            },
            pause = {}
        )

        assertEquals(Lab.DEVICE_BUSY, result.trackingResponseCode)
        assertNull(result.afStartResponseCode)
        assertEquals(listOf(Lab.NK_START_TRACKING), commands)
    }

    @Test
    fun cachedUnsupportedTrackingSkipsProbeAndUsesOneShotAf() = runBlocking {
        val commands = mutableListOf<Int>()

        val result = runTapFocusStart(
            trackingX = 2_175,
            trackingY = 1_638,
            focusX = 400,
            focusY = 300,
            tryTracking = false,
            command = { code, _ ->
                commands += code
                Lab.OK
            },
            pause = {}
        )

        assertNull(result.trackingResponseCode)
        assertEquals(Lab.OK, result.afStartResponseCode)
        assertEquals(listOf(Lab.NK_CHANGE_AF_AREA, Lab.NK_AF_DRIVE), commands)
    }

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
