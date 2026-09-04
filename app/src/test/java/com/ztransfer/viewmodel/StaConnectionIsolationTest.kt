package com.ztransfer.viewmodel

import com.ztransfer.connection.StaConnectionStatus
import com.ztransfer.connection.WirelessMode
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StaConnectionIsolationTest {
    @Test
    fun staConnectionRemainsInactiveWhenStaIsTheDefaultMode() {
        val state = CameraState()

        assertFalse(state.isStaConnection)
        assertTrue(state.wirelessMode == WirelessMode.STA)
        assertTrue(state.staConnectionStatus == StaConnectionStatus.IDLE)
        assertTrue(state.staDiscoveryProgress == null)
        assertTrue(state.staConnectionError == null)
    }

    @Test
    fun staServiceReadinessRetryIsLimitedToShortLivedStartupFailures() {
        assertTrue(isTransientStaServiceReadinessFailure(SocketTimeoutException("starting")))
        assertTrue(isTransientStaServiceReadinessFailure(ConnectException("starting")))
        assertTrue(
            isTransientStaServiceReadinessFailure(
                IOException("STA album access unavailable (0x2001)"),
            ),
        )
        assertFalse(isTransientStaServiceReadinessFailure(IOException("unrelated IO failure")))
        assertFalse(isTransientStaServiceReadinessFailure(NoRouteToHostException("offline")))
        assertFalse(isTransientStaServiceReadinessFailure(IllegalStateException("protocol")))
        assertFalse(isTransientStaServiceReadinessFailure(null))
    }

}
