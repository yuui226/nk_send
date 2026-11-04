package com.ztransfer.viewmodel

import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.protocol.PairingCompletedException
import com.ztransfer.protocol.PairingNotConfirmedException
import com.ztransfer.protocol.StaInitiatorIdentity
import com.ztransfer.protocol.StaPairingConfirmation
import com.ztransfer.protocol.StaPairingConfirmationMissingException
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
    fun missingPairingConfirmationStopsAutomaticRetryEvenWithAnExistingProfile() {
        val failure = StaPairingConfirmationMissingException()
        listOf(false, true).forEach { reconnect ->
            listOf(false, true).forEach { reusableProfile ->
                assertFalse(
                    shouldKeepStaDiscoveryAlive(
                        reconnectRequested = reconnect,
                        hasReusableProfile = reusableProfile,
                        failure = failure,
                    ),
                )
            }
        }
    }

    @Test
    fun ordinaryTransportFailureStillReconnectsForExistingProfilesOrSessions() {
        assertTrue(
            shouldKeepStaDiscoveryAlive(
                reconnectRequested = false,
                hasReusableProfile = true,
                failure = SocketTimeoutException("camera restarting"),
            ),
        )
        assertTrue(
            shouldKeepStaDiscoveryAlive(
                reconnectRequested = true,
                hasReusableProfile = false,
                failure = ConnectException("temporarily unavailable"),
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
    fun unconfirmedComputerPairingCannotEscapeThroughAlbumIdentity() {
        assertTrue(
            shouldBlockStaAlbumFallback(
                preferredIdentity = StaInitiatorIdentity.PAIRED_COMPUTER,
                pairingFlowStarted = true,
            ),
        )
    }

    @Test
    fun legacyAlbumValidationCanRecoverThroughComputerIdentity() {
        // A legacy album route may fail its DeviceInfo validation before computer pairing starts.
        // The authoritative identity must still get its own full confirmation/reconnect attempt.
        assertFalse(
            shouldBlockStaAlbumFallback(
                preferredIdentity = StaInitiatorIdentity.ALBUM_EXPLORER,
                pairingFlowStarted = true,
            ),
        )
    }

    @Test
    fun existingPairedRoutesKeepCompatibilityFallbackBeforeNewPairing() {
        StaInitiatorIdentity.entries.forEach { identity ->
            assertFalse(
                shouldBlockStaAlbumFallback(
                    preferredIdentity = identity,
                    pairingFlowStarted = false,
                ),
            )
        }
    }

    @Test
    fun liveViewCleanupRecoveryRequiresTheSameConfirmedBodyAndRunsOnlyOnce() {
        val receipt = StaPairingConfirmation("camera-a")
        val verified = receipt.copy(remotePermissionVerified = true)
        assertTrue(canRecoverStaPairingCleanup(StaInitiatorIdentity.PAIRED_COMPUTER, receipt, verified, false))
        assertFalse(canRecoverStaPairingCleanup(StaInitiatorIdentity.PAIRED_COMPUTER, receipt, verified, true))
        assertFalse(canRecoverStaPairingCleanup(StaInitiatorIdentity.PAIRED_COMPUTER, receipt, receipt, false))
        assertFalse(canRecoverStaPairingCleanup(StaInitiatorIdentity.PAIRED_COMPUTER, null, verified, false))
        assertFalse(canRecoverStaPairingCleanup(
            StaInitiatorIdentity.PAIRED_COMPUTER, StaPairingConfirmation("camera-b"), verified, false,
        ))
        assertFalse(canRecoverStaPairingCleanup(StaInitiatorIdentity.ALBUM_EXPLORER, receipt, verified, false))
    }

    @Test
    fun aVerifiedFrameNeverFallsBackToPairingAgainWhenReconnectFails() {
        val frameFailure = PairingNotConfirmedException(remoteRequestAttempted = true)
        val verified = StaPairingConfirmation("camera-a", remotePermissionVerified = true)
        assertFalse(canRetryUnconfirmedStaPairing(verified, recoveryUsed = false, failure = frameFailure))
        assertFalse(canRetryUnconfirmedStaPairing(verified, recoveryUsed = true, failure = frameFailure))
        // Preserve the original single recovery for a receipt whose frame was not verified yet.
        val unconfirmed = StaPairingConfirmation("camera-a")
        assertTrue(canRetryUnconfirmedStaPairing(unconfirmed, recoveryUsed = false, failure = frameFailure))
        assertFalse(canRetryUnconfirmedStaPairing(unconfirmed, recoveryUsed = true, failure = frameFailure))
        assertTrue(canRetryUnconfirmedStaPairing(null, recoveryUsed = false, failure = frameFailure))
        assertFalse(canRetryUnconfirmedStaPairing(null, recoveryUsed = true, failure = frameFailure))
    }

    @Test
    fun inlineAndMonitorRecoveryShareOneBudget() {
        val pending = StaPairingConfirmation("camera-a")
        val frameFailure = PairingNotConfirmedException(remoteRequestAttempted = true)
        val pairingOnly = PairingNotConfirmedException(pairingOnly = true)
        assertTrue(canUseInlineStaPairingRecovery(StaInitiatorIdentity.PAIRED_COMPUTER, pending, false))
        // Either recovery consumes the same flag; the other must not become a second repair.
        assertFalse(canUseInlineStaPairingRecovery(StaInitiatorIdentity.PAIRED_COMPUTER, pending, true))
        assertFalse(canRetryUnconfirmedStaPairing(pending, true, frameFailure))
        assertFalse(canRetryUnconfirmedStaPairing(pending, true, pairingOnly))
        // An exhausted pairing-only state is not a transient read failure either.
        assertFalse(canRetryStaPairingReadFailure(pairingOnly, readinessRetryUsed = false))
    }

    @Test
    fun inlineRepairRequiresAPendingUnverifiedComputerPairing() {
        val pending = StaPairingConfirmation("camera-a")
        assertFalse(canUseInlineStaPairingRecovery(StaInitiatorIdentity.PAIRED_COMPUTER, null, false))
        assertFalse(canUseInlineStaPairingRecovery(StaInitiatorIdentity.ALBUM_EXPLORER, pending, false))
        assertFalse(canUseInlineStaPairingRecovery(
            StaInitiatorIdentity.PAIRED_COMPUTER, pending.copy(remotePermissionVerified = true), false,
        ))
        // Legacy marker invalidation has no receipt yet; retain its original one-time repair.
        assertTrue(canRetryUnconfirmedStaPairing(null, false, PairingNotConfirmedException(pairingOnly = true)))
    }

    @Test
    fun verificationReadFailureRetriesServiceWithoutPairingAgain() {
        val readFailure = PairingNotConfirmedException(IOException("DeviceInfo unavailable"))
        val pending = StaPairingConfirmation("camera-a")
        assertFalse(canRetryUnconfirmedStaPairing(pending, false, readFailure))
        assertFalse(canRetryUnconfirmedStaPairing(null, false, readFailure))
        assertTrue(canRetryStaPairingReadFailure(readFailure, readinessRetryUsed = false))
        assertFalse(canRetryStaPairingReadFailure(readFailure, readinessRetryUsed = true))
        assertFalse(canRetryStaPairingReadFailure(
            PairingNotConfirmedException(remoteRequestAttempted = true), readinessRetryUsed = false,
        ))
    }

    @Test
    fun pairingRestartWaitStartsAtAcknowledgementAndIncludesConnectionCleanup() {
        assertEquals(6_600L, remainingStaPairingRestartDelay(1_000L, 1_000L, 6_600L))
        assertEquals(6_350L, remainingStaPairingRestartDelay(1_000L, 1_250L, 6_600L))
        assertEquals(0L, remainingStaPairingRestartDelay(1_000L, 7_600L, 6_600L))
        assertEquals(0L, remainingStaPairingRestartDelay(1_000L, 20_000L, 6_600L))
        // Synthetic/legacy receipts without a timestamp retain the conservative interval.
        assertEquals(6_600L, remainingStaPairingRestartDelay(0L, 20_000L, 6_600L))
        assertEquals(6_600L, remainingStaPairingRestartDelay(2_000L, 1_000L, 6_600L))
    }

    @Test
    fun failedPairingExchangeCannotUseTheOrdinaryReadinessRetry() {
        val timeout = SocketTimeoutException("Query or Result response missing")
        assertTrue(isTransientStaServiceReadinessFailure(timeout))
        assertTrue(isFailedStaPairingExchange(exchangeStarted = true, failure = timeout))
        assertFalse(isFailedStaPairingExchange(exchangeStarted = false, failure = timeout))
        listOf(false, true).forEach { recovery ->
            assertFalse(isFailedStaPairingExchange(
                exchangeStarted = true,
                failure = PairingCompletedException(StaPairingConfirmation("camera-a"), isRecovery = recovery),
            ))
        }
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
