package com.ztransfer.viewmodel

import com.ztransfer.protocol.CameraConnectionType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StaConnectionIsolationTest {
    @Test
    fun staStateIsCompletelyInactiveByDefault() {
        val state = CameraState()

        assertFalse(state.isStaConnection)
        assertTrue(state.wirelessMode == WirelessMode.AP)
        assertTrue(state.staConnectionStatus == StaConnectionStatus.IDLE)
        assertTrue(state.staDiscoveryProgress == null)
        assertTrue(state.staConnectionError == null)
    }

    @Test
    fun existingTransportsNeverEnterStaReconnectPath() {
        assertFalse(shouldReconnectUsingSta(null, WirelessMode.AP))
        assertFalse(shouldReconnectUsingSta(CameraConnectionType.WIFI, WirelessMode.AP))
        assertFalse(shouldReconnectUsingSta(CameraConnectionType.USB, WirelessMode.AP))
        assertFalse(shouldReconnectUsingSta(CameraConnectionType.USB, WirelessMode.STA))
    }

    @Test
    fun onlyStaOriginWifiSessionUsesStaReconnectPath() {
        assertTrue(shouldReconnectUsingSta(CameraConnectionType.WIFI, WirelessMode.STA))
    }

    @Test
    fun savedWirelessModeIsRestoredAndUnknownValuesFallBackToAp() {
        assertEquals(WirelessMode.AP, restoredWirelessMode(null))
        assertEquals(WirelessMode.AP, restoredWirelessMode("unknown"))
        assertEquals(WirelessMode.AP, restoredWirelessMode("AP"))
        assertEquals(WirelessMode.STA, restoredWirelessMode("STA"))
    }
}
