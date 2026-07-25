package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteMovieTest {
    @Test
    fun doesNotRestartLiveViewForStorageFailures() {
        val storageFailures = listOf(
            1L shl 0,  // no card
            1L shl 1,  // card error
            1L shl 2,  // unformatted
            1L shl 3,  // full
            1L shl 11  // protected
        )

        storageFailures.forEach { condition ->
            assertFalse(
                movieStartNeedsLiveViewRestart(
                    responseCode = 0xA004,
                    prohibitCondition = condition
                )
            )
        }
    }

    @Test
    fun restartsLiveViewForApplicationModeAndLiveViewStateFailures() {
        assertTrue(
            movieStartNeedsLiveViewRestart(
                responseCode = 0xA004,
                prohibitCondition = 1L shl 14
            )
        )
        assertTrue(
            movieStartNeedsLiveViewRestart(
                responseCode = 0xA004,
                prohibitCondition = 1L shl 12
            )
        )
        assertTrue(
            movieStartNeedsLiveViewRestart(
                responseCode = 0xA004,
                prohibitCondition = null
            )
        )
    }

    @Test
    fun successfulStartNeverRestartsLiveView() {
        assertFalse(
            movieStartNeedsLiveViewRestart(
                responseCode = Lab.OK,
                prohibitCondition = 1L shl 14
            )
        )
    }

    @Test
    fun doesNotRestartForNonRecoverableMovieStates() {
        assertFalse(
            movieStartNeedsLiveViewRestart(
                responseCode = 0xA004,
                prohibitCondition = 1L shl 9 // buffer pending
            )
        )
        assertFalse(
            movieStartNeedsLiveViewRestart(
                responseCode = 0xA004,
                prohibitCondition = 1L shl 10 // already recording
            )
        )
        assertFalse(
            movieStartNeedsLiveViewRestart(
                responseCode = 0xA004,
                prohibitCondition = 1L shl 13 // selector is not in movie position
            )
        )
        assertFalse(
            movieStartNeedsLiveViewRestart(
                responseCode = 0x2005,
                prohibitCondition = null // unsupported operation
            )
        )
    }

    @Test
    fun detectsCameraAlreadyRecording() {
        assertTrue(movieProhibitIndicatesRecording(1L shl 10))
        assertFalse(movieProhibitIndicatesRecording(1L shl 14))
        assertFalse(movieProhibitIndicatesRecording(null))
    }

    @Test
    fun onlyApplicationModeBitRequiresApplicationModeTransition() {
        assertTrue(movieProhibitRequiresApplicationMode(1L shl 14))
        assertTrue(movieProhibitRequiresApplicationMode((1L shl 14) or (1L shl 18)))
        assertFalse(movieProhibitRequiresApplicationMode(1L shl 0))
        assertFalse(movieProhibitRequiresApplicationMode(1L shl 18))
        assertFalse(movieProhibitRequiresApplicationMode(null))
    }

    @Test
    fun propertyFallbackOnlyRunsForUnsupportedApplicationOperation() {
        assertTrue(
            shouldFallbackToApplicationModeProperty(
                PtpConstants.OPERATION_NOT_SUPPORTED
            )
        )
        assertFalse(shouldFallbackToApplicationModeProperty(Lab.OK))
        assertFalse(shouldFallbackToApplicationModeProperty(Lab.DEVICE_BUSY))
        assertFalse(shouldFallbackToApplicationModeProperty(0xA004))
    }

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
            diagnostic
        )
    }
}
