package com.ztransfer.ui.screen

import com.ztransfer.connection.StaConnectionStatus
import com.ztransfer.connection.WifiConnectionStatus
import com.ztransfer.connection.WirelessMode
import com.ztransfer.protocol.CameraConnectionType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class HomeConnectionPresentationTest {
    private fun state(
        connected: Boolean = false,
        connectionType: CameraConnectionType? = null,
        wirelessMode: WirelessMode = WirelessMode.STA,
        staConnection: Boolean = false,
        staStatus: StaConnectionStatus = StaConnectionStatus.IDLE,
        usbError: String? = null,
        wifiStatus: WifiConnectionStatus = WifiConnectionStatus.IDLE,
    ) = HomeConnectionUiState(
        isConnectedToCamera = connected,
        connectionType = connectionType,
        wirelessMode = wirelessMode,
        isStaConnection = staConnection,
        staConnectionStatus = staStatus,
        staConnectionError = null,
        usbConnectionError = usbError,
        wifiConnectionStatus = wifiStatus,
    )

    @Test
    fun allThreeConnectionTypesHaveDistinctSuccessOutcomes() {
        assertEquals(
            ConnectionHapticOutcome.USB_SUCCESS,
            state(connected = true, connectionType = CameraConnectionType.USB)
                .connectionHapticOutcome(),
        )
        assertEquals(
            ConnectionHapticOutcome.AP_SUCCESS,
            state(
                connected = true,
                connectionType = CameraConnectionType.WIFI,
                wirelessMode = WirelessMode.AP,
            ).connectionHapticOutcome(),
        )
        assertEquals(
            ConnectionHapticOutcome.STA_SUCCESS,
            state(
                connected = true,
                connectionType = CameraConnectionType.WIFI,
                staConnection = true,
            ).connectionHapticOutcome(),
        )
    }

    @Test
    fun allThreeConnectionTypesHaveFailureOutcomes() {
        val usbFailure = state(
            connectionType = CameraConnectionType.USB,
            usbError = "USB failed",
        ).connectionHapticOutcome()
        val staFailure = state(
            wirelessMode = WirelessMode.STA,
            staStatus = StaConnectionStatus.FAILED,
        ).connectionHapticOutcome()

        assertEquals(ConnectionHapticOutcome.USB_FAILURE, usbFailure)
        assertEquals(ConnectionHapticOutcome.STA_FAILURE, staFailure)
        assertTrue(usbFailure.isFailure)
        assertTrue(staFailure.isFailure)

        listOf(
            WifiConnectionStatus.NOT_FOUND,
            WifiConnectionStatus.REFUSED,
            WifiConnectionStatus.FAILED,
        ).forEach { status ->
            val outcome = state(
                wirelessMode = WirelessMode.AP,
                wifiStatus = status,
            ).connectionHapticOutcome()
            assertEquals(ConnectionHapticOutcome.AP_FAILURE, outcome)
            assertTrue(outcome.isFailure)
        }
    }

    @Test
    fun transientConnectionStatesDoNotProduceResultHaptics() {
        listOf(
            state(),
            state(wirelessMode = WirelessMode.AP, wifiStatus = WifiConnectionStatus.PROBING),
            state(
                wirelessMode = WirelessMode.AP,
                wifiStatus = WifiConnectionStatus.RECONNECTING,
            ),
            state(staStatus = StaConnectionStatus.DISCOVERING),
        ).forEach { presentation ->
            assertEquals(ConnectionHapticOutcome.NONE, presentation.connectionHapticOutcome())
        }
    }

    @Test
    fun connectionSelectionPreservesUsbAndRequiresVerifiedWifi() {
        assertEquals(
            CameraConnectionType.USB,
            homeSelectedConnection(false, CameraConnectionType.USB),
        )
        assertNull(homeSelectedConnection(false, CameraConnectionType.WIFI))
        assertEquals(
            CameraConnectionType.WIFI,
            homeSelectedConnection(true, CameraConnectionType.WIFI),
        )
    }

    @Test
    fun usbSuppressesWifiFeedbackWhileStaSuppressesOnlyHotspotFeedback() {
        assertFalse(shouldShowWifiConnectionFeedback(CameraConnectionType.USB))
        assertTrue(shouldShowWifiConnectionFeedback(null))
        assertTrue(shouldShowWifiConnectionFeedback(CameraConnectionType.WIFI))

        assertFalse(
            shouldShowCameraHotspotFeedback(
                connectionType = CameraConnectionType.WIFI,
                isStaConnection = true,
            ),
        )
        assertFalse(
            shouldShowCameraHotspotFeedback(
                connectionType = null,
                staStatus = StaConnectionStatus.DISCOVERING,
            ),
        )
        assertFalse(
            shouldShowCameraHotspotFeedback(
                connectionType = null,
                wirelessMode = WirelessMode.STA,
            ),
        )
        assertTrue(
            shouldShowCameraHotspotFeedback(
                connectionType = CameraConnectionType.WIFI,
                staStatus = StaConnectionStatus.IDLE,
            ),
        )
    }
}
