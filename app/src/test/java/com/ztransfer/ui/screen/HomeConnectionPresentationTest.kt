package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.viewmodel.CameraState
import com.ztransfer.viewmodel.StaConnectionStatus
import com.ztransfer.viewmodel.WirelessMode
import com.ztransfer.viewmodel.WifiConnectionStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeConnectionPresentationTest {
    @Test
    fun allThreeConnectionTypesHaveDistinctSuccessOutcomes() {
        assertEquals(
            ConnectionHapticOutcome.USB_SUCCESS,
            CameraState(
                isConnectedToCamera = true,
                connectionType = CameraConnectionType.USB,
            ).toHomeConnectionUiState().connectionHapticOutcome(),
        )
        assertEquals(
            ConnectionHapticOutcome.AP_SUCCESS,
            CameraState(
                isConnectedToCamera = true,
                connectionType = CameraConnectionType.WIFI,
                wirelessMode = WirelessMode.AP,
            ).toHomeConnectionUiState().connectionHapticOutcome(),
        )
        assertEquals(
            ConnectionHapticOutcome.STA_SUCCESS,
            CameraState(
                isConnectedToCamera = true,
                connectionType = CameraConnectionType.WIFI,
                wirelessMode = WirelessMode.STA,
                isStaConnection = true,
            ).toHomeConnectionUiState().connectionHapticOutcome(),
        )
    }

    @Test
    fun allThreeConnectionTypesHaveFailureOutcomes() {
        val usbFailure = CameraState(
            connectionType = CameraConnectionType.USB,
            usbConnectionError = "USB failed",
        ).toHomeConnectionUiState().connectionHapticOutcome()
        val staFailure = CameraState(
            wirelessMode = WirelessMode.STA,
            staConnectionStatus = StaConnectionStatus.FAILED,
            staConnectionError = "STA failed",
        ).toHomeConnectionUiState().connectionHapticOutcome()

        assertEquals(ConnectionHapticOutcome.USB_FAILURE, usbFailure)
        assertEquals(ConnectionHapticOutcome.STA_FAILURE, staFailure)
        assertTrue(usbFailure.isFailure)
        assertTrue(staFailure.isFailure)

        listOf(
            WifiConnectionStatus.NOT_FOUND,
            WifiConnectionStatus.REFUSED,
            WifiConnectionStatus.FAILED,
        ).forEach { status ->
            val outcome = CameraState(
                wirelessMode = WirelessMode.AP,
                wifiConnectionStatus = status,
            ).toHomeConnectionUiState().connectionHapticOutcome()
            assertEquals(ConnectionHapticOutcome.AP_FAILURE, outcome)
            assertTrue(outcome.isFailure)
        }
    }

    @Test
    fun transientConnectionStatesDoNotProduceResultHaptics() {
        listOf(
            CameraState(),
            CameraState(
                wirelessMode = WirelessMode.AP,
                wifiConnectionStatus = WifiConnectionStatus.PROBING,
            ),
            CameraState(
                wirelessMode = WirelessMode.AP,
                wifiConnectionStatus = WifiConnectionStatus.RECONNECTING,
            ),
            CameraState(
                wirelessMode = WirelessMode.STA,
                staConnectionStatus = StaConnectionStatus.DISCOVERING,
            ),
        ).forEach { state ->
            assertEquals(
                ConnectionHapticOutcome.NONE,
                state.toHomeConnectionUiState().connectionHapticOutcome(),
            )
        }
    }

    @Test
    fun staConnectButtonBreathingIsSmoothAndPeriodic() {
        assertEquals(0f, staButtonBreathProgress(-1L), 0.001f)
        assertEquals(0f, staButtonBreathProgress(0L), 0.001f)
        assertEquals(0.5f, staButtonBreathProgress(450L), 0.001f)
        assertEquals(1f, staButtonBreathProgress(900L), 0.001f)
        assertEquals(0.5f, staButtonBreathProgress(1_350L), 0.001f)
        assertEquals(0f, staButtonBreathProgress(1_800L), 0.001f)
    }

    @Test
    fun connectionCelebrationUsesOneContinuousTimeline() {
        assertEquals(0f, connectionHeroProgress(-1L), 0f)
        assertEquals(0.5f, connectionHeroProgress(310L), 0.001f)
        assertEquals(1f, connectionHeroProgress(620L), 0f)
        assertEquals(1f, connectionHeroProgress(10_000L), 0f)

        assertEquals(0f, connectionSuccessProgress(499L), 0f)
        assertEquals(0f, connectionSuccessProgress(500L), 0f)
        assertEquals(1f, connectionSuccessProgress(1_260L), 0f)
    }

    @Test
    fun freeConnectionPulsesAreStaggeredAndDisappearCompletely() {
        assertEquals(0f, freeConnectionPulseVisibility(-1f), 0f)
        assertEquals(0f, freeConnectionPulseVisibility(0f), 0f)
        assertTrue(freeConnectionPulseVisibility(0.10f) > 0f)
        assertTrue(freeConnectionPulseVisibility(0.50f) > 0f)
        assertEquals(0f, freeConnectionPulseVisibility(1f), 0f)
        assertEquals(0f, freeConnectionPulseVisibility(2f), 0f)

        assertTrue(freeConnectionPulseProgress(0.10f, 0) > 0f)
        assertEquals(0f, freeConnectionPulseProgress(0.10f, 1), 0f)
        assertTrue(freeConnectionPulseProgress(0.20f, 1) > 0f)
        assertEquals(
            0f,
            freeConnectionPulseVisibility(freeConnectionPulseProgress(1f, 0)),
            0f,
        )
        assertEquals(
            0f,
            freeConnectionPulseVisibility(freeConnectionPulseProgress(1f, 1)),
            0f,
        )
    }

    @Test
    fun albumScanChangesDoNotInvalidateConnectionPresentation() {
        val initial = CameraState().toHomeConnectionUiState()
        val scanning = CameraState(
            isLoadingFiles = true,
            hasCompletedFileScan = true,
            storageIds = listOf(0x00010001),
        ).toHomeConnectionUiState()

        assertEquals(initial, scanning)
        assertTrue(
            initial != CameraState(
                isConnectedToCamera = true,
                connectionType = CameraConnectionType.WIFI,
            ).toHomeConnectionUiState()
        )
    }

    @Test
    fun disconnectedWifiNeverEntersTheSelectedScene() {
        assertNull(
            homeSelectedConnection(
                connected = false,
                connectionType = CameraConnectionType.WIFI
            )
        )
    }

    @Test
    fun verifiedWifiEntersTheSelectedScene() {
        assertEquals(
            CameraConnectionType.WIFI,
            homeSelectedConnection(
                connected = true,
                connectionType = CameraConnectionType.WIFI
            )
        )
    }

    @Test
    fun existingUsbPresentationIsPreserved() {
        assertEquals(
            CameraConnectionType.USB,
            homeSelectedConnection(
                connected = false,
                connectionType = CameraConnectionType.USB
            )
        )
    }

    @Test
    fun usbSelectionSuppressesAllWifiFeedback() {
        assertFalse(shouldShowWifiConnectionFeedback(CameraConnectionType.USB))
    }

    @Test
    fun wifiFeedbackRemainsAvailableBeforeAndDuringWifiSelection() {
        assertTrue(shouldShowWifiConnectionFeedback(null))
        assertTrue(shouldShowWifiConnectionFeedback(CameraConnectionType.WIFI))
    }

    @Test
    fun staStateSuppressesOnlyCameraHotspotFeedback() {
        assertFalse(
            shouldShowCameraHotspotFeedback(
                connectionType = CameraConnectionType.WIFI,
                isStaConnection = true,
            )
        )
        assertFalse(
            shouldShowCameraHotspotFeedback(
                connectionType = null,
                staStatus = StaConnectionStatus.DISCOVERING,
            )
        )
        assertFalse(
            shouldShowCameraHotspotFeedback(
                connectionType = null,
                wirelessMode = WirelessMode.STA,
            )
        )
        assertTrue(
            shouldShowCameraHotspotFeedback(
                connectionType = CameraConnectionType.WIFI,
                isStaConnection = false,
                staStatus = StaConnectionStatus.IDLE,
            )
        )
    }

    @Test
    fun disconnectedFileListKeepsTheSessionTransport() {
        assertEquals(
            CameraConnectionType.USB,
            disconnectedConnectionType(CameraConnectionType.USB)
        )
        assertEquals(
            CameraConnectionType.WIFI,
            disconnectedConnectionType(CameraConnectionType.WIFI)
        )
    }

    @Test
    fun subscriptionExpiryNoticeUsesTheOriginalSevenDayWindow() {
        assertFalse(shouldShowSubscriptionExpiryNotice(isPro = true, daysLeft = 8))
        assertTrue(shouldShowSubscriptionExpiryNotice(isPro = true, daysLeft = 7))
        assertTrue(shouldShowSubscriptionExpiryNotice(isPro = true, daysLeft = 0))
        assertFalse(shouldShowSubscriptionExpiryNotice(isPro = false, daysLeft = 7))
    }
}
