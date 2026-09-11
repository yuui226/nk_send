package com.ztransfer.ui

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The platform owns persistence and the existing queue; this object owns only settings UI state. */
data class NativeAutomaticTransferPreferences(val enabled: Boolean, val valid: Boolean, val canEnable: Boolean = true)

interface NativeAutomaticTransferSettingsPlatform {
    fun readAutomaticTransfer(): NativeAutomaticTransferPreferences
    fun changeAutomaticTransfer(enabled: Boolean): Boolean
    /** Called only after the shared confirmation dialog is accepted. */
    fun resetTransferPreferencesAfterConfirmation(): Boolean
}

internal data class NativeAutomaticTransferSettingsState(
    val available: Boolean = false, val enabled: Boolean = false, val failed: Boolean = false, val canEnable: Boolean = false,
)

class NativeAutomaticTransferSettingsModel {
    private var platform: NativeAutomaticTransferSettingsPlatform? = null
    private var closed = false
    private val mutableState = MutableStateFlow(NativeAutomaticTransferSettingsState())
    internal val state = mutableState.asStateFlow()

    fun attach(platform: NativeAutomaticTransferSettingsPlatform): Boolean {
        if (closed || this.platform != null) return false
        this.platform = platform
        reload()
        return true
    }

    fun reload() {
        if (closed) return
        val value = platform?.readAutomaticTransfer() ?: return
        mutableState.value = NativeAutomaticTransferSettingsState(true, value.enabled && value.valid, !value.valid, value.canEnable)
    }

    internal fun setEnabled(enabled: Boolean) {
        val owner = platform ?: return
        if (closed || mutableState.value.failed || enabled == mutableState.value.enabled) return
        if (enabled && !mutableState.value.canEnable) return
        val saved = owner.changeAutomaticTransfer(enabled)
        reload()
        if (!saved) mutableState.value = mutableState.value.copy(failed = true)
    }

    internal fun resetAfterConfirmation(): Boolean {
        val owner = platform ?: return false
        if (closed || !mutableState.value.failed) return false
        val reset = owner.resetTransferPreferencesAfterConfirmation()
        reload()
        if (!reset) mutableState.value = mutableState.value.copy(failed = true)
        return reset
    }

    fun close() {
        closed = true; platform = null
        mutableState.value = NativeAutomaticTransferSettingsState()
    }
}

internal data class NativeTransferRecoveryText(val title: String, val message: String, val reset: String, val cancel: String)

internal fun nativeTransferRecoveryText(languageTag: String): NativeTransferRecoveryText {
    val parts = languageTag.lowercase().replace('_', '-').split('-')
    return when {
        parts.firstOrNull() != "zh" -> NativeTransferRecoveryText("Reset transfer preferences?",
            "The saved preferences cannot be used. Reset real-time transfer, date folders and deferred start to off? Saved files, directory access and accepted queue tasks are kept.", "Reset preferences", "Cancel")
        "hant" in parts || ("hans" !in parts && parts.any { it in setOf("tw", "hk", "mo") }) ->
            NativeTransferRecoveryText("重設傳輸偏好？", "已儲存的偏好無法使用。是否關閉即時傳輸、按日期整理及延後開始？已儲存檔案、目錄授權和已入隊任務均保留。", "重設偏好", "取消")
        else -> NativeTransferRecoveryText("重置传输偏好？", "已保存的偏好无法使用。是否关闭实时传输、按日期整理和延后开始？已保存文件、目录授权和已入队任务均保留。", "重置偏好", "取消")
    }
}
