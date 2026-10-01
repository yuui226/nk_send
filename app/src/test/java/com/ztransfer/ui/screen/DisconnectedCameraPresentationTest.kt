package com.ztransfer.ui.screen

import com.ztransfer.R
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.viewmodel.CameraConnectionMode
import com.ztransfer.viewmodel.CameraState
import com.ztransfer.viewmodel.WirelessMode
import com.ztransfer.viewmodel.canRetryStaConnection
import com.ztransfer.viewmodel.connectionMode
import com.ztransfer.viewmodel.restoredConnectionMode
import org.junit.Assert.*
import org.junit.Test

class DisconnectedCameraPresentationTest {
    @Test
    fun everyTransportKeepsItsHintActionAndOfflineStyleAfterDisconnect() {
        for (mode in CameraConnectionMode.entries) {
            val connected = CameraState(
                isConnectedToCamera = true,
                connectionType = if (mode == CameraConnectionMode.USB) CameraConnectionType.USB else CameraConnectionType.WIFI,
                isStaConnection = mode == CameraConnectionMode.STA,
                // USB commonly retains STA as the preferred wireless mode.
                wirelessMode = if (mode == CameraConnectionMode.AP) WirelessMode.AP else WirelessMode.STA,
                wifiRssi = -35,
            )
            // A stale RSSI must not make any disconnected transport appear online.
            assertDisconnected(connected.copy(isConnectedToCamera = false), mode)
            // A reconnect can clear the list then lose transport before its first batch.
            assertDisconnected(connected.copy(
                isConnectedToCamera = false,
                isLoadingFiles = false,
                hasCompletedFileScan = false,
                files = emptyList(),
            ), mode)
        }
    }

    @Test
    fun processRecreationRestoresPresentationWithoutInventingALiveSession() {
        for (mode in CameraConnectionMode.entries) {
            val restored = CameraState(
                rememberedConnectionMode = restoredConnectionMode(mode.name),
                // The last USB transport must win over saved wireless preferences.
                wirelessMode = WirelessMode.STA,
            )
            assertNull(restored.connectionType)
            assertFalse(restored.isConnectedToCamera)
            assertFalse(restored.isStaConnection)
            assertDisconnected(restored, mode)
        }
    }

    @Test
    fun legacyOrInvalidSavedPresentationUsesSavedWirelessChoice() {
        for (saved in listOf(null, "invalid")) {
            assertNull(restoredConnectionMode(saved))
            for (wireless in WirelessMode.entries) {
                assertDisconnected(
                    CameraState(wirelessMode = wireless, rememberedConnectionMode = restoredConnectionMode(saved)),
                    if (wireless == WirelessMode.STA) CameraConnectionMode.STA else CameraConnectionMode.AP,
                )
            }
        }
    }

    @Test
    fun currentTransportOverridesRestoredHistoryAndUsbOverridesStaleStaFlag() {
        val usb = CameraState(
            connectionType = CameraConnectionType.USB,
            isStaConnection = true,
            rememberedConnectionMode = CameraConnectionMode.STA,
        )
        assertDisconnected(usb, CameraConnectionMode.USB)
        val ap = usb.copy(connectionType = CameraConnectionType.WIFI, isStaConnection = false)
        assertDisconnected(ap, CameraConnectionMode.AP)
        val sta = ap.copy(isStaConnection = true, rememberedConnectionMode = CameraConnectionMode.USB)
        assertDisconnected(sta, CameraConnectionMode.STA)
        assertFalse(sta.copy(isConnectedToCamera = true).canRetryStaConnection)
    }

    @Test
    fun retryingIsStillOfflineUntilConnectionActuallySucceeds() {
        val retrying = CameraState(
            rememberedConnectionMode = CameraConnectionMode.STA,
            isConnecting = true,
        )
        assertDisconnected(retrying, CameraConnectionMode.STA)
        val active = retrying.copy(
            isConnectedToCamera = true,
            connectionType = CameraConnectionType.WIFI,
            isStaConnection = true,
        ).toFileListSignalUiState()
        assertEquals(SignalPillMode.STA_ONLINE, signalPillMode(active.connectionType, active.staMode, active.connected, active.rssi))
    }

    private fun assertDisconnected(state: CameraState, expected: CameraConnectionMode) {
        assertEquals(expected, state.connectionMode)
        val body = state.toFileListCameraUiState()
        val signal = state.toFileListSignalUiState()
        assertEquals(body.connectionType, signal.connectionType)
        assertEquals(body.isStaConnection, signal.staMode)
        val content = disconnectedCameraPresentation(body.connectionType, body.isStaConnection)
        val style = signalPillMode(signal.connectionType, signal.staMode, signal.connected, signal.rssi)
        when (expected) {
            CameraConnectionMode.USB -> {
                assertEquals(R.string.usb_connection_lost, content.title)
                assertEquals(R.string.reconnect_camera_usb, content.hint)
                assertNull(content.actionLabel)
                assertEquals(SignalPillMode.USB_OFFLINE, style)
            }
            CameraConnectionMode.AP -> {
                assertEquals(R.string.connection_lost, content.title)
                assertEquals(R.string.connect_camera_wifi, content.hint)
                assertEquals(R.string.open_wifi_settings, content.actionLabel)
                assertEquals(SignalPillMode.WIFI_OFFLINE, style)
            }
            CameraConnectionMode.STA -> {
                assertEquals(R.string.connection_lost, content.title)
                assertEquals(R.string.reconnect_camera_sta, content.hint)
                assertEquals(R.string.reconnect_camera, content.actionLabel)
                assertEquals(SignalPillMode.STA_OFFLINE, style)
            }
        }
        assertEquals(expected == CameraConnectionMode.STA, state.canRetryStaConnection)
    }
}
