package com.ztransfer.gps

import android.location.Address
import java.util.Locale

enum class GpsPlaceLookupStatus {
    IDLE,
    LOADING,
    SUCCESS,
    ERROR,
}

/** A one-shot lookup always keeps the exact coordinates that the user tapped. */
data class GpsPlaceLookupState(
    val latitude: Double? = null,
    val longitude: Double? = null,
    val status: GpsPlaceLookupStatus = GpsPlaceLookupStatus.IDLE,
    val placeName: String? = null,
)

/** Roughly 100 m cells avoid resolving the same nearby coordinate repeatedly. */
internal fun gpsPlaceCacheKey(latitude: Double, longitude: Double): String =
    String.format(Locale.US, "%.3f,%.3f", latitude, longitude)

internal class GpsPlaceNameCache(private val maxEntries: Int = 8) {
    init {
        require(maxEntries > 0)
    }

    private val entries = object : LinkedHashMap<String, String>(maxEntries, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?): Boolean =
            size > maxEntries
    }

    fun get(
        latitude: Double,
        longitude: Double,
        locale: Locale = Locale.getDefault(),
    ): String? = entries[cacheKey(latitude, longitude, locale)]

    fun put(
        latitude: Double,
        longitude: Double,
        placeName: String,
        locale: Locale = Locale.getDefault(),
    ) {
        entries[cacheKey(latitude, longitude, locale)] = placeName
    }

    private fun cacheKey(latitude: Double, longitude: Double, locale: Locale): String =
        "${locale.toLanguageTag()}|${gpsPlaceCacheKey(latitude, longitude)}"
}

internal fun Address.bestGpsPlaceName(): String? = listOf(
    getAddressLine(0),
    featureName,
    thoroughfare,
    locality,
    subLocality,
    adminArea,
).firstOrNull { !it.isNullOrBlank() }?.trim()
