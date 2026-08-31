package com.ztransfer.gps

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class GpsViewModel(application: Application) : AndroidViewModel(application) {
    private val preferences = application.getSharedPreferences(PREFERENCES, 0)
    private val _state = NikonGpsRuntime.state
    val state: StateFlow<GpsState> = _state.asStateFlow()
    private val _updateFrequency = MutableStateFlow(readUpdateFrequency())
    val updateFrequency: StateFlow<GpsUpdateFrequency> = _updateFrequency.asStateFlow()

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

    fun setUpdateFrequency(frequency: GpsUpdateFrequency) {
        if (_updateFrequency.value == frequency) return
        preferences.edit()
            .putLong(GpsUpdateFrequency.PREFERENCE_KEY, frequency.seconds)
            .apply()
        _updateFrequency.value = frequency
        if (state.value.enabled) {
            NikonGpsService.setUpdateFrequency(getApplication(), frequency)
        }
    }

    fun hasPairedDevice(): Boolean =
        preferences.contains(KEY_DEVICE_ID) && preferences.contains(KEY_NONCE)

    fun clearPairing() {
        preferences.edit()
            .remove(KEY_DEVICE_ID)
            .remove(KEY_NONCE)
            .remove(KEY_BLE_ADDRESS)
            .apply()
        if (state.value.enabled) setEnabled(false)
    }

    override fun onCleared() {
        // The foreground service owns the BLE/location lifecycle and must outlive the UI.
        super.onCleared()
    }

    private fun readUpdateFrequency(): GpsUpdateFrequency = GpsUpdateFrequency.fromSeconds(
        preferences.getLong(GpsUpdateFrequency.PREFERENCE_KEY, GpsUpdateFrequency.DEFAULT_SECONDS),
    )

    private companion object {
        const val PREFERENCES = "nikon_gps"
        const val KEY_ENABLED = "enabled"
        const val KEY_DEVICE_ID = "device_id"
        const val KEY_NONCE = "nonce"
        const val KEY_BLE_ADDRESS = "ble_address"
    }
}
