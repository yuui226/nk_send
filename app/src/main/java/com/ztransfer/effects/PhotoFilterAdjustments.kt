package com.ztransfer.effects

import com.ztransfer.filter.LUT_ADJUSTMENT_RANGE
import com.ztransfer.filter.LutAdjustments
import com.ztransfer.filter.isCustomPhotoFilterCatalogKey
import com.ztransfer.filter.photoFilterCatalogKey

internal const val PHOTO_FILTER_ADJUSTMENTS_PREFERENCE_KEY = "photo_filter_adjustments_v1"
internal const val PHOTO_FILTER_APPLIED_ADJUSTMENTS_PREFERENCE_KEY = "photo_filter_applied_adjustments_v1"

private val ADJUSTMENT_CATALOG_KEY = Regex("[A-Za-z0-9._-]{1,128}")

private fun validAdjustmentCatalogKey(key: String): Boolean =
    ADJUSTMENT_CATALOG_KEY.matches(key) || isCustomPhotoFilterCatalogKey(key)

/** Shared with intensity memory: recipe revisions of the same NP3 keep the same catalog key. */
internal fun photoFilterAdjustmentsFor(
    filterId: String?,
    remembered: Map<String, LutAdjustments>,
): LutAdjustments = filterId?.let { remembered[photoFilterCatalogKey(it) ?: it] } ?: LutAdjustments()

internal fun normalizePhotoFilterAdjustments(
    values: Map<String, LutAdjustments>,
    validCatalogKeys: Set<String>,
): Map<String, LutAdjustments> = values.filterKeys {
    validAdjustmentCatalogKey(it) && (it in validCatalogKeys || isCustomPhotoFilterCatalogKey(it))
}

/** A compact, deterministic map. Unknown custom files retain their settings until selected again. */
internal fun encodePhotoFilterAdjustments(values: Map<String, LutAdjustments>): String =
    values.entries.filter { validAdjustmentCatalogKey(it.key) }.sortedBy { it.key }
        .joinToString(";") { (key, value) ->
            "$key,${value.contrast},${value.saturation},${value.highlights},${value.shadows}"
        }

internal fun decodePhotoFilterAdjustments(
    encoded: String?,
    validCatalogKeys: Set<String>,
): Map<String, LutAdjustments> {
    if (encoded.isNullOrBlank()) return emptyMap()
    val result = linkedMapOf<String, LutAdjustments>()
    encoded.split(';').forEach { entry ->
        val fields = entry.split(',')
        if (fields.size != 5) return@forEach
        val key = fields[0]
        if (!validAdjustmentCatalogKey(key) || key in result ||
            (key !in validCatalogKeys && !isCustomPhotoFilterCatalogKey(key))) return@forEach
        val values = fields.drop(1).map { (it.toIntOrNull() ?: return@forEach).coerceIn(LUT_ADJUSTMENT_RANGE) }
        result[key] = LutAdjustments(values[0], values[1], values[2], values[3])
    }
    return result
}
