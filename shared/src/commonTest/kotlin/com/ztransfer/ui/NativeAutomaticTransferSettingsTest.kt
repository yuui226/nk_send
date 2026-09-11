package com.ztransfer.ui

import kotlin.test.*

class NativeAutomaticTransferSettingsTest {
    private class Platform : NativeAutomaticTransferSettingsPlatform {
        var value = NativeAutomaticTransferPreferences(false, true)
        var writes = 0
        var resets = 0
        var succeed = true
        override fun readAutomaticTransfer() = value
        override fun changeAutomaticTransfer(enabled: Boolean): Boolean {
            writes++
            if (succeed) value = NativeAutomaticTransferPreferences(enabled, true)
            return succeed
        }
        override fun resetTransferPreferencesAfterConfirmation(): Boolean {
            resets++
            if (succeed) value = NativeAutomaticTransferPreferences(false, true)
            return succeed
        }
    }

    @Test fun unattachedControlCannotPretendToEnableTransfers() {
        val model = NativeAutomaticTransferSettingsModel()
        model.setEnabled(true)
        assertFalse(model.state.value.available)
        assertFalse(model.resetAfterConfirmation())
        val p = Platform()
        assertTrue(model.attach(p)); assertFalse(model.attach(Platform()))
        model.setEnabled(true); model.setEnabled(true)
        assertTrue(model.state.value.enabled); assertEquals(1, p.writes)
    }

    @Test fun failedSaveDoesNotPretendTheSwitchTookEffect() {
        val p = Platform().also { it.succeed = false }
        val model = NativeAutomaticTransferSettingsModel(); model.attach(p)
        model.setEnabled(true)
        assertFalse(model.state.value.enabled); assertTrue(model.state.value.failed)
        model.setEnabled(true); assertEquals(1, p.writes)
    }

    @Test fun absentDestinationCannotEnableButCanTurnOffRememberedAutomaticMode() {
        val p = Platform().also { it.value = NativeAutomaticTransferPreferences(false, true, false) }
        val model = NativeAutomaticTransferSettingsModel(); model.attach(p)
        model.setEnabled(true); assertEquals(0, p.writes)
        p.value = NativeAutomaticTransferPreferences(true, true, false); model.reload()
        model.setEnabled(false); assertEquals(1, p.writes); assertFalse(model.state.value.enabled)
    }

    @Test fun invalidPreferencesRequireExplicitResetAndKeepFailureOnResetError() {
        val p = Platform().also { it.value = NativeAutomaticTransferPreferences(true, false) }
        val model = NativeAutomaticTransferSettingsModel(); model.attach(p)
        assertTrue(model.state.value.failed); assertFalse(model.state.value.enabled)
        model.setEnabled(true); assertEquals(0, p.writes); assertEquals(0, p.resets)
        p.succeed = false
        assertFalse(model.resetAfterConfirmation()); assertTrue(model.state.value.failed)
        p.succeed = true
        assertTrue(model.resetAfterConfirmation()); assertFalse(model.state.value.failed)
        assertFalse(model.state.value.enabled); assertEquals(2, p.resets)
        assertFalse(model.resetAfterConfirmation()); assertEquals(2, p.resets)
    }

    @Test fun closeReleasesOwnerAndRejectsLateSettingsWork() {
        val p = Platform(); val model = NativeAutomaticTransferSettingsModel(); model.attach(p)
        model.close(); model.setEnabled(true); model.reload()
        assertFalse(model.attach(p)); assertFalse(model.resetAfterConfirmation())
        assertEquals(0, p.writes); assertEquals(0, p.resets)
        assertEquals(NativeAutomaticTransferSettingsState(), model.state.value)
    }

    @Test fun recoveryTextResolvesThreeLanguagesWithoutChangingTheScopeOfReset() {
        assertEquals("Reset preferences", nativeTransferRecoveryText("en-US").reset)
        assertEquals("重置偏好", nativeTransferRecoveryText("zh-Hans-CN").reset)
        assertEquals("重設偏好", nativeTransferRecoveryText("zh_HK").reset)
        assertEquals("重置偏好", nativeTransferRecoveryText("zh-Hans-TW").reset)
        assertTrue(nativeTransferRecoveryText("en").message.contains("accepted queue tasks are kept"))
    }
}
