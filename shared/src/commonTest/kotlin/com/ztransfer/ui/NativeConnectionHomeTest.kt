package com.ztransfer.ui

import com.ztransfer.connection.WirelessMode
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.ui.screen.homeSelectedConnection
import kotlin.test.*

class NativeConnectionHomeTest {
    @Test fun lateRecoveryResetCannotEraseANewerRecordOrStartConnectionDuringReset() {
        val p = Platform()
        var result: NativeQueueActionCompletion? = null
        val m = NativeConnectionHomeModel(object : NativeConnectionHomePlatform by p {
            override fun clearRecoveryRecord(completion: NativeQueueActionCompletion) { result = completion }
        })
        m.publishRecoveryRecord(listOf("old.JPG"), 1, false, false)
        m.clearRecoveryRecord(); m.connect()
        assertEquals(0, p.starts)
        m.publishRecoveryRecord(listOf("new.JPG"), 2, false, false)
        result!!.complete(true); result!!.complete(true)
        assertEquals(listOf("new.JPG"), m.state.value.recoveryRecord.names)
        assertFalse(m.state.value.clearingRecovery)
    }
    @Test fun recoveryNoticeNeverReconnectsOrRestartsAnOldQueue() {
        val p = Platform(); val m = NativeConnectionHomeModel(p)
        m.publishRecoveryNotice("background")
        assertEquals("background", m.state.value.recoveryNotice)
        assertEquals(0, p.starts)
        m.connect(); val old = m.currentRequestId()
        assertNull(m.state.value.recoveryNotice)
        m.cancel(); m.publish(old, "idle", null); m.connect()
        assertFalse(m.publish(old, "ready", "stale"))
        m.close(); m.publishRecoveryNotice("disconnected")
        assertNull(m.state.value.recoveryNotice)
    }
    @Test fun recoveryRecordIsBoundedAndDoesNotRestoreOldHandlesOrStartTasks() {
        val p = Platform(); val m = NativeConnectionHomeModel(p)
        m.publishRecoveryRecord(List(1000) { "DSC_$it.JPG" }, -1, false, true)
        assertEquals(500, m.state.value.recoveryRecord.names.size)
        assertEquals(0, m.state.value.recoveryRecord.completed)
        assertEquals(0, p.starts)
        m.clearRecoveryRecord() // Default platform rejects safely; no false acknowledgement.
        assertTrue(m.state.value.recoveryRecord.unavailable)
        assertFalse(m.state.value.clearingRecovery)
        m.close(); m.publishRecoveryRecord(emptyList(), 0, false, false)
        assertTrue(m.state.value.recoveryRecord.unavailable)
    }
    @Test fun stoppingDiscoveryRetainsChoicesAndCannotCancelAnActiveConnection() {
        val p = Platform(); val m = NativeConnectionHomeModel(p); m.setStationMode(true)
        val choice = NativeStationChoice("one", "Camera", "Bonjour", false)
        m.publishChoices(listOf(choice), true, null); val stopped = p.stops
        m.stopSearching(); assertEquals(stopped + 1, p.stops)
        assertFalse(m.state.value.searching); assertEquals(listOf(choice), m.state.value.choices)
        m.choose(choice); m.stopSearching(); assertEquals(stopped + 1, p.stops)
        assertEquals("connecting", m.currentPhase())
    }
    @Test fun celebrationNavigatesOnceOnlyForActualReadyRequest() {
        val p = Platform(); val m = NativeConnectionHomeModel(p)
        m.connect(); val request = m.currentRequestId()
        m.celebrationFinished(request); assertEquals(0, p.files)
        m.publish(request, "ready", null)
        assertTrue(m.shouldCelebrate(request))
        m.celebrationFinished(request); m.celebrationFinished(request)
        assertEquals(1, p.files); assertFalse(m.shouldCelebrate(request))
        assertFalse(m.publish(request, "connecting", "late"))
        assertFalse(m.publish(request, "paired", "late"))
    }
    @Test fun lateCelebrationCannotUndoCancelFailureDisconnectOrClose() {
        for (terminal in listOf("cancel", "failed", "disconnect", "close")) {
            val p = Platform(); val m = NativeConnectionHomeModel(p)
            m.connect(); val request = m.currentRequestId()
            when (terminal) {
                "cancel" -> m.cancel()
                "failed" -> m.publish(request, "failed", null)
                "disconnect" -> { m.publish(request, "ready", null); m.disconnect() }
                else -> { m.publish(request, "ready", null); m.close() }
            }
            m.celebrationFinished(request); assertEquals(0, p.files)
        }
    }
    @Test fun manualNavigationAndReconnectFenceCelebrationCallbacks() {
        val p = Platform(); val m = NativeConnectionHomeModel(p)
        m.connect(); val old = m.currentRequestId(); m.publish(old, "ready", null)
        m.openQueue(); m.celebrationFinished(old); assertEquals(0, p.files); assertEquals(1, p.queues)
        m.disconnect(); m.publish(old, "idle", null); m.connect()
        val current = m.currentRequestId(); m.publish(current, "ready", null)
        m.celebrationFinished(old); assertEquals(0, p.files)
        m.celebrationFinished(current); assertEquals(1, p.files)
    }
    @Test fun originalConnectionTimingBoundariesArePreserved() {
        assertEquals(0f, com.ztransfer.ui.screen.connectionHeroProgress(-1))
        assertEquals(0.5f, com.ztransfer.ui.screen.connectionHeroProgress(310))
        assertEquals(1f, com.ztransfer.ui.screen.connectionHeroProgress(620))
        assertEquals(0f, com.ztransfer.ui.screen.connectionSuccessProgress(499))
        assertEquals(0f, com.ztransfer.ui.screen.connectionSuccessProgress(500))
        assertEquals(1f, com.ztransfer.ui.screen.connectionSuccessProgress(1260))
    }
    @Test fun apDefaultAddressRecoveryCannotChangeStationOrActiveSession() {
        val m = NativeConnectionHomeModel(Platform())
        m.editAddress("bad:15740"); m.connect(); assertEquals("failed", m.currentPhase())
        m.resetApAddress(); assertEquals(com.ztransfer.protocol.PtpConstants.CAMERA_IP, m.currentAddress())
        m.connect(); val address = m.currentAddress(); m.resetApAddress(); assertEquals(address, m.currentAddress())
        m.publish(m.currentRequestId(), "failed", null); m.setStationMode(true); m.editAddress("camera.local")
        m.resetApAddress(); assertEquals("camera.local", m.currentAddress())
    }
    @Test fun restoredModeDoesNotRestoreTrustPermissionOrReadyState() {
        val p = Platform().apply { mode = "sta" }; val m = NativeConnectionHomeModel(p)
        assertTrue(m.state.value.stationMode); assertFalse(m.state.value.allowPairing)
        assertFalse(m.isReady()); assertEquals(0, p.starts)
        m.setStationMode(false); assertEquals("ap", p.mode)
        assertFalse(NativeConnectionHomeModel(p).state.value.stationMode)
    }
    @Test fun damagedModePreferencesStayUntouchedAndSurfaceFailure() {
        val p = Platform().apply { mode = null; saveMode = false }; val m = NativeConnectionHomeModel(p)
        assertTrue(m.state.value.preferencesUnavailable)
        m.setStationMode(true)
        assertTrue(m.state.value.stationMode); assertTrue(m.state.value.preferencesUnavailable)
        assertNull(p.mode); assertEquals(0, p.starts)
    }
    @Test fun switchingModesNeverCarriesPairingOptInAcrossModes() {
        val m = NativeConnectionHomeModel(Platform())
        m.setStationMode(true); m.setAllowPairing(true); m.setStationMode(false); m.setStationMode(true)
        assertFalse(m.state.value.allowPairing)
    }
    @Test fun pairingAcknowledgementIsTerminalButNotAReadyCameraSession() {
        val p = Platform(); val m = NativeConnectionHomeModel(p)
        m.setStationMode(true); m.setAllowPairing(true); m.connect()
        val request = m.currentRequestId()
        assertTrue(m.publish(request, "paired", "confirmed"))
        assertFalse(m.isReady()); assertFalse(m.state.value.allowPairing)
        m.openFiles(); m.openQueue(); assertEquals(0, p.files + p.queues)
        assertFalse(m.publish(request, "ready", "late"))
        m.connect(); assertTrue(m.currentRequestId() > request); assertFalse(p.pairing)
    }
    @Test fun cancelledPairingCannotPublishSuccess() {
        val m = NativeConnectionHomeModel(Platform())
        m.connect(); m.cancel(); assertFalse(m.publish(m.currentRequestId(), "paired", "late"))
    }
    @Test fun homeSupportsTraditionalChineseWithoutChangingSimplifiedOrEnglish() {
        assertEquals("連接相機", NativeConnectionHomeText.label("zh-TW", "连接相机", "Connect camera"))
        assertEquals("連接相機", NativeConnectionHomeText.label("zh-Hant", "连接相机", "Connect camera"))
        assertEquals("连接相机", NativeConnectionHomeText.label("zh-CN", "连接相机", "Connect camera"))
        assertEquals("Connect camera", NativeConnectionHomeText.label("en", "连接相机", "Connect camera"))
    }
    private class Platform : NativeConnectionHomePlatform {
        var mode: String? = "ap"
        var saveMode = true
        override fun readConnectionMode(): String? = mode
        override fun saveConnectionMode(stationMode: Boolean): Boolean {
            if (saveMode) mode = if (stationMode) "sta" else "ap"
            return saveMode
        }
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
