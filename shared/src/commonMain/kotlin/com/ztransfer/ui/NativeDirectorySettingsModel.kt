package com.ztransfer.ui

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

interface NativeDirectorySettingsPlatform { fun selectDirectory(requestId: Long) }

internal data class NativeDirectorySettingsState(
    val description: String? = null,
    val message: String? = null,
    val selecting: Boolean = false,
)

/** UI request ownership only. The existing queue/platform commits the grant and changes the source. */
class NativeDirectorySettingsModel {
    private var platform: NativeDirectorySettingsPlatform? = null
    private var closed = false
    private var request = 0L
    private val mutableState = MutableStateFlow(NativeDirectorySettingsState())
    internal val state = mutableState.asStateFlow()

    fun attach(platform: NativeDirectorySettingsPlatform, description: String?, message: String?): Boolean {
        if (closed || this.platform != null) return false
        this.platform = platform
        mutableState.value = NativeDirectorySettingsState(description, message)
        return true
    }

    internal fun choose() {
        val owner = platform ?: return
        if (closed || mutableState.value.selecting) return
        request += 1
        mutableState.value = mutableState.value.copy(selecting = true)
        owner.selectDirectory(request)
    }

    /** Null means cancelled/no new error: never clear an existing invalid-target warning on cancel. */
    fun finish(requestId: Long, message: String?): Boolean {
        if (closed || !mutableState.value.selecting || requestId != request) return false
        mutableState.value = mutableState.value.copy(selecting = false, message = message ?: mutableState.value.message)
        return true
    }

    fun close() {
        closed = true
        platform = null
        mutableState.value = NativeDirectorySettingsState()
    }
}
