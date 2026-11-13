package com.ztransfer.lut

import com.ztransfer.filter.DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT
import com.ztransfer.filter.LutAdjustments
import com.ztransfer.filter.normalizePhotoFilterIntensity

internal val PHOTO_LUT_ADJUSTMENT_FIELDS = listOf("contrast", "saturation", "highlights", "shadows")
internal val PHOTO_LUT_DIGEST_PATTERN = Regex("[a-f0-9]{64}")

internal fun requirePhotoLutRole(role: String) {
    require(role == "transfer" || role == "local") { "Unknown photo LUT editor: $role" }
}

internal fun photoLutMemoryKey(role: String, digest: String): String {
    requirePhotoLutRole(role)
    require(PHOTO_LUT_DIGEST_PATTERN.matches(digest))
    return "lut_adjustments_v2:$role:$digest"
}

internal data class PhotoLutParameterMemory(val intensityPercent: Int, val adjustments: LutAdjustments)

internal fun hasPhotoLutAdjustments(values: Map<String, *>, key: String): Boolean =
    PHOTO_LUT_ADJUSTMENT_FIELDS.any { "$key:$it" in values }

internal fun readPhotoLutAdjustments(values: Map<String, *>, key: String): LutAdjustments = LutAdjustments(
    contrast = (values["$key:contrast"] as? Int ?: 0).coerceIn(-100, 100),
    saturation = (values["$key:saturation"] as? Int ?: 0).coerceIn(-100, 100),
    highlights = (values["$key:highlights"] as? Int ?: 0).coerceIn(-100, 100),
    shadows = (values["$key:shadows"] as? Int ?: 0).coerceIn(-100, 100),
)

/** New role memory wins; migration prefers this editor's applied recipe over old shared detents. */
internal fun resolvePhotoLutParameterMemory(
    values: Map<String, *>,
    role: String,
    digest: String,
    uri: String?,
): PhotoLutParameterMemory {
    val key = photoLutMemoryKey(role, digest)
    val legacy = "lut_adjustments_v1:$digest"
    val isCurrent = values["$role:digest"] == digest
    val sourceUri = uri ?: (values["$role:uri"] as? String).takeIf { isCurrent }
    val intensity = when {
        "$key:intensity" in values -> values["$key:intensity"] as? Int
        isCurrent && "$role:strength" in values -> values["$role:strength"] as? Int
        "$legacy:intensity" in values -> values["$legacy:intensity"] as? Int
        sourceUri != null -> values["strength:$sourceUri"] as? Int
        else -> null
    } ?: DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT
    val adjustmentKey = when {
        hasPhotoLutAdjustments(values, key) -> key
        isCurrent && hasPhotoLutAdjustments(values, "$role:adjustments") -> "$role:adjustments"
        else -> legacy
    }
    return PhotoLutParameterMemory(normalizePhotoFilterIntensity(intensity), readPhotoLutAdjustments(values, adjustmentKey))
}
