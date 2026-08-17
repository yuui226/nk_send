package com.ztransfer.location

import android.content.Context

private const val PREFS_NAME = "debug_photo_location"
private const val KEY_ENABLED = "enabled"
private const val LEGACY_KEY_NAME = "name"
private const val KEY_LATITUDE = "latitude"
private const val KEY_LONGITUDE = "longitude"
private const val KEY_DEFAULT_VERSION = "default_version"
private const val CURRENT_DEFAULT_VERSION = 1
private const val DEFAULT_LATITUDE = "41.1076"
private const val DEFAULT_LONGITUDE = "122.9902"

internal data class DebugPhotoLocationInput(
    val enabled: Boolean,
    val latitude: String,
    val longitude: String,
)

internal data class DebugPhotoLocationConfig(
    val latitude: Double,
    val longitude: Double,
)

internal fun parseDebugPhotoLocation(
    input: DebugPhotoLocationInput,
): DebugPhotoLocationConfig? {
    if (!input.enabled) return null
    val latitude = input.latitude.normalizedCoordinate().toDoubleOrNull()
        ?.takeIf(Double::isFinite)
        ?.takeIf { it in -90.0..90.0 }
        ?: return null
    val longitude = input.longitude.normalizedCoordinate().toDoubleOrNull()
        ?.takeIf(Double::isFinite)
        ?.takeIf { it in -180.0..180.0 }
        ?: return null
    return DebugPhotoLocationConfig(
        latitude = latitude,
        longitude = longitude,
    )
}

private fun String.normalizedCoordinate(): String = trim()
    .replace('－', '-')
    .replace('＋', '+')

internal object DebugPhotoLocationStore {
    fun readInput(context: Context): DebugPhotoLocationInput {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (prefs.getInt(KEY_DEFAULT_VERSION, 0) < CURRENT_DEFAULT_VERSION) {
            val defaultInput = DebugPhotoLocationInput(
                enabled = true,
                latitude = DEFAULT_LATITUDE,
                longitude = DEFAULT_LONGITUDE,
            )
            prefs.edit()
                .putBoolean(KEY_ENABLED, defaultInput.enabled)
                .putString(KEY_LATITUDE, defaultInput.latitude)
                .putString(KEY_LONGITUDE, defaultInput.longitude)
                .putInt(KEY_DEFAULT_VERSION, CURRENT_DEFAULT_VERSION)
                .remove(LEGACY_KEY_NAME)
                .apply()
            return defaultInput
        }
        return DebugPhotoLocationInput(
            enabled = prefs.getBoolean(KEY_ENABLED, true),
            latitude = prefs.getString(KEY_LATITUDE, DEFAULT_LATITUDE).orEmpty(),
            longitude = prefs.getString(KEY_LONGITUDE, DEFAULT_LONGITUDE).orEmpty(),
        )
    }

    fun saveInput(context: Context, input: DebugPhotoLocationInput) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_ENABLED, input.enabled)
            .putString(KEY_LATITUDE, input.latitude.take(24))
            .putString(KEY_LONGITUDE, input.longitude.take(24))
            .putInt(KEY_DEFAULT_VERSION, CURRENT_DEFAULT_VERSION)
            .remove(LEGACY_KEY_NAME)
            .apply()
    }

}
