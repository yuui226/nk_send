package com.ztransfer.ui

import com.ztransfer.ui.theme.SkinPreset
import com.ztransfer.ui.theme.ThemeMode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** App-wide UI preferences, deliberately separate from camera generations and browse snapshots. */
class NativeAppearancePreferences(
    themeName: String?, val appLanguage: String, skinName: String?,
    val hapticsEnabled: Boolean, val keepScreenOn: Boolean,
) {
    internal val theme = ThemeMode.entries.firstOrNull { it.name == themeName } ?: ThemeMode.SYSTEM
    // Match Android's restore: absent means first install; unknown existing value means legacy fallback.
    internal val skin = if (skinName == null) SkinPreset.FROSTED_GLASS
        else SkinPreset.entries.firstOrNull { it.name == skinName } ?: SkinPreset.TITANIUM
    internal val needsSkinRepair = skinName != null && skinName != skin.name
    val themeName: String = theme.name
    val skinName: String = skin.name

    companion object {
        fun defaults() = NativeAppearancePreferences(null, "system", null, true, true)
    }
}

interface NativeAppearancePlatform {
    /** Null denotes unreadable/future data, not a first install. Never silently overwrite it. */
    fun readAppearance(): NativeAppearancePreferences?
    fun saveAppearance(value: NativeAppearancePreferences): Boolean
    fun setScreenAwake(enabled: Boolean)
    fun productVersion(): String = ""
    fun copyFeedbackContact(): Boolean = false
    fun openSourceRepository() {}
    fun resetAppearanceAfterConfirmation(): Boolean = false
}

internal data class NativeAppearanceState(
    val theme: ThemeMode, val language: String, val skin: SkinPreset,
    val hapticsEnabled: Boolean, val keepScreenOn: Boolean, val systemLanguage: String,
    val preferencesFailed: Boolean = false,
) {
    val resolvedLanguage: String get() = if (language == "system") systemLanguage else language
    fun preferences() = NativeAppearancePreferences(theme.name, language, skin.name, hapticsEnabled, keepScreenOn)
}

/** Main/UI-thread boundary. One owner for every controller; no connection, I/O worker or page lifetime. */
class NativeAppearanceModel(platform: NativeAppearancePlatform, systemLanguageTag: String) {
    private var platform: NativeAppearancePlatform? = platform
    private val restored = try { platform.readAppearance() } catch (_: Exception) { null }
    private val initial = restored ?: NativeAppearancePreferences.defaults()
    private val mutableState = MutableStateFlow(NativeAppearanceState(initial.theme, initial.appLanguage,
        initial.skin, initial.hapticsEnabled, initial.keepScreenOn, systemLanguageTag, restored == null))
    internal val state = mutableState.asStateFlow()
    private var active = false
    private var screenAwake = false

    init {
        if (restored?.needsSkinRepair == true) persist() // Same legacy skin correction as Android.
    }

    fun currentPreferences(): NativeAppearancePreferences = state.value.preferences()
    internal fun productVersion(): String = platform?.productVersion().orEmpty()
    internal fun copyFeedbackContact(): Boolean = platform?.copyFeedbackContact() == true
    internal fun openSourceRepository() { platform?.openSourceRepository() }
    internal fun resetAfterConfirmation(): Boolean {
        val owner = platform ?: return false
        if (!owner.resetAppearanceAfterConfirmation()) return false
        val restored = owner.readAppearance() ?: return false
        mutableState.value = state.value.copy(theme = restored.theme, language = restored.appLanguage,
            skin = restored.skin, hapticsEnabled = restored.hapticsEnabled,
            keepScreenOn = restored.keepScreenOn, preferencesFailed = false)
        applyScreenAwake()
        return true
    }
    fun setThemeName(name: String) = change { copy(theme = ThemeMode.entries.firstOrNull { it.name == name } ?: ThemeMode.SYSTEM) }
    fun setLanguage(tag: String) = change { copy(language = tag) }
    fun setSkinName(name: String) = change { copy(skin = SkinPreset.entries.firstOrNull { it.name == name } ?: SkinPreset.TITANIUM) }
    fun setHapticsEnabled(enabled: Boolean) = change { copy(hapticsEnabled = enabled) }
    fun setKeepScreenOn(enabled: Boolean) = change { copy(keepScreenOn = enabled) }

    fun updateSystemLanguage(languageTag: String) {
        if (platform != null) mutableState.value = state.value.copy(systemLanguage = languageTag)
    }

    fun setApplicationActive(value: Boolean) {
        if (platform == null) return
        active = value
        applyScreenAwake()
    }

    private fun change(transform: NativeAppearanceState.() -> NativeAppearanceState) {
        if (platform == null) return
        val next = state.value.transform()
        if (next == state.value) return
        mutableState.value = next
        applyScreenAwake()
        persist() // A failed store does not undo current UI choices or restart a camera session.
    }

    private fun persist() {
        val saved = try { platform?.saveAppearance(state.value.preferences()) == true } catch (_: Exception) { false }
        mutableState.value = state.value.copy(preferencesFailed = !saved)
    }

    private fun applyScreenAwake() {
        val enabled = active && state.value.keepScreenOn
        if (enabled == screenAwake) return
        platform?.setScreenAwake(enabled)
        screenAwake = enabled
    }

    /** App owner only. Closing a file/queue sheet must never call this. */
    fun close() {
        active = false
        applyScreenAwake()
        platform = null
    }
}
