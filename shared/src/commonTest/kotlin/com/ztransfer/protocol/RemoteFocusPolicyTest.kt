package com.ztransfer.protocol

import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RemoteFocusPolicyTest {
    @Test
    fun focusModeScalarAndKnownEnumRulesStayStrict() {
        assertEquals(
            listOf(Lab.PROP_FOCUS_MODE, Lab.PROP_NK_AF_MODE),
            rcFocusModeCandidateProps().toList(),
        )
        assertEquals(0x04030201L, rcDecodeFocusModeRaw(byteArrayOf(1, 2, 3, 4)))
        assertNull(rcDecodeFocusModeRaw(byteArrayOf()))
        assertNull(rcDecodeFocusModeRaw(byteArrayOf(1, 2, 3)))
        assertEquals(
            RcFocusMode("MF", manual = true, Lab.PROP_FOCUS_MODE, 1L),
            rcFocusModeFromRaw(Lab.PROP_FOCUS_MODE, 1L),
        )
        assertEquals(
            RcFocusMode("AF-C", manual = false, Lab.PROP_NK_AF_MODE, 1L),
            rcFocusModeFromRaw(Lab.PROP_NK_AF_MODE, 1L),
        )
        assertNull(rcFocusModeFromRaw(Lab.PROP_NK_AF_MODE, 4L))
        assertNull(rcFocusModeFromRaw(Lab.PROP_ISO, 1L))
    }

    @Test
    fun trackingLifecycleChangesOnlyForConfirmedTerminalResponses() {
        listOf(
            Lab.OK,
            PtpConstants.OPERATION_NOT_SUPPORTED,
            Lab.NK_INVALID_STATUS,
        ).forEach { assertTrue(rcEndTrackingClearsActive(it)) }
        assertFalse(rcEndTrackingClearsActive(Lab.DEVICE_BUSY))
        assertFalse(rcEndTrackingClearsActive(Lab.ACCESS_DENIED))

        assertEquals(true, rcTrackingSupportAfterStart(null, Lab.OK))
        assertEquals(false, rcTrackingSupportAfterStart(true, PtpConstants.OPERATION_NOT_SUPPORTED))
        assertEquals(true, rcTrackingSupportAfterStart(true, Lab.DEVICE_BUSY))
        assertEquals(false, rcTrackingSupportAfterStart(false, Lab.DEVICE_BUSY))
        assertEquals(false, rcTrackingSupportAfterStart(false, null))
        assertNull(rcTrackingSupportAfterStart(null, Lab.NK_INVALID_STATUS))
        assertNull(rcTrackingSupportAfterStart(null, null))
    }

    @Test
    fun tapFocusCompletionPreservesEveryTerminalBranch() = runImmediately {
        var now = 1_150L
        val waitedResponses = mutableListOf<Int>()
        suspend fun complete(start: RcTapFocusStartResult?): RcTapFocusResult = completeTapFocus(
            endTrackingResponseCode = Lab.OK,
            start = start,
            startedAt = 1_000L,
            elapsedRealtime = { now },
            waitForStartedAf = { responseCode ->
                waitedResponses += responseCode
                RcAfResult(responseCode, polls = 2, elapsedMs = 300L, timedOut = false)
            },
        )

        assertEquals(
            RcTapFocusResult(Lab.OK, null, null, trackingStarted = false, afResult = null),
            complete(start = null),
        )
        assertEquals(
            RcTapFocusResult(
                Lab.OK,
                null,
                Lab.OK,
                trackingStarted = true,
                afResult = RcAfResult(Lab.OK, 2, 300L, timedOut = false),
            ),
            complete(RcTapFocusStartResult(null, Lab.OK, Lab.OK)),
        )
        assertEquals(
            RcTapFocusResult(
                Lab.OK,
                Lab.DEVICE_BUSY,
                PtpConstants.OPERATION_NOT_SUPPORTED,
                trackingStarted = false,
                afResult = null,
            ),
            complete(
                RcTapFocusStartResult(
                    Lab.DEVICE_BUSY,
                    PtpConstants.OPERATION_NOT_SUPPORTED,
                    null,
                ),
            ),
        )
        assertEquals(
            RcTapFocusResult(
                Lab.OK,
                Lab.OK,
                PtpConstants.OPERATION_NOT_SUPPORTED,
                trackingStarted = false,
                afResult = RcAfResult(Lab.DEVICE_BUSY, 0, 150L, timedOut = true),
            ),
            complete(
                RcTapFocusStartResult(
                    Lab.OK,
                    PtpConstants.OPERATION_NOT_SUPPORTED,
                    null,
                ),
            ),
        )
        assertEquals(
            RcTapFocusResult(
                Lab.OK,
                null,
                Lab.NK_INVALID_STATUS,
                trackingStarted = false,
                afResult = null,
            ),
            complete(RcTapFocusStartResult(null, Lab.NK_INVALID_STATUS, null)),
        )
        assertEquals(
            RcTapFocusResult(
                Lab.OK,
                Lab.OK,
                null,
                trackingStarted = false,
                afResult = RcAfResult(Lab.OK, 2, 300L, timedOut = false),
            ),
            complete(RcTapFocusStartResult(Lab.OK, null, Lab.OK)),
        )
        assertEquals(listOf(Lab.OK, Lab.OK), waitedResponses)
    }

    @Test
    fun trackingMotionNeedsThreeFramesAndKeepsTheFloatBoundary() {
        val origin = LiveViewFocusFrame(0.500f, 0.500f, 0.1f, 0.1f)
        val nominalThreshold = LiveViewFocusFrame(0.515f, 0.500f, 0.1f, 0.1f)
        val aboveThreshold = LiveViewFocusFrame(0.5151f, 0.500f, 0.1f, 0.1f)
        val still = listOf(
            origin,
            LiveViewFocusFrame(0.504f, 0.497f, 0.1f, 0.1f),
            LiveViewFocusFrame(0.499f, 0.503f, 0.1f, 0.1f),
        )

        assertFalse(trackingMotionDetected(listOf(origin, aboveThreshold)))
        assertFalse(trackingMotionDetected(listOf(origin, origin, nominalThreshold)))
        assertFalse(trackingMotionDetected(still))
        assertTrue(trackingMotionDetected(listOf(origin, origin, aboveThreshold)))
    }

    @Test
    fun trackingCoordinatesAreAcceptedBeforeOneAfDrive() = runImmediately {
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
            pause = { now += it },
        )

        assertNull(result.moveResponseCode)
        assertEquals(Lab.OK, result.trackingResponseCode)
        assertEquals(Lab.OK, result.afStartResponseCode)
        assertEquals(
            listOf(
                Triple(Lab.NK_START_TRACKING, listOf(4_120, 960), 0L),
                Triple(Lab.NK_AF_DRIVE, emptyList(), 80L),
            ),
            calls,
        )
    }

    @Test
    fun onlyExplicitlyUnsupportedTrackingFallsBackToOneShotAf() = runImmediately {
        val calls = mutableListOf<Pair<Int, List<Int>>>()
        val fallback = runTapFocusStart(
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
            pause = {},
        )
        assertEquals(PtpConstants.OPERATION_NOT_SUPPORTED, fallback.trackingResponseCode)
        assertEquals(Lab.OK, fallback.afStartResponseCode)
        assertEquals(
            listOf(
                Lab.NK_START_TRACKING to listOf(2_175, 1_638),
                Lab.NK_CHANGE_AF_AREA to listOf(400, 300),
                Lab.NK_AF_DRIVE to emptyList(),
            ),
            calls,
        )

        val transientCommands = mutableListOf<Int>()
        val transient = runTapFocusStart(
            1,
            2,
            3,
            4,
            tryTracking = true,
            command = { code, _ ->
                transientCommands += code
                Lab.DEVICE_BUSY
            },
            pause = {},
        )
        assertEquals(Lab.DEVICE_BUSY, transient.trackingResponseCode)
        assertNull(transient.afStartResponseCode)
        assertEquals(listOf(Lab.NK_START_TRACKING), transientCommands)
    }

    @Test
    fun missingResponsesAndFailedFallbackMoveDoNotStartAf() = runImmediately {
        var paused = false
        val missingCommands = mutableListOf<Int>()
        val missing = runTapFocusStart(
            1,
            2,
            3,
            4,
            tryTracking = true,
            command = { code, _ ->
                missingCommands += code
                null
            },
            pause = { paused = true },
        )
        assertEquals(Lab.DEVICE_BUSY, missing.trackingResponseCode)
        assertNull(missing.moveResponseCode)
        assertNull(missing.afStartResponseCode)
        assertEquals(listOf(Lab.NK_START_TRACKING), missingCommands)
        assertFalse(paused)

        val commands = mutableListOf<Int>()
        val failedMove = runTapFocusStart(
            1,
            2,
            3,
            4,
            tryTracking = true,
            command = { code, _ ->
                commands += code
                if (code == Lab.NK_START_TRACKING) {
                    PtpConstants.OPERATION_NOT_SUPPORTED
                } else {
                    Lab.DEVICE_BUSY
                }
            },
            pause = { paused = true },
        )
        assertEquals(Lab.DEVICE_BUSY, failedMove.moveResponseCode)
        assertEquals(PtpConstants.OPERATION_NOT_SUPPORTED, failedMove.trackingResponseCode)
        assertNull(failedMove.afStartResponseCode)
        assertEquals(listOf(Lab.NK_START_TRACKING, Lab.NK_CHANGE_AF_AREA), commands)
        assertFalse(paused)
    }

    @Test
    fun cachedUnsupportedTrackingSkipsProbe() = runImmediately {
        val commands = mutableListOf<Int>()
        val result = runTapFocusStart(
            1,
            2,
            3,
            4,
            tryTracking = false,
            command = { code, _ ->
                commands += code
                Lab.OK
            },
            pause = {},
        )

        assertNull(result.trackingResponseCode)
        assertEquals(Lab.OK, result.afStartResponseCode)
        assertEquals(listOf(Lab.NK_CHANGE_AF_AREA, Lab.NK_AF_DRIVE), commands)
    }

    @Test
    fun afDriveIsSentOnceAndBusyReadyResponsesArePolled() = runImmediately {
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
            pause = { now += it },
        )

        assertEquals(
            listOf(Lab.NK_AF_DRIVE, Lab.NK_DEVICE_READY, Lab.NK_DEVICE_READY),
            commands,
        )
        assertEquals(RcAfResult(Lab.OK, 2, 150L, timedOut = false), result)
    }

    @Test
    fun busyReadyAtTheDeadlineDoesNotSendAnotherPoll() = runImmediately {
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
            pause = { now += it },
        )

        assertEquals(listOf(Lab.NK_AF_DRIVE, Lab.NK_DEVICE_READY), commands)
        assertEquals(RcAfResult(Lab.DEVICE_BUSY, 1, 150L, timedOut = true), result)
    }

    @Test
    fun afDeadlineMissingResponseAndNonBusyTerminalsStayDistinct() = runImmediately {
        var now = 2_000L
        val deadlineCommands = mutableListOf<Int>()
        val deadline = runAfDriveAndWait(
            startedAt = now,
            deadlineMs = now,
            elapsedRealtime = { now },
            command = { code -> deadlineCommands += code; Lab.OK },
            pause = { now += it },
        )
        assertTrue(deadlineCommands.isEmpty())
        assertEquals(RcAfResult(Lab.DEVICE_BUSY, 0, 0L, timedOut = true), deadline)

        val missingResponses = ArrayDeque<Int?>(listOf(Lab.OK, null))
        val missingCommands = mutableListOf<Int>()
        val missing = runAfDriveAndWait(
            startedAt = now,
            deadlineMs = now + 6_000L,
            elapsedRealtime = { now },
            command = { code ->
                missingCommands += code
                missingResponses.removeFirst()
            },
            pause = { now += it },
        )
        assertEquals(Lab.DEVICE_BUSY, missing.responseCode)
        assertEquals(0, missing.polls)
        assertTrue(missing.timedOut)
        assertEquals(listOf(Lab.NK_AF_DRIVE, Lab.NK_DEVICE_READY), missingCommands)

        val failedStartCommands = mutableListOf<Int>()
        val failedStart = runAfDriveAndWait(
            startedAt = now,
            deadlineMs = now + 6_000L,
            elapsedRealtime = { now },
            command = { code ->
                failedStartCommands += code
                Lab.NK_OUT_OF_FOCUS
            },
            pause = { now += it },
        )
        assertEquals(RcAfResult(Lab.NK_OUT_OF_FOCUS, 0, 0L, timedOut = false), failedStart)
        assertEquals(listOf(Lab.NK_AF_DRIVE), failedStartCommands)

        val terminalResponses = ArrayDeque(listOf(Lab.OK, Lab.NK_OUT_OF_FOCUS))
        val terminal = runAfDriveAndWait(
            startedAt = now,
            deadlineMs = now + 6_000L,
            elapsedRealtime = { now },
            command = { terminalResponses.removeFirst() },
            pause = { now += it },
        )
        assertEquals(RcAfResult(Lab.NK_OUT_OF_FOCUS, 1, 0L, timedOut = false), terminal)
    }

    private fun <T> runImmediately(block: suspend () -> T): T {
        var completion: Result<T>? = null
        block.startCoroutine(
            object : Continuation<T> {
                override val context = EmptyCoroutineContext

                override fun resumeWith(result: Result<T>) {
                    completion = result
                }
            },
        )
        return completion?.getOrThrow() ?: error("Synchronous fake unexpectedly suspended")
    }
}
