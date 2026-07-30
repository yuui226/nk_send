package com.ztransfer.viewmodel

import com.ztransfer.protocol.CameraRefusedException
import java.net.ConnectException
import java.net.SocketTimeoutException
import org.junit.Assert.assertEquals
import org.junit.Test

class WifiConnectionStatusTest {
    @Test
    fun explicitCameraRefusalIsNotReportedAsMissingCamera() {
        assertEquals(
            WifiConnectionStatus.REFUSED,
            classifyWifiConnectionFailure(CameraRefusedException("refused"))
        )
    }

    @Test
    fun unreachableEndpointIsReportedAsCameraNotFound() {
        assertEquals(
            WifiConnectionStatus.NOT_FOUND,
            classifyWifiConnectionFailure(ConnectException("refused"))
        )
        assertEquals(
            WifiConnectionStatus.NOT_FOUND,
            classifyWifiConnectionFailure(SocketTimeoutException("timeout"))
        )
    }

    @Test
    fun malformedHandshakeUsesTheGenericFailureState() {
        assertEquals(
            WifiConnectionStatus.FAILED,
            classifyWifiConnectionFailure(IllegalStateException("bad handshake"))
        )
    }
}
