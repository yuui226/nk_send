package com.ztransfer.gps

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class GpsViewModel(application: Application) : AndroidViewModel(application) {
    private val preferences = application.getSharedPreferences(PREFERENCES, 0)
    private val _state = NikonGpsRuntime.state
    val state: StateFlow<GpsState> = _state.asStateFlow()

    fun setEnabled(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_ENABLED, enabled).apply()
        _state.value = if (enabled) {
            GpsState(enabled = true, status = GpsStatus.STARTING)
        } else {
            GpsState()
        }
        NikonGpsService.setEnabled(getApplication(), enabled)
    }

    fun retry() {
        if (!state.value.enabled) return
        NikonGpsService.setEnabled(getApplication(), true)
    }

    override fun onCleared() {
        // The foreground service owns the BLE/location lifecycle and must outlive the UI.
        super.onCleared()
    }

    private companion object {
        const val PREFERENCES = "nikon_gps"
        const val KEY_ENABLED = "enabled"
    }
}
