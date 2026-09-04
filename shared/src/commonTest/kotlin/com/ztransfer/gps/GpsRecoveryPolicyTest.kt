package com.ztransfer.gps

import kotlin.test.Test
import kotlin.test.assertEquals

class GpsRecoveryPolicyTest {
    @Test
    fun freshLeIdentityHandshakeIsAlreadyConnected() {
        assertEquals(
            GpsStatus.CONNECTED,
            gpsStatusAfterCameraReady(preserveReadyDuringReconnect = false),
        )
    }

    @Test
    fun establishedReconnectKeepsReadyPresentation() {
        assertEquals(
            GpsStatus.READY,
            gpsStatusAfterCameraReady(preserveReadyDuringReconnect = true),
        )
    }

    @Test
    fun connectedCameraRetriesOnlyPhoneLocation() {
        assertEquals(
            GpsRecoveryTarget.LOCATION_ONLY,
            gpsRecoveryTarget(cameraReady = true, bleClientRunning = true),
        )
    }

    @Test
    fun incompleteCameraSessionUsesFullConnectionRecovery() {
        listOf(
            false to false,
            false to true,
            true to false,
        ).forEach { (cameraReady, bleClientRunning) ->
            assertEquals(
                GpsRecoveryTarget.FULL_CONNECTION,
                gpsRecoveryTarget(
                    cameraReady = cameraReady,
                    bleClientRunning = bleClientRunning,
                ),
            )
        }
    }
}
