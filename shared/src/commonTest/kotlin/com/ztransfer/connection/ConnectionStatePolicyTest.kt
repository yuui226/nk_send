package com.ztransfer.connection

import com.ztransfer.protocol.CameraConnectionType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ConnectionStatePolicyTest {
    @Test
    fun statusAndModePersistenceNamesRemainStable() {
        assertEquals(
            listOf("IDLE", "PROBING", "NOT_FOUND", "REFUSED", "FAILED", "RECONNECTING"),
            WifiConnectionStatus.entries.map(WifiConnectionStatus::name),
        )
        assertEquals(
            listOf("IDLE", "DISCOVERING", "PAIRING", "CONNECTING", "FAILED"),
            StaConnectionStatus.entries.map(StaConnectionStatus::name),
        )
        assertEquals(
            listOf("AP", "STA"),
            WirelessMode.entries.map(WirelessMode::name),
        )
    }

    @Test
    fun onlyStaOriginWifiSessionUsesStaReconnectPath() {
        assertFalse(shouldReconnectUsingSta(null, WirelessMode.AP))
        assertFalse(shouldReconnectUsingSta(null, WirelessMode.STA))
        assertFalse(shouldReconnectUsingSta(CameraConnectionType.WIFI, WirelessMode.AP))
        assertFalse(shouldReconnectUsingSta(CameraConnectionType.USB, WirelessMode.AP))
        assertFalse(shouldReconnectUsingSta(CameraConnectionType.USB, WirelessMode.STA))
        assertTrue(shouldReconnectUsingSta(CameraConnectionType.WIFI, WirelessMode.STA))
    }

    @Test
    fun staDiscoveryLifetimePreservesPairingAndReconnectRules() {
        assertTrue(
            shouldKeepStaDiscoveryAlive(
                reconnectRequested = false,
                hasReusableProfile = true,
            ),
        )
        assertFalse(
            shouldKeepStaDiscoveryAlive(
                reconnectRequested = false,
                hasReusableProfile = false,
            ),
        )
        assertTrue(
            shouldKeepStaDiscoveryAlive(
                reconnectRequested = true,
                hasReusableProfile = false,
            ),
        )
        assertTrue(
            shouldKeepStaDiscoveryAlive(
                reconnectRequested = true,
                hasReusableProfile = true,
            ),
        )
    }

    @Test
    fun reconnectOverlappingPreviousDiscoveryIsDeferredOnlyWhenBothFlagsAreSet() {
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
        assertFalse(
            shouldScheduleStaDiscoveryRetry(
                reconnectRequested = false,
                discoveryInProgress = false,
            ),
        )
    }

    @Test
    fun staActivationRequiresBothAlbumAccessAndPairingConfirmation() {
        assertFalse(canActivateStaSession(false, false))
        assertFalse(canActivateStaSession(true, false))
        assertFalse(canActivateStaSession(false, true))
        assertTrue(canActivateStaSession(true, true))
    }

    @Test
    fun persistedInitiatorIdentityUsesStrictNamesAndPairingFallback() {
        assertEquals(
            StaInitiatorIdentity.ALBUM_EXPLORER,
            restoredStaInitiatorIdentity("ALBUM_EXPLORER"),
        )
        assertEquals(
            StaInitiatorIdentity.PAIRED_COMPUTER,
            restoredStaInitiatorIdentity("PAIRED_COMPUTER"),
        )
        listOf(null, "unknown", "album_explorer", " ALBUM_EXPLORER ", "").forEach { value ->
            assertEquals(StaInitiatorIdentity.PAIRED_COMPUTER, restoredStaInitiatorIdentity(value))
        }
    }

    @Test
    fun persistedWirelessModeUsesStrictNamesAndStaFallback() {
        assertEquals(WirelessMode.AP, restoredWirelessMode("AP"))
        assertEquals(WirelessMode.STA, restoredWirelessMode("STA"))
        listOf(null, "unknown", "ap", " AP ", "").forEach { value ->
            assertEquals(WirelessMode.STA, restoredWirelessMode(value))
        }
    }

    @Test
    fun reconnectDelayUsesTheExistingBoundedBackoff() {
        assertEquals(3_000L, staReconnectDelayMs(0))
        assertEquals(8_000L, staReconnectDelayMs(1))
        assertEquals(15_000L, staReconnectDelayMs(2))
        assertEquals(30_000L, staReconnectDelayMs(3))
        assertEquals(30_000L, staReconnectDelayMs(4))
        assertEquals(30_000L, staReconnectDelayMs(100))
    }
}
