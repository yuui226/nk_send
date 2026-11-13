package com.ztransfer.location

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

internal sealed interface PhotoPlaceLookupResult<out T> {
    data class Found<T>(val value: T) : PhotoPlaceLookupResult<T>
    data object Empty : PhotoPlaceLookupResult<Nothing>
    data object Error : PhotoPlaceLookupResult<Nothing>
    /** A local gate prevented a request; never turn it into a cached backend failure. */
    data class Unavailable(val reason: String) : PhotoPlaceLookupResult<Nothing>
}

/** One request at a time, with no worker/job detached from the caller. */
internal class PhotoPlaceLookupCache<T : Any>(
    private val nowMillis: () -> Long,
    private val maxEntries: Int = 32,
) {
    private data class Entry<T>(val result: PhotoPlaceLookupResult<T>, val time: Long)
    private val entries = LinkedHashMap<String, Entry<T>>(maxEntries, .75f, true)
    private val requests = Mutex()

    init { require(maxEntries > 0) }

    suspend fun resolve(
        key: String,
        timeoutMillis: Long = REQUEST_TIMEOUT_MILLIS,
        trace: ((String) -> Unit)? = null,
        backend: suspend () -> PhotoPlaceLookupResult<T>,
    ): T? = try {
        currentCoroutineContext().ensureActive()
        // A completed hit need not wait behind an unrelated coordinate's request.
        val hit = cached(key)
        if (hit != null) {
            trace?.invoke("placeLookup=cache-${hit.label()}")
            hit.valueOrNull()
        } else {
            if (requests.isLocked) trace?.invoke("placeLookup=waiting")
            requests.withLock {
                currentCoroutineContext().ensureActive()
                val queuedHit = cached(key)
                if (queuedHit != null) {
                    trace?.invoke("placeLookup=cache-${queuedHit.label()}")
                    return@withLock queuedHit.valueOrNull()
                }
                // Time spent waiting for the mutex does not consume the backend's budget.
                trace?.invoke("placeLookup=request")
                val result = withTimeoutOrNull(timeoutMillis.coerceIn(0L, REQUEST_TIMEOUT_MILLIS)) {
                    try {
                        backend()
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (error: Exception) {
                        trace?.invoke("placeLookup=backend-error type=${error.javaClass.simpleName}")
                        PhotoPlaceLookupResult.Error
                    }
                }
                currentCoroutineContext().ensureActive()
                if (result == null) {
                    trace?.invoke("placeLookup=timeout")
                    return@withLock null
                }
                trace?.invoke("placeLookup=${result.label()}")
                if (result !is PhotoPlaceLookupResult.Unavailable) {
                    synchronized(entries) {
                        entries[key] = Entry(result, nowMillis())
                        while (entries.size > maxEntries) entries.remove(entries.keys.first())
                    }
                }
                result.valueOrNull()
            }
        }
    } catch (cancelled: CancellationException) {
        // Preview replacement and caller timeouts must not poison a later export's lookup.
        trace?.invoke("placeLookup=cancelled")
        throw cancelled
    }

    private fun cached(key: String): PhotoPlaceLookupResult<T>? = synchronized(entries) {
        val entry = entries[key] ?: return@synchronized null
        val lifetime = when (entry.result) {
            is PhotoPlaceLookupResult.Found -> 86_400_000L
            PhotoPlaceLookupResult.Empty -> 15_000L
            PhotoPlaceLookupResult.Error -> 5_000L
            is PhotoPlaceLookupResult.Unavailable -> 0L
        }
        if (nowMillis() - entry.time in 0 until lifetime) entry.result
        else { entries.remove(key); null }
    }

    companion object {
        const val REQUEST_TIMEOUT_MILLIS = 3_000L
    }
}

private fun <T> PhotoPlaceLookupResult<T>.valueOrNull(): T? = when (this) {
    is PhotoPlaceLookupResult.Found -> value
    else -> null
}

private fun PhotoPlaceLookupResult<*>.label(): String = when (this) {
    is PhotoPlaceLookupResult.Found -> "success"
    PhotoPlaceLookupResult.Empty -> "empty"
    PhotoPlaceLookupResult.Error -> "error"
    is PhotoPlaceLookupResult.Unavailable -> reason
}
