package com.ztransfer.ui

import com.ztransfer.ui.theme.SkinPreset
import com.ztransfer.ui.theme.ThemeMode
import kotlin.test.*

class NativeAppearanceModelTest {
    private class Platform : NativeAppearancePlatform {
        var stored: NativeAppearancePreferences? = NativeAppearancePreferences.defaults()
        val saves = mutableListOf<NativeAppearancePreferences>()
        val awake = mutableListOf<Boolean>()
        var failSave = false
        var throwRead = false
        var throwSave = false
        override fun readAppearance(): NativeAppearancePreferences? {
            if (throwRead) error("unreadable")
            return stored
        }
        override fun saveAppearance(value: NativeAppearancePreferences): Boolean {
            if (throwSave) error("unwritable")
            saves += value
            if (failSave || stored == null) return false
            stored = value
            return true
        }
        override fun setScreenAwake(enabled: Boolean) { awake += enabled }
    }

    @Test fun defaultsMatchActualAndroidRestore() {
        val platform = Platform()
        val model = NativeAppearanceModel(platform, "zh-Hant")
        val state = model.state.value
        assertEquals(ThemeMode.SYSTEM, state.theme)
        assertEquals(SkinPreset.FROSTED_GLASS, state.skin)
        assertEquals("system", state.language)
        assertEquals("zh-Hant", state.resolvedLanguage)
        assertTrue(state.hapticsEnabled); assertTrue(state.keepScreenOn)
        assertFalse(state.preferencesFailed)
        assertTrue(platform.saves.isEmpty()); assertTrue(platform.awake.isEmpty())
    }

    @Test fun unknownStoredSkinIsTitaniumAndRepairedButMissingSkinIsFrosted() {
        val platform = Platform()
        platform.stored = NativeAppearancePreferences("unknown", "en", "old-skin", false, false)
        val model = NativeAppearanceModel(platform, "zh-Hans")
        assertEquals(ThemeMode.SYSTEM, model.state.value.theme)
        assertEquals(SkinPreset.TITANIUM, model.state.value.skin)
        assertEquals("TITANIUM", platform.saves.single().skinName)
        assertFalse(platform.saves.single().hapticsEnabled)
        assertEquals("FROSTED_GLASS", NativeAppearancePreferences(null, "system", null, true, true).skinName)
    }

    @Test fun allChoicesSaveOneCompleteAppSnapshotWithoutLosingOtherFields() {
        val platform = Platform()
        val model = NativeAppearanceModel(platform, "en")
        model.setThemeName("DARK"); model.setLanguage("zh-Hant"); model.setSkinName("WOOD")
        model.setHapticsEnabled(false); model.setKeepScreenOn(false)
        val restored = NativeAppearanceModel(platform, "en").state.value
        assertEquals(ThemeMode.DARK, restored.theme); assertEquals(SkinPreset.WOOD, restored.skin)
        assertEquals("zh-Hant", restored.language)
        assertFalse(restored.hapticsEnabled); assertFalse(restored.keepScreenOn)
        assertEquals(5, platform.saves.size)
        assertTrue(platform.awake.isEmpty()) // Inactive, despite preference updates.
    }

    @Test fun unchangedValuesNeverWriteOrReapplyIdleTimer() {
        val platform = Platform()
        val model = NativeAppearanceModel(platform, "en")
        model.setThemeName("SYSTEM"); model.setLanguage("system"); model.setSkinName("FROSTED_GLASS")
        model.setHapticsEnabled(true); model.setKeepScreenOn(true)
        model.setApplicationActive(true); model.setApplicationActive(true)
        assertTrue(platform.saves.isEmpty()); assertEquals(listOf(true), platform.awake)
    }

    @Test fun systemLanguageRefreshDoesNotPersistOrOverrideExplicitChoice() {
        val platform = Platform()
        val model = NativeAppearanceModel(platform, "en")
        model.updateSystemLanguage("zh-Hans")
        assertEquals("zh-Hans", model.state.value.resolvedLanguage)
        assertTrue(platform.saves.isEmpty())
        model.setLanguage("zh-Hant"); model.updateSystemLanguage("en")
        assertEquals("zh-Hant", model.state.value.resolvedLanguage)
        model.setLanguage("system")
        assertEquals("en", model.state.value.resolvedLanguage)
        assertEquals(2, platform.saves.size)
    }

    @Test fun idleTimerFollowsForegroundAndPreferenceThenReleasesExactlyOnce() {
        val platform = Platform()
        val model = NativeAppearanceModel(platform, "en")
        model.setApplicationActive(true); model.setApplicationActive(false); model.setApplicationActive(false)
        model.setApplicationActive(true); model.setKeepScreenOn(false); model.setKeepScreenOn(true)
        model.close(); model.close(); model.setApplicationActive(true)
        assertEquals(listOf(true, false, true, false, true, false), platform.awake)
    }

    @Test fun backgroundChangesCannotEnableIdleTimerUntilActive() {
        val platform = Platform()
        val model = NativeAppearanceModel(platform, "en")
        model.setKeepScreenOn(false); model.setApplicationActive(true)
        model.setApplicationActive(false); model.setKeepScreenOn(true)
        assertTrue(platform.awake.isEmpty())
        model.setApplicationActive(true)
        assertEquals(listOf(true), platform.awake)
    }

    @Test fun saveFailureKeepsLiveChoicesAndIsClearedOnlyAfterSuccessfulSave() {
        val platform = Platform()
        val model = NativeAppearanceModel(platform, "en")
        platform.failSave = true
        model.setThemeName("LIGHT")
        assertEquals(ThemeMode.LIGHT, model.state.value.theme); assertTrue(model.state.value.preferencesFailed)
        platform.failSave = false
        model.updateSystemLanguage("zh-Hans")
        assertTrue(model.state.value.preferencesFailed)
        model.setHapticsEnabled(false)
        assertFalse(model.state.value.preferencesFailed)
        assertEquals("LIGHT", platform.saves.last().themeName)
    }

    @Test fun corruptOrThrowingReadsStartWithVisibleDefaultsWithoutOverwritingAtInit() {
        for (throws in listOf(false, true)) {
            val platform = Platform().apply { stored = null; throwRead = throws }
            val model = NativeAppearanceModel(platform, "en")
            assertTrue(model.state.value.preferencesFailed)
            assertTrue(platform.saves.isEmpty())
            platform.throwSave = true
            model.setLanguage("zh-Hans")
            assertEquals("zh-Hans", model.state.value.resolvedLanguage)
            assertTrue(model.state.value.preferencesFailed)
        }
    }

    @Test fun closedAppOwnerRejectsEveryLateMutation() {
        val platform = Platform()
        val model = NativeAppearanceModel(platform, "en")
        model.close()
        val before = model.state.value
        model.setThemeName("DARK"); model.setLanguage("zh-Hans"); model.setSkinName("WOOD")
        model.setHapticsEnabled(false); model.setKeepScreenOn(false); model.updateSystemLanguage("zh-Hant")
        model.setApplicationActive(true)
        assertEquals(before, model.state.value)
        assertTrue(platform.saves.isEmpty()); assertTrue(platform.awake.isEmpty())
    }
}
