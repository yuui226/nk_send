package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraConnectionType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
}
