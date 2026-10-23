package com.ztransfer.gps

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraWifiWakeStateTest {
    @Test
    fun onlyConnectingAndSendingKeepTheRequestBusy() {
        assertFalse(CameraWifiWakeState().isBusy)
        for (status in CameraWifiWakeStatus.values()) {
            assertEquals(
                status == CameraWifiWakeStatus.CONNECTING || status == CameraWifiWakeStatus.SENDING,
                CameraWifiWakeState(status).isBusy,
            )
        }
    }

    @Test
    fun successfulWriteRequiresReadyAndCompletesOnlyOnce() {
        val attempt = CameraWifiWakeAttempt()
        val connecting = attempt.state
        assertFalse(attempt.written(true))
        assertFalse(attempt.written(false))
        assertEquals(connecting, attempt.state)

        assertTrue(attempt.ready())
        assertEquals(CameraWifiWakeStatus.SENDING, attempt.state.status)
        assertTrue(attempt.state.isBusy)
        assertFalse(attempt.ready())
        assertTrue(attempt.written(true))
        assertEquals(CameraWifiWakeState(CameraWifiWakeStatus.REQUEST_SENT), attempt.state)
        assertTerminalCallbacksDoNotChange(attempt)
    }

    @Test
    fun rejectedWriteCannotBeOverwrittenByLateSuccess() {
        val attempt = CameraWifiWakeAttempt()
        assertTrue(attempt.ready())
        assertTrue(attempt.written(false))
        assertEquals(
            CameraWifiWakeState(CameraWifiWakeStatus.ERROR, CameraWifiWakeError.WRITE_FAILED),
            attempt.state,
        )
        assertTerminalCallbacksDoNotChange(attempt)
    }

    @Test
    fun failuresRemainTerminalBeforeAndAfterReady() {
        for (error in CameraWifiWakeError.values()) {
            for (ready in listOf(false, true)) {
                val attempt = CameraWifiWakeAttempt()
                if (ready) assertTrue(attempt.ready())
                assertTrue(attempt.fail(error))
                assertEquals(CameraWifiWakeState(CameraWifiWakeStatus.ERROR, error), attempt.state)
                assertTerminalCallbacksDoNotChange(attempt)
            }
        }
    }

    @Test
    fun cancellationDuringConnectOrWriteIgnoresEveryLateCallback() {
        for (ready in listOf(false, true)) {
            val attempt = CameraWifiWakeAttempt()
            if (ready) assertTrue(attempt.ready())
            attempt.cancel()
            assertEquals(CameraWifiWakeState(), attempt.state)
            assertTerminalCallbacksDoNotChange(attempt)
        }
    }

    @Test
    fun aNewAttemptDoesNotInheritThePreviousFailureOrCancellation() {
        val previous = CameraWifiWakeAttempt()
        previous.fail(CameraWifiWakeError.TIMEOUT)
        previous.cancel()
        val next = CameraWifiWakeAttempt()
        assertEquals(CameraWifiWakeState(CameraWifiWakeStatus.CONNECTING), next.state)
        assertTrue(next.ready())
        assertTrue(next.written(true))
        assertEquals(CameraWifiWakeError.TIMEOUT, previous.state.error)
    }

    @Test
    fun activeGpsRejectsWakeEvenWhenTheSavedCameraIsOtherwiseUsable() {
        assertEquals(CameraWifiWakeError.GPS_ACTIVE, preflight(gpsEnabled = true))
        assertEquals(
            CameraWifiWakeError.GPS_ACTIVE,
            cameraWifiWakePreflight(true, false, false, false, false),
        )
    }

    @Test
    fun savedIdentityAndAddressAreBothRequiredToAvoidPairingOrTargetingAnotherCamera() {
        for ((identity, address) in listOf(false to false, false to true, true to false)) {
            assertEquals(
                CameraWifiWakeError.NOT_PAIRED,
                preflight(hasSavedIdentity = identity, hasSavedAddress = address),
            )
        }
    }

    @Test
    fun missingPermissionWinsOverBluetoothOffForAPairedCamera() {
        assertEquals(CameraWifiWakeError.PERMISSION_REQUIRED, preflight(hasConnectPermission = false))
        assertEquals(
            CameraWifiWakeError.PERMISSION_REQUIRED,
            preflight(hasConnectPermission = false, bluetoothEnabled = false),
        )
    }

    @Test
    fun bluetoothMustBeEnabledBeforeTheRequestStarts() {
        assertEquals(CameraWifiWakeError.BLUETOOTH_OFF, preflight(bluetoothEnabled = false))
    }

    @Test
    fun pairedCameraWithPermissionAndBluetoothPassesWithoutEnablingGps() {
        assertNull(preflight())
    }

    @Test
    fun discoveryAndHandshakeFailuresDoNotFalselyReportUnsupportedCamera() {
        assertEquals(CameraWifiWakeError.CONNECTION_FAILED, cameraWifiWakeError("Camera service unavailable"))
        assertEquals(CameraWifiWakeError.CONNECTION_FAILED, cameraWifiWakeError("Camera not found"))
        assertEquals(CameraWifiWakeError.TIMEOUT, cameraWifiWakeError("Camera pairing handshake timeout"))
        assertEquals(CameraWifiWakeError.TIMEOUT, cameraWifiWakeError("GPS connection confirmation timeout"))
        assertEquals(CameraWifiWakeError.NOT_PAIRED, cameraWifiWakeError("Camera pairing identity expired"))
        assertEquals(CameraWifiWakeError.NOT_PAIRED, cameraWifiWakeError("Camera pairing rejected"))
    }

    @Test
    fun onlyMissingRequiredCharacteristicsReportUnsupportedCamera() {
        for (message in listOf(
            "Camera Wi-Fi service unavailable",
            "Camera GPS service unavailable",
            "Camera GPS notification unavailable",
        )) assertEquals(CameraWifiWakeError.UNSUPPORTED, cameraWifiWakeError(message))
        assertEquals(CameraWifiWakeError.BLUETOOTH_OFF, cameraWifiWakeError("Bluetooth unavailable"))
        assertEquals(CameraWifiWakeError.PERMISSION_REQUIRED, cameraWifiWakeError("Bluetooth permission required"))
    }

    private fun assertTerminalCallbacksDoNotChange(attempt: CameraWifiWakeAttempt) {
        val terminal = attempt.state
        assertFalse(terminal.isBusy)
        assertFalse(attempt.ready())
        assertFalse(attempt.written(true))
        assertFalse(attempt.written(false))
        for (error in CameraWifiWakeError.values()) assertFalse(attempt.fail(error))
        attempt.cancel()
        assertEquals(terminal, attempt.state)
    }

    private fun preflight(
        gpsEnabled: Boolean = false,
        hasSavedIdentity: Boolean = true,
        hasSavedAddress: Boolean = true,
        bluetoothEnabled: Boolean = true,
        hasConnectPermission: Boolean = true,
    ) = cameraWifiWakePreflight(
        gpsEnabled,
        hasSavedIdentity,
        hasSavedAddress,
        bluetoothEnabled,
        hasConnectPermission,
    )
}
