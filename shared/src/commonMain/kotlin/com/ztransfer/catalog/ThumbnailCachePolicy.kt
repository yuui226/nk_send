package com.ztransfer.catalog

/** A camera cache is retained through the exact 90-day boundary. */
const val THUMBNAIL_CAMERA_CACHE_MAX_IDLE_MS: Long = 90L * 24 * 60 * 60 * 1_000

/** Stable bytes-to-hash input used by the normal thumbnail cache. */
fun thumbnailCacheKeyMaterial(
    fileName: String,
    size: Long,
    captureDate: String?,
): String = "$fileName\u0000$size\u0000${captureDate.orEmpty()}"

/**
 * STA discovers names and dates progressively, so its cache identity is based only on the
 * unsigned PTP object handle and size.
 */
fun staThumbnailCacheKeyMaterial(handle: Int, size: Long): String =
    "sta\u0000${handle.toLong() and 0xFFFF_FFFFL}\u0000$size"

fun isThumbnailCameraCacheExpired(lastConnectedMs: Long, nowMs: Long): Boolean =
    lastConnectedMs < nowMs - THUMBNAIL_CAMERA_CACHE_MAX_IDLE_MS

fun normalizedCameraIdentifier(value: String?): String? {
    val normalized = value?.trim()?.takeIf(String::isNotEmpty) ?: return null
    when (normalized.lowercase()) {
        "unknown", "none", "null", "n/a" -> return null
    }
    // Some cameras use all zeroes, optionally separated by punctuation, as a placeholder serial.
    return normalized.takeIf { text ->
        text.any { character ->
            character.isLetter() || (character.isDigit() && character != '0')
        }
    }
}

/**
 * Stable cross-transport identity for isolating each camera's thumbnail directory.
 * A reported body serial wins over the USB/PTP-IP transport identity.
 */
fun cameraThumbnailCacheIdentity(
    manufacturer: String?,
    model: String?,
    reportedSerial: String?,
    fallbackPhysicalId: String?,
): String {
    val physicalId = normalizedCameraIdentifier(reportedSerial)
        ?: normalizedCameraIdentifier(fallbackPhysicalId)
        ?: "unknown-device"
    return "${manufacturer.orEmpty().trim()}\u0000${model.orEmpty().trim()}\u0000$physicalId"
}

/** Direct-STA non-JPEG reads are bounded probes, so their misses must remain retryable. */
fun shouldRememberThumbnailMiss(
    staDirectObjectReadValidated: Boolean,
    extension: String,
): Boolean = !staDirectObjectReadValidated || extension == ".jpg"

/** Expensive direct-STA RAW/video probes are deferred until the item becomes visible. */
fun shouldPrefetchThumbnailInBackground(
    staDirectObjectReadValidated: Boolean,
    extension: String,
): Boolean = !staDirectObjectReadValidated || extension == ".jpg"
