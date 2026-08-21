package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraConnectionType
import org.junit.Assert.assertEquals
import org.junit.Test

class LicenseDialogPolicyTest {

    @Test
    fun connectionPageAndUsbOpenCodeEntryDirectly() {
        assertEquals(EnterCodeAction.OPEN, enterCodeAction(null, cameraConnected = false))
        assertEquals(
            EnterCodeAction.OPEN,
            enterCodeAction(CameraConnectionType.USB, cameraConnected = true),
        )
        assertEquals(
            EnterCodeAction.OPEN,
            enterCodeAction(CameraConnectionType.USB, cameraConnected = false),
        )
    }

    @Test
    fun connectedWifiShowsNetworkHintWithoutProbing() {
        assertEquals(
            EnterCodeAction.SHOW_NETWORK_HINT,
            enterCodeAction(CameraConnectionType.WIFI, cameraConnected = true),
        )
    }

    @Test
    fun disconnectedWifiProbesServerBeforeOpeningCodeEntry() {
        assertEquals(
            EnterCodeAction.PROBE_SERVER,
            enterCodeAction(CameraConnectionType.WIFI, cameraConnected = false),
        )
    }
}
