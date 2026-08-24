package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.viewmodel.StaConnectionStatus
import com.ztransfer.viewmodel.WirelessMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeConnectionPresentationTest {
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
}
