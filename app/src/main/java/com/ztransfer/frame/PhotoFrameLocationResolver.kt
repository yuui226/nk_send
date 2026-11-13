package com.ztransfer.frame

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.SystemClock
import com.ztransfer.location.AndroidPlaceLookup
import com.ztransfer.location.PhotoPlaceLookupCache
import com.ztransfer.location.PhotoPlaceLookupResult
import java.util.Locale
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged

/** Apply the same connectivity policy to the deduplication snapshot and the rendered photo. */
internal fun PhotoFrameMetadata.withAllowedFramePlace(allowed: Boolean): PhotoFrameMetadata =
    if (allowed) this else copy(city = null, region = null, address = null)

/** Treat the all-zero EXIF placeholder as missing, but allow the equator/prime meridian. */
internal fun validFrameCoordinates(latitude: Double?, longitude: Double?): Boolean =
    latitude != null && longitude != null && latitude.isFinite() && longitude.isFinite() &&
        latitude in -90.0..90.0 && longitude in -180.0..180.0 &&
        (latitude != 0.0 || longitude != 0.0)

internal suspend fun resolveFramePlace(
    metadata: PhotoFrameMetadata,
    settings: PhotoFrameMetadataSettings,
    allowed: () -> Boolean,
    trace: ((String) -> Unit)? = null,
    lookup: suspend (Double, Double) -> FramePlace?,
): PhotoFrameMetadata {
    val empty = metadata.copy(city = null, region = null, address = null)
    if (!settings.showCity && !settings.showRegion) {
        trace?.invoke("placeLookup=fields-disabled")
        return empty
    }
    if (!allowed()) {
        trace?.invoke("placeLookup=network-blocked")
        return empty
    }
    val lat = metadata.latitude
    val lon = metadata.longitude
    if (!validFrameCoordinates(lat, lon)) {
        trace?.invoke("placeLookup=no-valid-gps")
        return empty
    }
    val place = lookup(checkNotNull(lat), checkNotNull(lon)) ?: return empty
    // A connection can switch to AP or lose validation while the geocoder is completing.
    if (!allowed()) {
        trace?.invoke("placeLookup=network-changed")
        return empty
    }
    return empty.copy(city = place.city, region = place.region)
}

/** Shared by preview and export; raw EXIF parsing deliberately never enters this service. */
internal object PhotoFrameLocationResolver {
    val apBlocked = MutableStateFlow(true)
    private val cache = PhotoPlaceLookupCache<FramePlace>(SystemClock::elapsedRealtime)

    fun allowed(context: Context): Boolean {
        if (apBlocked.value) return false // Check before even inspecting internet availability.
        return runCatching {
            val cm = context.getSystemService(ConnectivityManager::class.java) ?: return false
            val network = cm.boundNetworkForProcess ?: cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(network) ?: return false
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        }.getOrDefault(false)
    }

    /** Invalidates completed preview caches after a real connectivity/mode transition. */
    fun availability(context: Context) = callbackFlow {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { trySend(allowed(context)) }
            override fun onLost(network: Network) { trySend(allowed(context)) }
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                trySend(allowed(context))
            }
        }
        val registered = runCatching { cm?.registerDefaultNetworkCallback(callback) }.isSuccess
        trySend(allowed(context))
        awaitClose { if (registered) runCatching { cm?.unregisterNetworkCallback(callback) } }
    }.combine(apBlocked) { _, _ -> allowed(context) }.distinctUntilChanged()

    suspend fun resolve(
        context: Context,
        metadata: PhotoFrameMetadata,
        settings: PhotoFrameMetadataSettings,
        trace: ((String) -> Unit)? = null,
        timeoutMillis: Long = PhotoPlaceLookupCache.REQUEST_TIMEOUT_MILLIS,
    ): PhotoFrameMetadata = resolveFramePlace(metadata, settings, { allowed(context) }, trace) { lat, lon ->
        val locale = context.resources.configuration.locales[0] ?: Locale.getDefault()
        val key = locale.toLanguageTag() + String.format(Locale.US, ":%.4f,%.4f", lat, lon)
        cache.resolve(key, timeoutMillis, trace) lookup@ {
            if (!allowed(context)) return@lookup PhotoPlaceLookupResult.Unavailable("network-blocked")
            when (val response = AndroidPlaceLookup.query(context, locale, lat, lon) { allowed(context) }) {
                is PhotoPlaceLookupResult.Found -> {
                    val address = response.value
                    trace?.invoke("placeLookup=address-fields locality=${!address.locality.isNullOrBlank()} " +
                        "subLocality=${!address.subLocality.isNullOrBlank()} subAdmin=${!address.subAdminArea.isNullOrBlank()} " +
                        "admin=${!address.adminArea.isNullOrBlank()}")
                    val place = framePlace(address.locality, address.subLocality, address.subAdminArea,
                        address.adminArea, address.countryCode)
                    trace?.invoke("placeLookup=fields city=${place.city != null} region=${place.region != null}")
                    if (place.city != null || place.region != null) PhotoPlaceLookupResult.Found(place)
                    else PhotoPlaceLookupResult.Empty
                }
                PhotoPlaceLookupResult.Empty -> PhotoPlaceLookupResult.Empty
                PhotoPlaceLookupResult.Error -> PhotoPlaceLookupResult.Error
                is PhotoPlaceLookupResult.Unavailable -> response
            }
        }
    }
}
