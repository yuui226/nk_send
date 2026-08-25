package com.ztransfer.viewmodel

import com.ztransfer.protocol.CameraConnectionType
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
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
    fun staServiceReadinessRetryIsLimitedToShortLivedTcpFailures() {
        assertTrue(isTransientStaServiceReadinessFailure(SocketTimeoutException("starting")))
        assertTrue(isTransientStaServiceReadinessFailure(ConnectException("starting")))
        assertFalse(isTransientStaServiceReadinessFailure(NoRouteToHostException("offline")))
        assertFalse(isTransientStaServiceReadinessFailure(IllegalStateException("protocol")))
        assertFalse(isTransientStaServiceReadinessFailure(null))
    }

    @Test
    fun savedWirelessModeIsRestoredAndUnknownValuesFallBackToAp() {
        assertEquals(WirelessMode.AP, restoredWirelessMode(null))
        assertEquals(WirelessMode.AP, restoredWirelessMode("unknown"))
        assertEquals(WirelessMode.AP, restoredWirelessMode("AP"))
        assertEquals(WirelessMode.STA, restoredWirelessMode("STA"))
    }

    @Test
    fun apStillRejectsAggregateStorageIds() {
        assertEquals(
            listOf(0x00010001),
            usableStorageIds(listOf(0x00010000, 0x00010001), isStaConnection = false),
        )
        assertEquals(0x00010001, objectHandleQueryStorageId(0x00010001, false))
    }

    @Test
    fun staKeepsNikonAggregateStorageAndQueriesItByWildcard() {
        assertEquals(
            listOf(0x00010000),
            usableStorageIds(listOf(0, -1, 0x00010000), isStaConnection = true),
        )
        assertEquals(-1, objectHandleQueryStorageId(0x00010000, true))
    }
}
