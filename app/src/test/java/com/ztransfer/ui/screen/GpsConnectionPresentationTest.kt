package com.ztransfer.ui.screen

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
    fun unavailableAltitudeDisplaysAsZeroMeters() {
        assertEquals(0, gpsDisplayedAltitudeMeters(null))
        assertEquals(0, gpsDisplayedAltitudeMeters(0.0))
        assertEquals(55, gpsDisplayedAltitudeMeters(55.34))
    }

    @Test
    fun nextUpdateCountdownUsesLastSuccessfulWriteAndRoundsUp() {
        assertNull(
            gpsNextUpdateRemainingSeconds(
                lastUpdatedAtMs = null,
                intervalMillis = 60_000L,
                nowMs = 10_000L,
            )
        )
        assertEquals(
            60L,
            gpsNextUpdateRemainingSeconds(
                lastUpdatedAtMs = 10_000L,
                intervalMillis = 60_000L,
                nowMs = 10_001L,
            )
        )
        assertEquals(
            1L,
            gpsNextUpdateRemainingSeconds(
                lastUpdatedAtMs = 10_000L,
                intervalMillis = 60_000L,
                nowMs = 69_999L,
            )
        )
        assertEquals(
            0L,
            gpsNextUpdateRemainingSeconds(
                lastUpdatedAtMs = 10_000L,
                intervalMillis = 60_000L,
                nowMs = 70_000L,
            )
        )
        assertEquals("0:00", gpsCountdownText(0L))
        assertEquals("0:09", gpsCountdownText(9L))
        assertEquals("5:00", gpsCountdownText(300L))
    }

    @Test
    fun closingAnimatedLayersStayMountedUntilTheirExitCompletes() {
        assertTrue(
            gpsAnimatedLayerActive(
                currentState = true,
                targetState = false,
            )
        )
        assertFalse(
            gpsAnimatedLayerActive(
                currentState = false,
                targetState = false,
            )
        )
    }

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
    fun onlyEstablishedCameraSessionRequiresHoldToDisable() {
        listOf(
            GpsStatus.PAIRING_SUCCESS,
            GpsStatus.CONNECTED,
            GpsStatus.WRITING,
            GpsStatus.WAITING_FIX,
            GpsStatus.READY,
        ).forEach { status ->
            assertTrue(gpsStatusRequiresHoldToDisable(enabled = true, status = status))
        }
        listOf(
            GpsStatus.OFF,
            GpsStatus.STARTING,
            GpsStatus.SEARCHING,
            GpsStatus.NEEDS_CAMERA,
            GpsStatus.CONNECTING,
            GpsStatus.PAIRING,
            GpsStatus.CAMERA_CONFIRM,
            GpsStatus.AP_UNAVAILABLE,
            GpsStatus.ERROR,
        ).forEach { status ->
            assertFalse(gpsStatusRequiresHoldToDisable(enabled = true, status = status))
        }
        assertFalse(
            gpsStatusRequiresHoldToDisable(
                enabled = false,
                status = GpsStatus.CONNECTED,
            )
        )
    }

    @Test
    fun timingControlsStayHiddenUntilTheCameraSessionIsEstablished() {
        listOf(
            GpsStatus.STARTING,
            GpsStatus.SEARCHING,
            GpsStatus.NEEDS_CAMERA,
            GpsStatus.CONNECTING,
            GpsStatus.PAIRING,
            GpsStatus.CAMERA_CONFIRM,
            GpsStatus.ERROR,
        ).forEach { status ->
            assertFalse(gpsTimingControlsVisible(enabled = true, status = status))
        }
        listOf(
            GpsStatus.PAIRING_SUCCESS,
            GpsStatus.CONNECTED,
            GpsStatus.WRITING,
            GpsStatus.WAITING_FIX,
            GpsStatus.READY,
        ).forEach { status ->
            assertTrue(gpsTimingControlsVisible(enabled = true, status = status))
        }
        assertFalse(
            gpsTimingControlsVisible(
                enabled = false,
                status = GpsStatus.READY,
            )
        )
    }

    @Test
    fun leConnectionProgressStillLooksLikeConnectionProgress() {
        assertEquals(
            GpsStatusButtonState.CONNECTING,
            gpsStatusButtonState(enabled = true, status = GpsStatus.CONNECTING),
        )
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
