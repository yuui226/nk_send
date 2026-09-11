package com.ztransfer.protocol

import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RemoteLiveViewPolicyTest {
    @Test
    fun usbWarmupOnlyWaitsForTheUncoveredRemainder() {
        assertEquals(
            USB_LIVE_VIEW_WARMUP_MS,
            liveViewWarmupRemainingMs(CameraConnectionType.USB, 1_000L, 1_000L),
        )
        assertEquals(250L, liveViewWarmupRemainingMs(CameraConnectionType.USB, 1_000L, 1_500L))
        assertEquals(0L, liveViewWarmupRemainingMs(CameraConnectionType.USB, 1_000L, 2_000L))
        assertEquals(0L, liveViewWarmupRemainingMs(CameraConnectionType.USB, 0L, 1_000L))
        assertEquals(0L, liveViewWarmupRemainingMs(CameraConnectionType.WIFI, 1_000L, 1_000L))
    }

    @Test
    fun movieModePollingAndUsbSessionGatesStayStable() {
        assertTrue(shouldPollMovieModeDuringLiveViewRecovery(true, false, false))
        assertFalse(shouldPollMovieModeDuringLiveViewRecovery(false, false, false))
        assertFalse(shouldPollMovieModeDuringLiveViewRecovery(true, true, false))
        assertFalse(shouldPollMovieModeDuringLiveViewRecovery(true, false, true))

        assertTrue(shouldPrepareUsbMovieSessionForRecord(CameraConnectionType.USB, false))
        assertFalse(shouldPrepareUsbMovieSessionForRecord(CameraConnectionType.USB, true))
        assertFalse(shouldPrepareUsbMovieSessionForRecord(CameraConnectionType.WIFI, false))
        assertTrue(shouldReturnUsbMovieSessionToStandby(CameraConnectionType.USB, true))
        assertFalse(shouldReturnUsbMovieSessionToStandby(CameraConnectionType.USB, false))
        assertFalse(shouldReturnUsbMovieSessionToStandby(CameraConnectionType.WIFI, true))
    }

    @Test
    fun startupDropsOnlyPropertiesAndSteadyStateKeepsFirstConcreteAlias() {
        val objectEvent = Lab.EVT_OBJECT_ADDED to 42L
        val startup = listOf(
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_ISO.toLong(),
            objectEvent,
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_F_NUMBER.toLong(),
        )
        assertEquals(listOf(objectEvent), coalesceRemoteEvents(startup, true))

        val events = listOf(
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_EXP_COMPENSATION.toLong(),
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_NK_EXP_COMPENSATION.toLong(),
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_ISO.toLong(),
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_NK_ISO_EX.toLong(),
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_ISO.toLong(),
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_EXPOSURE_TIME_STD.toLong(),
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_NK_SHUTTER.toLong(),
            objectEvent,
            objectEvent,
        )
        assertEquals(
            listOf(
                Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_EXP_COMPENSATION.toLong(),
                Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_ISO.toLong(),
                Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_EXPOSURE_TIME_STD.toLong(),
                objectEvent,
                objectEvent,
            ),
            coalesceRemoteEvents(events, false),
        )
    }

    @Test
    fun jpegStartRequiresTheSameThreeBytePrefix() {
        assertEquals(1, findLiveViewJpegStart(byteArrayOf(0, -1, -40, -1, 1)))
        assertEquals(-1, findLiveViewJpegStart(byteArrayOf(-1, -40)))
        assertEquals(-1, findLiveViewJpegStart(byteArrayOf(-1, -40, 0)))
        assertEquals(-1, findLiveViewJpegStart(byteArrayOf()))
    }

    @Test
    fun enhancedOperationIsChosenOnlyWhenAdvertised() {
        assertEquals(Lab.NK_GET_LIVE_VIEW_IMG, preferredLiveViewImageOperation(null))
        assertEquals(Lab.NK_GET_LIVE_VIEW_IMG, preferredLiveViewImageOperation(emptyList()))
        assertEquals(
            Lab.NK_GET_LIVE_VIEW_IMG_EX,
            preferredLiveViewImageOperation(listOf(Lab.NK_GET_LIVE_VIEW_IMG_EX)),
        )
    }

    @Test
    fun enhancedFrameDowngradeNeedsTwoRealFailures() {
        assertEquals(
            LiveViewEnhancedFrameDecision(0, false),
            liveViewEnhancedFrameDecision(Lab.NK_GET_LIVE_VIEW_IMG_EX, Lab.OK, true, 1),
        )
        assertEquals(
            LiveViewEnhancedFrameDecision(1, false),
            liveViewEnhancedFrameDecision(Lab.NK_GET_LIVE_VIEW_IMG_EX, Lab.OK, false, 0),
        )
        assertEquals(
            LiveViewEnhancedFrameDecision(2, true),
            liveViewEnhancedFrameDecision(Lab.NK_GET_LIVE_VIEW_IMG_EX, Lab.ACCESS_DENIED, false, 1),
        )
        assertEquals(
            LiveViewEnhancedFrameDecision(2, true),
            liveViewEnhancedFrameDecision(
                Lab.NK_GET_LIVE_VIEW_IMG_EX,
                PtpConstants.OPERATION_NOT_SUPPORTED,
                false,
                0,
            ),
        )
    }

    @Test
    fun busyAndNotLiveViewDoNotChangeEnhancedFailureCount() {
        listOf(Lab.DEVICE_BUSY, Lab.NK_NOT_LIVE_VIEW).forEach { response ->
            assertEquals(
                LiveViewEnhancedFrameDecision(1, false),
                liveViewEnhancedFrameDecision(
                    Lab.NK_GET_LIVE_VIEW_IMG_EX,
                    response,
                    jpegFound = false,
                    previousFailureCount = 1,
                ),
            )
        }
        assertEquals(
            LiveViewEnhancedFrameDecision(7, false),
            liveViewEnhancedFrameDecision(
                Lab.NK_GET_LIVE_VIEW_IMG,
                Lab.ACCESS_DENIED,
                jpegFound = false,
                previousFailureCount = 7,
            ),
        )
    }

    @Test
    fun retryPoliciesPreserveCountsCodesAndDelays() {
        assertEquals(200L, remoteBusyRetryDelayMs(Lab.DEVICE_BUSY, 0))
        assertEquals(200L, remoteBusyRetryDelayMs(Lab.DEVICE_BUSY, 4))
        assertNull(remoteBusyRetryDelayMs(Lab.DEVICE_BUSY, 5))
        assertNull(remoteBusyRetryDelayMs(Lab.NK_INVALID_STATUS, 0))

        assertEquals(300L, liveViewStartRetryDelayMs(Lab.DEVICE_BUSY, 0))
        assertEquals(300L, liveViewStartRetryDelayMs(Lab.NK_INVALID_STATUS, 4))
        assertNull(liveViewStartRetryDelayMs(Lab.NK_INVALID_STATUS, 5))
        assertNull(liveViewStartRetryDelayMs(PtpConstants.OPERATION_NOT_SUPPORTED, 0))
    }

    @Test
    fun captureAndMovieCompletionPredicatesStayNarrow() {
        assertTrue(isRemoteCaptureCompletionEvent(Lab.EVT_OBJECT_ADDED))
        assertTrue(isRemoteCaptureCompletionEvent(Lab.EVT_OBJECT_ADDED_SDRAM))
        assertFalse(isRemoteCaptureCompletionEvent(Lab.EVT_CAPTURE_COMPLETE))

        assertTrue(isRemoteMovieCompletionEvent(Lab.EVT_NK_MOVIE_REC_COMPLETE))
        assertTrue(isRemoteMovieCompletionEvent(Lab.EVT_NK_MOVIE_REC_INTERRUPTED))
        assertFalse(isRemoteMovieCompletionEvent(Lab.EVT_NK_MOVIE_REC_STARTED))
    }

    @Test
    fun busyAndLiveViewStartRunnersKeepTheSixAttemptCeiling() = runImmediately {
        var busyCalls = 0
        var busyElapsed = 0L
        val busy = runRemoteBusyCommand(
            command = {
                busyCalls++
                Lab.DEVICE_BUSY
            },
            pause = { busyElapsed += it },
        )
        assertEquals(RemoteCommandRetryResult(Lab.DEVICE_BUSY, 5), busy)
        assertEquals(6, busyCalls)
        assertEquals(1_000L, busyElapsed)

        val liveViewResponses = ArrayDeque(
            listOf(
                Lab.NK_INVALID_STATUS,
                Lab.NK_INVALID_STATUS,
                Lab.NK_INVALID_STATUS,
                Lab.NK_INVALID_STATUS,
                Lab.NK_INVALID_STATUS,
                Lab.OK,
            ),
        )
        var liveViewElapsed = 0L
        val liveView = runLiveViewStartCommand(
            command = { liveViewResponses.removeFirst() },
            pause = { liveViewElapsed += it },
        )
        assertEquals(RemoteCommandRetryResult(Lab.OK, 5), liveView)
        assertEquals(1_500L, liveViewElapsed)
        assertTrue(liveViewResponses.isEmpty())

        var unsupportedCalls = 0
        val unsupported = runLiveViewStartCommand(
            command = {
                unsupportedCalls++
                PtpConstants.OPERATION_NOT_SUPPORTED
            },
            pause = { error("must not pause") },
        )
        assertEquals(RemoteCommandRetryResult(PtpConstants.OPERATION_NOT_SUPPORTED, 0), unsupported)
        assertEquals(1, unsupportedCalls)
    }

    @Test
    fun busyRunnerStopsImmediatelyAfterTheFirstNonBusyResponse() = runImmediately {
        val responses = ArrayDeque(listOf(Lab.DEVICE_BUSY, Lab.OK, Lab.ACCESS_DENIED))
        val delays = mutableListOf<Long>()

        val result = runRemoteBusyCommand(
            command = { responses.removeFirst() },
            pause = { delays += it },
        )

        assertEquals(RemoteCommandRetryResult(Lab.OK, completedRetries = 1), result)
        assertEquals(listOf(200L), delays)
        assertEquals(listOf(Lab.ACCESS_DENIED), responses.toList())
    }

    @Test
    fun liveViewReadyWaitStopsOnAnyNonBusyResponse() = runImmediately {
        var now = 10_000L
        val responses = ArrayDeque(listOf(Lab.DEVICE_BUSY, Lab.DEVICE_BUSY, Lab.NK_OUT_OF_FOCUS))
        val result = runLiveViewReadyWait(
            startedAtMs = now,
            currentTimeMs = { now },
            command = { responses.removeFirst() },
            pause = { now += it },
        )

        assertEquals(
            LiveViewReadyWaitResult(Lab.NK_OUT_OF_FOCUS, polls = 3, elapsedMs = 40L),
            result,
        )
    }

    @Test
    fun liveViewReadyDeadlinePreservesTheLastBusyOrInitialOk() = runImmediately {
        var now = 20_000L
        var polls = 0
        val busy = runLiveViewReadyWait(
            startedAtMs = now,
            currentTimeMs = { now },
            command = {
                polls++
                Lab.DEVICE_BUSY
            },
            pause = { now += LIVE_VIEW_READY_TIMEOUT_MS },
        )
        assertEquals(
            LiveViewReadyWaitResult(Lab.DEVICE_BUSY, polls = 1, elapsedMs = 4_000L),
            busy,
        )
        assertEquals(1, polls)

        val expired = runLiveViewReadyWait(
            startedAtMs = 0L,
            currentTimeMs = { LIVE_VIEW_READY_TIMEOUT_MS },
            command = { error("must not poll") },
            pause = { error("must not pause") },
        )
        assertEquals(
            LiveViewReadyWaitResult(Lab.OK, polls = 0, elapsedMs = 4_000L),
            expired,
        )

        assertTrue(
            liveViewSessionAccepted(
                RemoteCommandRetryResult(Lab.OK, completedRetries = 5),
                LiveViewReadyWaitResult(Lab.DEVICE_BUSY, polls = 1, elapsedMs = 4_000L),
            ),
        )
        assertFalse(
            liveViewSessionAccepted(
                RemoteCommandRetryResult(Lab.NK_INVALID_STATUS, completedRetries = 5),
                readyResult = null,
            ),
        )
    }

    @Test
    fun frameLoopDecisionKeepsBusyStreakAndRestartsOnThirdError() {
        assertEquals(40L, LIVE_VIEW_BUSY_RETRY_DELAY_MS)
        assertEquals(300L, LIVE_VIEW_FRAME_ERROR_RETRY_DELAY_MS)
        assertEquals(2_000L, LIVE_VIEW_SESSION_RESTART_DELAY_MS)
        assertEquals(3_000L, LIVE_VIEW_START_FAILURE_RETRY_DELAY_MS)
        assertEquals(
            LiveViewFramePollDecision(0, null, false),
            liveViewFramePollDecision(2, LiveViewFramePollOutcome.SUCCESS),
        )
        assertEquals(
            LiveViewFramePollDecision(2, LIVE_VIEW_BUSY_RETRY_DELAY_MS, false),
            liveViewFramePollDecision(2, LiveViewFramePollOutcome.BUSY),
        )
        assertEquals(
            LiveViewFramePollDecision(2, LIVE_VIEW_FRAME_ERROR_RETRY_DELAY_MS, false),
            liveViewFramePollDecision(1, LiveViewFramePollOutcome.ERROR),
        )
        assertEquals(
            LiveViewFramePollDecision(3, null, true),
            liveViewFramePollDecision(2, LiveViewFramePollOutcome.ERROR),
        )
        assertTrue(liveViewIsStableAfterSuccessfulFrames(CameraConnectionType.WIFI, 0))
        assertFalse(liveViewIsStableAfterSuccessfulFrames(CameraConnectionType.USB, 7))
        assertTrue(liveViewIsStableAfterSuccessfulFrames(CameraConnectionType.USB, 8))
    }

    @Test
    fun captureWaiterIsArmedBeforeCommandAndCancelledOnlyOnFailure() = runImmediately {
        val successTrace = mutableListOf<String>()
        val success = runRemoteCapture(
            armConfirmation = {
                successTrace += "arm"
                RcPendingCaptureConfirmation(
                    awaitObjectHandle = {
                        successTrace += "await"
                        0xFFFF_FFFEL
                    },
                    cancel = { successTrace += "cancel" },
                )
            },
            capture = {
                successTrace += "capture"
                Lab.OK
            },
        )
        assertEquals(RcCaptureResult(Lab.OK, 0xFFFF_FFFEL), success)
        assertEquals(listOf("arm", "capture", "await"), successTrace)

        val timeoutTrace = mutableListOf<String>()
        val timeout = runRemoteCapture(
            armConfirmation = {
                timeoutTrace += "arm"
                RcPendingCaptureConfirmation(
                    awaitObjectHandle = {
                        timeoutTrace += "await"
                        null
                    },
                    cancel = { timeoutTrace += "cancel" },
                )
            },
            capture = {
                timeoutTrace += "capture"
                Lab.OK
            },
        )
        assertEquals(RcCaptureResult(Lab.OK, null), timeout)
        assertEquals(listOf("arm", "capture", "await"), timeoutTrace)

        val failureTrace = mutableListOf<String>()
        val failure = runRemoteCapture(
            armConfirmation = {
                failureTrace += "arm"
                RcPendingCaptureConfirmation(
                    awaitObjectHandle = { error("must not await") },
                    cancel = { failureTrace += "cancel" },
                )
            },
            capture = {
                failureTrace += "capture"
                Lab.ACCESS_DENIED
            },
        )
        assertEquals(RcCaptureResult(Lab.ACCESS_DENIED, null), failure)
        assertEquals(listOf("arm", "capture", "cancel"), failureTrace)
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
