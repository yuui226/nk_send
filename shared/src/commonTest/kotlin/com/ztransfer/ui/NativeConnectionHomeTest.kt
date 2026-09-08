package com.ztransfer.ui

import com.ztransfer.connection.WirelessMode
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.ui.screen.homeSelectedConnection
import kotlin.test.*

class NativeConnectionHomeTest {
    private class Platform : NativeConnectionHomePlatform {
        var accept = true
        var starts = 0; var cancels = 0; var disconnects = 0; var files = 0; var queues = 0; var settings = 0; var scans = 0; var stops = 0
        var address: String? = null; var station = false; var pairing = false; var request = 0L
        var choice: String? = null
        var forgotten: String? = null; var historyResets = 0; var identityRecoveries = 0
        override fun connectCamera(address: String, stationMode: Boolean, allowPairing: Boolean, requestId: Long): Boolean {
            starts++; this.address = address; station = stationMode; pairing = allowPairing; request = requestId; return accept
        }
        override fun connectChoice(id: String, paired: Boolean, allowPairing: Boolean, requestId: Long): Boolean {
            choice = id; pairing = allowPairing; request = requestId; starts++; return accept
        }
        override fun cancelConnection(requestId: Long) { cancels++ }
        override fun disconnectCamera(requestId: Long) { disconnects++ }
        override fun openCameraFiles() { files++ }
        override fun openTransferQueue() { queues++ }
        override fun openNetworkSettings() { settings++ }
        override fun discoverCameras() { scans++ }
        override fun stopDiscovering() { stops++ }
        override fun clearExpectedCamera() {}
        override fun forgetCameraProfile(id: String): Boolean { forgotten = id; return true }
        override fun resetCameraHistory(): Boolean { historyResets++; return true }
        override fun recoverCameraIdentity(): Boolean { identityRecoveries++; return true }
    }
    @Test fun initialApHomeNeverAdvertisesUsbOrReadyBeforeSession() {
        val platform = Platform(); val model = NativeConnectionHomeModel(platform)
        val value = model.state.value
        assertFalse(value.ready); assertEquals(WirelessMode.AP, value.presentation().wirelessMode)
        assertNull(homeSelectedConnection(value.ready, value.presentation().connectionType))
        model.openFiles(); model.openQueue(); assertEquals(0, platform.files + platform.queues)
    }
    @Test fun addressValidationUsesSharedPolicyBeforeStartingOwner() {
        val platform = Platform(); val model = NativeConnectionHomeModel(platform)
        for (bad in listOf("", "https://camera.local", "192.168.1.1:15740", "999.0.0.1")) {
            model.editAddress(bad); model.connect(); assertEquals("failed", model.currentPhase())
        }
        assertEquals(0, platform.starts)
        model.editAddress(" CAMERA.local "); model.connect()
        assertEquals("camera.local", platform.address); assertEquals(1, platform.starts)
    }
    @Test fun repeatedConnectAndModeChangesCannotOverlapActiveConnection() {
        val platform = Platform(); val model = NativeConnectionHomeModel(platform)
        model.connect(); val address = model.currentAddress()
        model.connect(); model.setStationMode(true); model.editAddress("other.local"); model.setAllowPairing(true)
        assertEquals(1, platform.starts); assertFalse(model.state.value.stationMode)
        assertEquals(address, model.currentAddress()); assertFalse(model.state.value.allowPairing)
    }
    @Test fun cancelWaitsForOwnerCloseAndRejectsLateReady() {
        val platform = Platform(); val model = NativeConnectionHomeModel(platform)
        model.connect(); val id = model.currentRequestId(); model.cancel(); model.cancel()
        assertEquals("closing", model.currentPhase()); assertEquals(1, platform.cancels)
        assertFalse(model.publish(id, "ready", "late")); model.connect(); assertEquals(1, platform.starts)
        assertTrue(model.publish(id, "idle", null)); model.connect(); assertEquals(2, platform.starts)
    }
    @Test fun onlyActualReadyUnlocksFilesQueueAndUsesSharedWifiSelection() {
        val platform = Platform(); val model = NativeConnectionHomeModel(platform)
        model.connect(); model.openFiles(); assertEquals(0, platform.files)
        assertTrue(model.publish(model.currentRequestId(), "ready", "camera"))
        val value = model.state.value
        assertEquals(CameraConnectionType.WIFI, homeSelectedConnection(value.ready, value.presentation().connectionType))
        model.openFiles(); model.openQueue(); assertEquals(1, platform.files); assertEquals(1, platform.queues)
        model.disconnect(); model.openFiles(); model.openQueue()
        assertEquals(1, platform.files); assertEquals(1, platform.disconnects)
    }
    @Test fun failureCanRetryButOldGenerationCannotOverwriteNewConnection() {
        val platform = Platform(); val model = NativeConnectionHomeModel(platform)
        model.connect(); val old = model.currentRequestId()
        assertTrue(model.publish(old, "failed", "denied")); model.connect()
        assertFalse(model.publish(old, "ready", "stale")); assertFalse(model.isReady())
        assertTrue(model.publish(model.currentRequestId(), "ready", "correct"))
    }
    @Test fun rejectedOwnerAdmissionReturnsFailedWithoutFakeReady() {
        val platform = Platform().apply { accept = false }; val model = NativeConnectionHomeModel(platform)
        model.connect(); assertEquals("failed", model.currentPhase()); assertFalse(model.isReady())
        assertFalse(model.publish(model.currentRequestId(), "ready", "unsolicited"))
    }
    @Test fun stationDiscoveryRequiresExplicitSelectionAndPairingOptIn() {
        val platform = Platform(); val model = NativeConnectionHomeModel(platform)
        model.discover(); assertEquals(0, platform.scans)
        model.setStationMode(true); model.discover(); assertEquals(1, platform.scans)
        val choice = NativeStationChoice("id", "camera", "Bonjour", false)
        model.publishChoices(listOf(choice), true, null)
        assertEquals(0, platform.starts)
        model.choose(choice.copy(id = "stale")); assertEquals(0, platform.starts)
        model.setAllowPairing(true); model.choose(choice)
        assertEquals("id", platform.choice); assertTrue(platform.pairing)
    }
    @Test fun lateDiscoveryCannotReplaceBusyOrDifferentModeHome() {
        val platform = Platform(); val model = NativeConnectionHomeModel(platform)
        val choice = NativeStationChoice("id", "camera", "", true)
        model.publishChoices(listOf(choice), true, null); assertTrue(model.state.value.choices.isEmpty())
        model.setStationMode(true); model.connect(); model.publishChoices(listOf(choice), true, null)
        assertTrue(model.state.value.choices.isEmpty())
    }
    @Test fun closeStopsDiscoveryAndCancelsExactlyOneLiveOwnerWithoutMoreActions() {
        val platform = Platform(); val model = NativeConnectionHomeModel(platform)
        model.connect(); model.close(); model.close(); model.connect(); model.settings(); model.openFiles()
        assertEquals(1, platform.cancels); assertEquals(1, platform.starts); assertEquals(1, platform.stops)
        assertEquals(0, platform.settings + platform.files)
        assertFalse(model.publish(model.currentRequestId(), "ready", null))
    }
    @Test fun retryAfterChoiceFailureKeepsTheChosenRouteInsteadOfDefaultAddress() {
        val platform = Platform().apply { accept = false }; val model = NativeConnectionHomeModel(platform)
        model.setStationMode(true)
        val choice = NativeStationChoice("camera-b", "B", "service", false)
        model.publishChoices(listOf(choice), false, null); model.choose(choice)
        assertEquals("failed", model.currentPhase()); assertNull(platform.address)
        model.connect(); assertEquals(2, platform.starts); assertEquals("camera-b", platform.choice); assertNull(platform.address)
        model.editAddress("different.local"); model.connect()
        assertEquals("different.local", platform.address)
    }
    @Test fun retryOfExpiredChoiceRequiresNewExplicitSelection() {
        val platform = Platform().apply { accept = false }; val model = NativeConnectionHomeModel(platform)
        model.setStationMode(true)
        val choice = NativeStationChoice("old", "old", "", false)
        model.publishChoices(listOf(choice), false, null); model.choose(choice)
        model.publishChoices(emptyList(), false, null); model.connect()
        assertEquals(1, platform.starts); assertNull(platform.address)
    }
    @Test fun destructiveMetadataActionsRequireKnownProfileAndIdleSession() {
        val platform = Platform(); val model = NativeConnectionHomeModel(platform)
        val live = NativeStationChoice("live", "live", "", false)
        val profile = NativeStationChoice("profile", "profile", "", true)
        model.setStationMode(true); model.publishChoices(listOf(live, profile), false, null)
        model.forgetConfirmed(live); model.forgetConfirmed(profile.copy(id = "unknown")); assertNull(platform.forgotten)
        model.forgetConfirmed(profile); assertEquals("profile", platform.forgotten)
        model.connect(); model.resetHistoryConfirmed(); model.recoverIdentityConfirmed()
        assertEquals(0, platform.historyResets + platform.identityRecoveries)
        model.publish(model.currentRequestId(), "failed", null)
        model.resetHistoryConfirmed(); model.recoverIdentityConfirmed()
        assertEquals(1, platform.historyResets); assertEquals(1, platform.identityRecoveries)
    }
}
