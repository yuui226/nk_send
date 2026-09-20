package com.ztransfer.frame

import android.content.Context
import android.location.Address
import android.location.Geocoder
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.SystemClock
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

internal data class FramePlace(val city: String?, val region: String?)

/**
 * Address fields are not a universal province/city/county hierarchy. Only promote a known
 * Chinese municipality from adminArea; overseas subLocality may merely name a neighborhood.
 * Prefer omission to guessing from a street address or promoting a county to a city.
 */
internal fun framePlace(
    city: String?,
    district: String?,
    subAdmin: String?,
    admin: String?,
    countryCode: String? = null,
): FramePlace {
    fun String?.clean() = this?.trim()?.takeIf(String::isNotEmpty)
    val locality = city.clean()
    val subLocality = district.clean()
    val subdivision = subAdmin.clean()
    val administration = admin.clean()
    val chineseHierarchy = countryCode.equals("CN", ignoreCase = true) ||
        (countryCode.isNullOrBlank() && listOfNotNull(locality, subLocality, subdivision, administration)
            .any { value -> value.any { it in '\u4E00'..'\u9FFF' } })
    fun same(a: String?, b: String?): Boolean = a != null && b != null && a.equals(b, ignoreCase = true)
    fun isCountyOrDistrict(value: String): Boolean =
        if (chineseHierarchy) {
            !value.endsWithAny("自治区", "自治區", "特别行政区", "特別行政區", "省", "社区", "社區", "开发区", "開發區", "高新区", "高新區", "工业区", "工業區") &&
                value !in setOf("市辖区", "市轄區", "县", "縣", "区", "區") &&
                (value.endsWithAny("区", "區", "县", "縣", "旗") ||
                    value.matches(Regex(".+\\s+(County|District|Autonomous County)", RegexOption.IGNORE_CASE)))
        } else {
            value.matches(Regex(".+\\s+(County|District)", RegexOption.IGNORE_CASE))
        }
    fun isProvince(value: String): Boolean = chineseHierarchy &&
        value.endsWithAny("省", "自治区", "自治區", "特别行政区", "特別行政區")
    val municipality = administration?.takeIf { name ->
        (countryCode.isNullOrBlank() || countryCode.equals("CN", ignoreCase = true)) &&
            name.lowercase(Locale.ROOT) in CHINESE_MUNICIPALITY_NAMES
    }
    val cityName = locality?.takeUnless {
        isCountyOrDistrict(it) || isProvince(it) || (chineseHierarchy && (
            it.endsWithAny("社区", "社區", "街道", "开发区", "開發區", "高新区", "高新區", "工业区", "工業區") ||
                it in setOf("市辖区", "市轄區") || (same(it, administration) && municipality == null)
            ))
    }
        ?: subdivision?.takeIf { chineseHierarchy && it.length > 1 && it.endsWith("市") }
        ?: municipality
    val regionName = if (chineseHierarchy) {
        sequenceOf(subLocality, subdivision, locality).filterNotNull().firstOrNull {
            isCountyOrDistrict(it) && !same(it, cityName) && !same(it, administration)
        }
    } else {
        // Outside the Chinese hierarchy, subAdminArea is the structured administrative field.
        // Do not substitute an arbitrary neighborhood from subLocality when it is absent.
        subdivision?.takeUnless { same(it, cityName) || same(it, administration) }
            ?: locality?.takeIf { isCountyOrDistrict(it) && !same(it, cityName) }
    }
    return FramePlace(cityName, regionName)
}

private fun String.endsWithAny(vararg suffixes: String): Boolean = suffixes.any { endsWith(it) }

private val CHINESE_MUNICIPALITY_NAMES = setOf(
    "北京", "北京市", "beijing", "beijing shi",
    "上海", "上海市", "shanghai", "shanghai shi",
    "天津", "天津市", "tianjin", "tianjin shi",
    "重庆", "重庆市", "重慶", "重慶市", "chongqing", "chongqing shi",
)

/** Treat the all-zero EXIF placeholder as missing, but allow the equator/prime meridian. */
internal fun validFrameCoordinates(latitude: Double?, longitude: Double?): Boolean =
    latitude != null && longitude != null && latitude.isFinite() && longitude.isFinite() &&
        latitude in -90.0..90.0 && longitude in -180.0..180.0 &&
        (latitude != 0.0 || longitude != 0.0)

internal suspend fun resolveFramePlace(
    metadata: PhotoFrameMetadata,
    settings: PhotoFrameMetadataSettings,
    allowed: () -> Boolean,
    lookup: suspend (Double, Double) -> FramePlace?,
): PhotoFrameMetadata {
    val empty = metadata.copy(city = null, region = null, address = null)
    if ((!settings.showCity && !settings.showRegion) || !allowed()) return empty
    val lat = metadata.latitude ?: return empty
    val lon = metadata.longitude ?: return empty
    if (!validFrameCoordinates(lat, lon)) return empty
    val place = lookup(lat, lon) ?: return empty
    // A connection can switch to AP or lose validation while the geocoder is completing.
    if (!allowed()) return empty
    return empty.copy(city = place.city, region = place.region)
}

/** Shared by preview and export; raw EXIF parsing deliberately never enters this service. */
internal object PhotoFrameLocationResolver {
    val apBlocked = MutableStateFlow(true)
    private data class Entry(val place: FramePlace?, val time: Long)
    private val cache = object : LinkedHashMap<String, Entry>(32, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Entry>) = size > 32
    }
    private val lookupMutex = Mutex()
    private val legacyBusy = AtomicBoolean(false)
    private val legacyWorker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "frame-geocoder").apply { isDaemon = true }
    }

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
    ): PhotoFrameMetadata = resolveFramePlace(metadata, settings, { allowed(context) }) { lat, lon ->
        val locale = context.resources.configuration.locales[0] ?: Locale.getDefault()
        val key = locale.toLanguageTag() + String.format(Locale.US, ":%.4f,%.4f", lat, lon)
        // Completed cache hits never wait behind an unrelated in-flight lookup.
        cachedEntry(key)?.let { return@resolveFramePlace it.place }
        // The one-second budget covers both queueing and the backend, not just network time.
        withTimeoutOrNull(1_000L) {
            lookupMutex.withLock {
                cachedEntry(key)?.let { return@withLock it.place }
                if (!allowed(context) || !Geocoder.isPresent()) return@withLock null
                trace?.invoke("placeLookup=request city=${settings.showCity} region=${settings.showRegion}")
                var place: FramePlace? = null
                try {
                    place = withContext(Dispatchers.IO) {
                        query(context, locale, lat, lon)?.let { address ->
                            framePlace(address.locality, address.subLocality, address.subAdminArea, address.adminArea, address.countryCode)
                                .takeIf { it.city != null || it.region != null }
                        }
                    }
                    place
                } finally {
                    // Remember a failed/timed-out attempt before releasing the lock, so a batch
                    // of photos at this coordinate does not retry the same failing request.
                    synchronized(cache) { cache[key] = Entry(place, SystemClock.elapsedRealtime()) }
                    trace?.invoke("placeLookup=result city=${place?.city != null} region=${place?.region != null}")
                }
            }
        }
    }

    private fun cachedEntry(key: String): Entry? = synchronized(cache) {
        cache[key]?.takeIf { entry ->
            val lifetime = if (entry.place == null) 60_000L else 86_400_000L
            SystemClock.elapsedRealtime() - entry.time < lifetime
        }
    }

    @Suppress("DEPRECATION")
    private suspend fun query(context: Context, locale: Locale, lat: Double, lon: Double): Address? =
        suspendCancellableCoroutine { continuation ->
            val completed = AtomicBoolean(false)
            fun complete(address: Address?) {
                // Each backend completes exactly once; cancellation discards late results.
                if (completed.compareAndSet(false, true) && continuation.isActive) continuation.resume(address)
            }
            if (!allowed(context)) {
                complete(null)
            } else if (Build.VERSION.SDK_INT >= 33) {
                try {
                    Geocoder(context, locale).getFromLocation(lat, lon, 1, object : Geocoder.GeocodeListener {
                        override fun onGeocode(addresses: MutableList<Address>) = complete(addresses.firstOrNull())
                        override fun onError(errorMessage: String?) = complete(null)
                    })
                } catch (_: Exception) { complete(null) }
            } else if (legacyBusy.compareAndSet(false, true)) {
                // One bounded worker on older Android: a stuck system geocoder cannot accumulate
                // threads or queue lookups behind a timed-out preview/export.
                legacyWorker.execute {
                    try {
                        val result = if (continuation.isActive && allowed(context)) {
                            runCatching { Geocoder(context, locale).getFromLocation(lat, lon, 1)?.firstOrNull() }
                                .getOrNull()
                        } else null
                        complete(result)
                    } finally { legacyBusy.set(false) }
                }
            } else complete(null)
        }
}
