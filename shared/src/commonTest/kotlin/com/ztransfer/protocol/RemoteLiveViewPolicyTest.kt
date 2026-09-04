package com.ztransfer.protocol

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
}
