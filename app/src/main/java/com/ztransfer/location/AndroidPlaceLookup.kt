package com.ztransfer.location

import android.content.Context
import android.location.Address
import android.location.Geocoder
import android.os.Build
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

/** Android provider adapter; callers retain ownership of policy, caching and timeout budgets. */
internal object AndroidPlaceLookup {
    private val legacyBusy = AtomicBoolean(false)
    private val legacyWorker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "frame-geocoder").apply { isDaemon = true }
    }

    @Suppress("DEPRECATION")
    suspend fun query(
        context: Context,
        locale: Locale,
        lat: Double,
        lon: Double,
        allowed: () -> Boolean,
    ): PhotoPlaceLookupResult<PlaceAddress> {
        if (!Geocoder.isPresent()) return PhotoPlaceLookupResult.Unavailable("provider-missing")
        return withContext(Dispatchers.IO) {
            suspendCancellableCoroutine { continuation ->
                val completed = AtomicBoolean(false)
                fun complete(result: PhotoPlaceLookupResult<PlaceAddress>) {
                    // Each backend completes exactly once; cancellation discards late results.
                    if (completed.compareAndSet(false, true) && continuation.isActive) continuation.resume(result)
                }
                fun found(address: Address?) {
                    // Never let the Android provider's mutable Address escape the adapter.
                    val result = try {
                        address?.let {
                            PhotoPlaceLookupResult.Found(PlaceAddress(
                                it.locality, it.subLocality, it.subAdminArea, it.adminArea, it.countryCode,
                            ))
                        } ?: PhotoPlaceLookupResult.Empty
                    } catch (_: Exception) { PhotoPlaceLookupResult.Error }
                    complete(result)
                }
                if (!allowed()) {
                    complete(PhotoPlaceLookupResult.Unavailable("network-blocked"))
                } else if (Build.VERSION.SDK_INT >= 33) {
                    try {
                        Geocoder(context, locale).getFromLocation(lat, lon, 1, object : Geocoder.GeocodeListener {
                            override fun onGeocode(addresses: MutableList<Address>) = found(addresses.firstOrNull())
                            override fun onError(errorMessage: String?) = complete(PhotoPlaceLookupResult.Error)
                        })
                    } catch (_: Exception) { complete(PhotoPlaceLookupResult.Error) }
                } else if (legacyBusy.compareAndSet(false, true)) {
                    // One bounded worker on older Android: a stuck system geocoder cannot accumulate
                    // threads or queue lookups behind a timed-out preview/export.
                    legacyWorker.execute {
                        try {
                            if (continuation.isActive && allowed()) {
                                try { found(Geocoder(context, locale).getFromLocation(lat, lon, 1)?.firstOrNull()) }
                                catch (_: Exception) { complete(PhotoPlaceLookupResult.Error) }
                            } else complete(PhotoPlaceLookupResult.Unavailable("network-blocked"))
                        } finally { legacyBusy.set(false) }
                    }
                } else complete(PhotoPlaceLookupResult.Unavailable("backend-busy"))
            }
        }
    }
}
