package com.ztransfer.gps

import android.app.Application
import android.location.Address
import android.location.Geocoder
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import java.util.Locale
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

class GpsViewModel(application: Application) : AndroidViewModel(application) {
    private val preferences = application.getSharedPreferences(PREFERENCES, 0)
    private val _state = NikonGpsRuntime.state
    val state: StateFlow<GpsState> = _state.asStateFlow()
    private val _updateFrequency = MutableStateFlow(readUpdateFrequency())
    val updateFrequency: StateFlow<GpsUpdateFrequency> = _updateFrequency.asStateFlow()
    private val _placeLookupState = MutableStateFlow(GpsPlaceLookupState())
    val placeLookupState: StateFlow<GpsPlaceLookupState> = _placeLookupState.asStateFlow()
    private val placeNameCache = GpsPlaceNameCache()
    private var placeLookupJob: Job? = null
    private var placeLookupRequestId = 0L

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

    fun lookupPlaceName(latitude: Double, longitude: Double) {
        placeLookupRequestId += 1
        val requestId = placeLookupRequestId
        placeLookupJob?.cancel()
        placeLookupJob = null
        if (!latitude.isFinite() || latitude !in -90.0..90.0 ||
            !longitude.isFinite() || longitude !in -180.0..180.0
        ) {
            _placeLookupState.value = GpsPlaceLookupState(
                latitude = latitude,
                longitude = longitude,
                status = GpsPlaceLookupStatus.ERROR,
            )
            return
        }

        val locale = Locale.getDefault()
        placeNameCache.get(latitude, longitude, locale)?.let { cached ->
            _placeLookupState.value = GpsPlaceLookupState(
                latitude = latitude,
                longitude = longitude,
                status = GpsPlaceLookupStatus.SUCCESS,
                placeName = cached,
            )
            return
        }

        _placeLookupState.value = GpsPlaceLookupState(
            latitude = latitude,
            longitude = longitude,
            status = GpsPlaceLookupStatus.LOADING,
        )
        placeLookupJob = viewModelScope.launch {
            val placeName = try {
                resolvePlaceName(latitude, longitude, locale)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                null
            }
            if (requestId != placeLookupRequestId) return@launch
            if (placeName == null) {
                _placeLookupState.value = GpsPlaceLookupState(
                    latitude = latitude,
                    longitude = longitude,
                    status = GpsPlaceLookupStatus.ERROR,
                )
            } else {
                placeNameCache.put(latitude, longitude, placeName, locale)
                _placeLookupState.value = GpsPlaceLookupState(
                    latitude = latitude,
                    longitude = longitude,
                    status = GpsPlaceLookupStatus.SUCCESS,
                    placeName = placeName,
                )
            }
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

    private suspend fun resolvePlaceName(
        latitude: Double,
        longitude: Double,
        locale: Locale,
    ): String? {
        if (!Geocoder.isPresent()) return null
        val geocoder = Geocoder(getApplication(), locale)
        val addresses = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            geocodeAsync(geocoder, latitude, longitude)
        } else {
            withContext(Dispatchers.IO) {
                @Suppress("DEPRECATION")
                geocoder.getFromLocation(latitude, longitude, 1).orEmpty()
            }
        }
        return addresses.firstOrNull()?.bestGpsPlaceName()
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private suspend fun geocodeAsync(
        geocoder: Geocoder,
        latitude: Double,
        longitude: Double,
    ): List<Address> = suspendCancellableCoroutine { continuation ->
        geocoder.getFromLocation(
            latitude,
            longitude,
            1,
            object : Geocoder.GeocodeListener {
                override fun onGeocode(addresses: MutableList<Address>) {
                    if (continuation.isActive) continuation.resume(addresses)
                }

                override fun onError(errorMessage: String?) {
                    if (continuation.isActive) continuation.resume(emptyList())
                }
            },
        )
    }

    private companion object {
        const val PREFERENCES = "nikon_gps"
        const val KEY_ENABLED = "enabled"
        const val KEY_DEVICE_ID = "device_id"
        const val KEY_NONCE = "nonce"
        const val KEY_BLE_ADDRESS = "ble_address"
    }
}
