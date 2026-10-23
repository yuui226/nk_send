package com.ztransfer.gps

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GpsRecoveryPolicyTest {
    @Test
    fun immediateSyncIsAvailableOnlyWithCoordinatesInAnIdleSession() {
        val ready = GpsState(enabled = true, status = GpsStatus.READY, latitude = 0.0, longitude = 0.0)
        assertTrue(ready.canSyncNow) // Zero coordinates are valid, not a missing fix.
        assertTrue(ready.copy(status = GpsStatus.CONNECTED).canSyncNow)
        assertTrue(ready.copy(status = GpsStatus.WAITING_FIX).canSyncNow)
        assertTrue(ready.copy(status = GpsStatus.PAIRING_SUCCESS).canSyncNow)
        assertFalse(ready.copy(enabled = false).canSyncNow)
        assertFalse(ready.copy(latitude = null).canSyncNow)
        assertFalse(ready.copy(longitude = null).canSyncNow)
        for (status in listOf(
            GpsStatus.WRITING, GpsStatus.CONNECTING, GpsStatus.SEARCHING,
            GpsStatus.OFF, GpsStatus.ERROR, GpsStatus.AP_UNAVAILABLE,
        )) assertFalse("Must not sync while $status", ready.copy(status = status).canSyncNow)
    }

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
