package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RemoteMoviePolicyTest {
    @Test
    fun diagnosticDistinguishesPreparationFailureFromStartResponse() {
        val diagnostic = RcMovieStartResult(
            responseCode = PtpConstants.OPERATION_NOT_SUPPORTED,
            prohibitCondition = (1L shl 14) or (1L shl 18),
            prohibitExtendedResponse = PtpConstants.OPERATION_NOT_SUPPORTED,
            applicationModeResponse = PtpConstants.OPERATION_NOT_SUPPORTED,
            applicationModePropertyResponse = 0x200A,
            startCommandResponse = null,
        ).diagnosticSummary()

        assertEquals(
            "result=0x2005 startOp=not-sent prohibit=0x00044000 " +
                "preEx=0x2005 appOp=0x2005 appProp=0x200A",
            diagnostic,
        )

        assertEquals(
            "result=0x2005 startOp=0x2005 prohibit=0x100000000",
            RcMovieStartResult(
                responseCode = PtpConstants.OPERATION_NOT_SUPPORTED,
                prohibitCondition = 0x1_0000_0000L,
            ).diagnosticSummary(),
        )
        assertEquals(
            "result=0x2005 startOp=0x2005 prohibit=0xFFFFFFFFFFFFFFFF",
            RcMovieStartResult(
                responseCode = PtpConstants.OPERATION_NOT_SUPPORTED,
                prohibitCondition = -1L,
            ).diagnosticSummary(),
        )
    }

    @Test
    fun movieStartResultKeepsTheStartResponseDefault() {
        val result = RcMovieStartResult(
            responseCode = Lab.DEVICE_BUSY,
            prohibitCondition = null,
        )

        assertEquals(Lab.DEVICE_BUSY, result.startCommandResponse)
        assertEquals(null, result.prohibitExtendedResponse)
        assertEquals(null, result.applicationModeResponse)
        assertEquals(null, result.applicationModePropertyResponse)
    }

    @Test
    fun storageFailuresTakePriorityOverRestartableBits() {
        val storageFailures = listOf(
            1L shl 0,
            1L shl 1,
            1L shl 2,
            1L shl 3,
            1L shl 11,
        )

        storageFailures.forEach { condition ->
            assertFalse(
                movieStartNeedsLiveViewRestart(
                    responseCode = Lab.NK_INVALID_STATUS,
                    prohibitCondition = condition,
                ),
            )
            assertFalse(
                movieStartNeedsLiveViewRestart(
                    responseCode = Lab.DEVICE_BUSY,
                    prohibitCondition = condition or (1L shl 14),
                ),
            )
        }
    }

    @Test
    fun restartsForApplicationModeAndEnlargedLiveViewBits() {
        assertTrue(movieStartNeedsLiveViewRestart(Lab.NK_INVALID_STATUS, 1L shl 14))
        assertTrue(movieStartNeedsLiveViewRestart(Lab.NK_INVALID_STATUS, 1L shl 12))
        assertTrue(
            movieStartNeedsLiveViewRestart(
                Lab.NK_INVALID_STATUS,
                (1L shl 12) or (1L shl 14),
            ),
        )
        assertTrue(
            movieStartNeedsLiveViewRestart(
                Lab.DEVICE_BUSY,
                (1L shl 13) or (1L shl 14),
            ),
        )
    }

    @Test
    fun successfulStartNeverRestartsLiveView() {
        assertFalse(movieStartNeedsLiveViewRestart(Lab.OK, null))
        assertFalse(movieStartNeedsLiveViewRestart(Lab.OK, 0L))
        assertFalse(movieStartNeedsLiveViewRestart(Lab.OK, 1L shl 14))
    }

    @Test
    fun bufferAndRecordingStatesTakePriorityOverRestartableBits() {
        listOf(1L shl 9, 1L shl 10).forEach { blockingBit ->
            assertFalse(
                movieStartNeedsLiveViewRestart(
                    responseCode = Lab.NK_INVALID_STATUS,
                    prohibitCondition = blockingBit or (1L shl 12) or (1L shl 14),
                ),
            )
        }
    }

    @Test
    fun nonzeroUnknownConditionsDoNotFallBackToResponseCode() {
        assertFalse(movieStartNeedsLiveViewRestart(Lab.NK_INVALID_STATUS, 1L shl 13))
        assertFalse(movieStartNeedsLiveViewRestart(Lab.DEVICE_BUSY, 1L shl 18))
        assertFalse(
            movieStartNeedsLiveViewRestart(
                PtpConstants.OPERATION_NOT_SUPPORTED,
                null,
            ),
        )
    }

    @Test
    fun missingOrZeroConditionsUseOnlyInvalidStatusAndBusyResponses() {
        listOf(null, 0L).forEach { condition ->
            assertTrue(movieStartNeedsLiveViewRestart(Lab.NK_INVALID_STATUS, condition))
            assertTrue(movieStartNeedsLiveViewRestart(Lab.DEVICE_BUSY, condition))
            assertFalse(
                movieStartNeedsLiveViewRestart(
                    PtpConstants.OPERATION_NOT_SUPPORTED,
                    condition,
                ),
            )
        }
    }

    @Test
    fun recordingAndApplicationModeBitsAreDetectedIndependently() {
        assertTrue(movieProhibitIndicatesRecording(1L shl 10))
        assertTrue(movieProhibitIndicatesRecording((1L shl 10) or (1L shl 14)))
        assertFalse(movieProhibitIndicatesRecording(1L shl 14))
        assertFalse(movieProhibitIndicatesRecording(null))

        assertTrue(movieProhibitRequiresApplicationMode(1L shl 14))
        assertTrue(movieProhibitRequiresApplicationMode((1L shl 14) or (1L shl 18)))
        assertFalse(movieProhibitRequiresApplicationMode(1L shl 0))
        assertFalse(movieProhibitRequiresApplicationMode(1L shl 18))
        assertFalse(movieProhibitRequiresApplicationMode(null))
    }

    @Test
    fun propertyFallbackOnlyRunsForUnsupportedApplicationOperation() {
        assertTrue(
            shouldFallbackToApplicationModeProperty(PtpConstants.OPERATION_NOT_SUPPORTED),
        )
        assertFalse(shouldFallbackToApplicationModeProperty(Lab.OK))
        assertFalse(shouldFallbackToApplicationModeProperty(Lab.DEVICE_BUSY))
        assertFalse(shouldFallbackToApplicationModeProperty(Lab.NK_INVALID_STATUS))
    }

    @Test
    fun recordingEventsPreserveTheTwoSecondLateStartWindow() {
        val stoppedAt = 10_000L
        assertEquals(
            RcMovieRecordingEvent.STARTED,
            rcMovieRecordingEvent(Lab.EVT_NK_MOVIE_REC_STARTED),
        )
        assertEquals(
            RcMovieRecordingEvent.FINISHED,
            rcMovieRecordingEvent(Lab.EVT_NK_MOVIE_REC_COMPLETE),
        )
        assertEquals(RcMovieRecordingEvent.OTHER, rcMovieRecordingEvent(Lab.EVT_OBJECT_ADDED))

        assertFalse(
            rcRecordingAfterMovieEvent(false, Lab.EVT_NK_MOVIE_REC_STARTED, stoppedAt + 2_000L, stoppedAt),
        )
        assertTrue(
            rcRecordingAfterMovieEvent(false, Lab.EVT_NK_MOVIE_REC_STARTED, stoppedAt + 2_001L, stoppedAt),
        )
        assertTrue(
            rcRecordingAfterMovieEvent(true, Lab.EVT_NK_MOVIE_REC_STARTED, stoppedAt + 10L, stoppedAt),
        )
        assertFalse(
            rcRecordingAfterMovieEvent(true, Lab.EVT_NK_MOVIE_REC_INTERRUPTED, stoppedAt, stoppedAt),
        )
        assertTrue(rcRecordingAfterMovieEvent(true, Lab.EVT_OBJECT_ADDED, stoppedAt, stoppedAt))
        assertFalse(rcRecordingAfterMovieEvent(false, Lab.EVT_OBJECT_ADDED, stoppedAt, stoppedAt))
    }

    @Test
    fun startAdoptionAndStopFinalizationUseTheExistingCameraSignals() {
        assertTrue(shouldAdoptMovieRecording(RcMovieStartResult(Lab.OK, null)))
        assertTrue(
            shouldAdoptMovieRecording(
                RcMovieStartResult(Lab.DEVICE_BUSY, 1L shl 10),
            ),
        )
        assertFalse(shouldAdoptMovieRecording(RcMovieStartResult(Lab.DEVICE_BUSY, 0L)))
        assertFalse(shouldAdoptMovieRecording(null))

        assertTrue(movieStopNeedsFinalizationWait(true, false))
        assertTrue(movieStopNeedsFinalizationWait(false, true))
        assertTrue(movieStopNeedsFinalizationWait(true, true))
        assertFalse(movieStopNeedsFinalizationWait(false, false))
    }
}
