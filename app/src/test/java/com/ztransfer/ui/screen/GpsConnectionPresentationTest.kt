package com.ztransfer.ui.screen

import com.ztransfer.gps.GpsState
import com.ztransfer.gps.GpsStatus
import com.ztransfer.gps.GpsPlaceLookupState
import com.ztransfer.gps.GpsPlaceLookupStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GpsConnectionPresentationTest {
    @Test
    fun connectedCameraWorkStatesNeverLookLikeConnectionProgress() {
        listOf(
            GpsStatus.PAIRING_SUCCESS,
            GpsStatus.CONNECTED,
            GpsStatus.WRITING,
            GpsStatus.WAITING_FIX,
            GpsStatus.READY,
        ).forEach { status ->
            assertEquals(
                GpsStatusButtonState.ENABLED,
                gpsStatusButtonState(enabled = true, status = status),
            )
        }
    }

    @Test
    fun leConnectionProgressStillLooksLikeConnectionProgress() {
        assertEquals(
            GpsStatusButtonState.CONNECTING,
            gpsStatusButtonState(enabled = true, status = GpsStatus.CONNECTING),
        )
    }

    @Test
    fun connectedStatesCollapseIntoOneSuccessOutcome() {
        listOf(
            GpsStatus.PAIRING_SUCCESS,
            GpsStatus.CONNECTED,
            GpsStatus.WRITING,
            GpsStatus.WAITING_FIX,
            GpsStatus.READY,
        ).forEach { status ->
            assertEquals(
                GpsConnectionHapticOutcome.SUCCESS,
                GpsState(enabled = true, status = status).gpsConnectionHapticOutcome(),
            )
        }
    }

    @Test
    fun actionableConnectionFailuresCollapseIntoOneFailureOutcome() {
        listOf(
            GpsStatus.NEEDS_CAMERA,
            GpsStatus.AP_UNAVAILABLE,
            GpsStatus.ERROR,
        ).forEach { status ->
            assertEquals(
                GpsConnectionHapticOutcome.FAILURE,
                GpsState(enabled = true, status = status).gpsConnectionHapticOutcome(),
            )
        }
    }

    @Test
    fun disabledAndProgressStatesDoNotProduceResultHaptics() {
        GpsStatus.entries.forEach { status ->
            assertEquals(
                GpsConnectionHapticOutcome.NONE,
                GpsState(enabled = false, status = status).gpsConnectionHapticOutcome(),
            )
        }
        listOf(
            GpsStatus.OFF,
            GpsStatus.STARTING,
            GpsStatus.SEARCHING,
            GpsStatus.CONNECTING,
            GpsStatus.PAIRING,
            GpsStatus.CAMERA_CONFIRM,
        ).forEach { status ->
            assertEquals(
                GpsConnectionHapticOutcome.NONE,
                GpsState(enabled = true, status = status).gpsConnectionHapticOutcome(),
            )
        }
    }

    @Test
    fun reconnectDoesNotFlashFirstUseStepsAfterASessionWasEstablished() {
        listOf(
            GpsStatus.STARTING,
            GpsStatus.SEARCHING,
            GpsStatus.CONNECTING,
            GpsStatus.ERROR,
        ).forEach { transientStatus ->
            assertFalse(
                shouldShowGpsConnectionSteps(
                    status = transientStatus,
                    sessionEstablished = true,
                )
            )
        }
    }

    @Test
    fun firstConnectionKeepsStepsUntilCoordinatesOrAStableSessionArrives() {
        assertTrue(
            shouldShowGpsConnectionSteps(
                status = GpsStatus.CONNECTING,
                sessionEstablished = false,
            )
        )
        assertTrue(
            gpsSessionPresentationEstablished(
                status = GpsStatus.CONNECTING,
                hasCoordinates = true,
            )
        )
        assertEquals(
            GpsDetailPrimaryContent.LOCATION,
            gpsDetailPrimaryContent(
                enabled = true,
                hasCoordinates = true,
                showConnectionSteps = false,
            )
        )
        assertEquals(
            GpsDetailPrimaryContent.STABLE_STATUS,
            gpsDetailPrimaryContent(
                enabled = true,
                hasCoordinates = false,
                showConnectionSteps = false,
            )
        )
    }

    @Test
    fun placeBubbleNeverFlashesAResultFromPreviousCoordinates() {
        val previousResult = GpsPlaceLookupState(
            latitude = 31.2304,
            longitude = 121.4737,
            status = GpsPlaceLookupStatus.SUCCESS,
            placeName = "上一个地点",
        )

        val presentation = gpsPlaceBubblePresentation(
            latitude = 24.4900,
            longitude = 118.1800,
            lookupState = previousResult,
        )

        assertEquals(GpsPlaceLookupStatus.LOADING, presentation.status)
        assertEquals(24.4900, presentation.latitude!!, 0.0)
        assertEquals(118.1800, presentation.longitude!!, 0.0)
        assertNull(presentation.placeName)
    }

    @Test
    fun placeBubbleCanImmediatelyReuseTheMatchingCachedResult() {
        val matchingResult = GpsPlaceLookupState(
            latitude = 24.4900,
            longitude = 118.1800,
            status = GpsPlaceLookupStatus.SUCCESS,
            placeName = "当前地点",
        )

        assertEquals(
            matchingResult,
            gpsPlaceBubblePresentation(
                latitude = 24.4900,
                longitude = 118.1800,
                lookupState = matchingResult,
            )
        )
    }
}
