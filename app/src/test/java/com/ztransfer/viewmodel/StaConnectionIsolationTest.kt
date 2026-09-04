package com.ztransfer.viewmodel

import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.protocol.StaInitiatorIdentity
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import org.junit.Assert.assertEquals
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
    fun completedPairingKeepsManualDiscoveryAliveForCameraServiceRestart() {
        assertTrue(
            shouldKeepStaDiscoveryAlive(
                reconnectRequested = false,
                hasReusableProfile = true,
            ),
        )
    }

    @Test
    fun firstPairingSearchCanStillStopBeforeAProfileExists() {
        assertFalse(
            shouldKeepStaDiscoveryAlive(
                reconnectRequested = false,
                hasReusableProfile = false,
            ),
        )
    }

    @Test
    fun automaticReconnectDoesNotDependOnProfileMigration() {
        assertTrue(
            shouldKeepStaDiscoveryAlive(
                reconnectRequested = true,
                hasReusableProfile = false,
            ),
        )
    }

    @Test
    fun reconnectOverlappingPreviousDiscoveryIsDeferredInsteadOfDropped() {
        assertTrue(
            shouldScheduleStaDiscoveryRetry(
                reconnectRequested = true,
                discoveryInProgress = true,
            ),
        )
        assertFalse(
            shouldScheduleStaDiscoveryRetry(
                reconnectRequested = false,
                discoveryInProgress = true,
            ),
        )
        assertFalse(
            shouldScheduleStaDiscoveryRetry(
                reconnectRequested = true,
                discoveryInProgress = false,
            ),
        )
    }

    @Test
    fun albumAccessWithoutConfirmedPairingCannotActivateStaSession() {
        assertFalse(
            canActivateStaSession(
                albumAccessValidated = true,
                pairingConfirmed = false,
            ),
        )
    }

    @Test
    fun confirmedPairingStillRequiresValidatedAlbumAccess() {
        assertFalse(
            canActivateStaSession(
                albumAccessValidated = false,
                pairingConfirmed = true,
            ),
        )
        assertTrue(
            canActivateStaSession(
                albumAccessValidated = true,
                pairingConfirmed = true,
            ),
        )
    }

    @Test
    fun savedStaInitiatorIdentitySurvivesAppRelaunch() {
        assertEquals(
            StaInitiatorIdentity.ALBUM_EXPLORER,
            restoredStaInitiatorIdentity("ALBUM_EXPLORER"),
        )
        assertEquals(
            StaInitiatorIdentity.PAIRED_COMPUTER,
            restoredStaInitiatorIdentity("PAIRED_COMPUTER"),
        )
    }

    @Test
    fun legacyProfileDefaultsToThePairingIdentity() {
        assertEquals(
            StaInitiatorIdentity.PAIRED_COMPUTER,
            restoredStaInitiatorIdentity(null),
        )
        assertEquals(
            StaInitiatorIdentity.PAIRED_COMPUTER,
            restoredStaInitiatorIdentity("unknown"),
        )
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

    @Test
    fun savedWirelessModeIsRestoredAndUnknownValuesFallBackToSta() {
        assertEquals(WirelessMode.STA, restoredWirelessMode(null))
        assertEquals(WirelessMode.STA, restoredWirelessMode("unknown"))
        assertEquals(WirelessMode.AP, restoredWirelessMode("AP"))
        assertEquals(WirelessMode.STA, restoredWirelessMode("STA"))
    }

}
