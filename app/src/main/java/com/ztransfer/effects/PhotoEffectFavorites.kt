package com.ztransfer.effects

import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.PhotoFrameWatermarkColor
import com.ztransfer.frame.PhotoFrameWatermarkContent
import com.ztransfer.frame.PhotoFrameWatermarkEffect
import com.ztransfer.frame.PhotoFrameWatermarkFont
import com.ztransfer.frame.PhotoFrameWatermarkPosition
import com.ztransfer.frame.normalizePhotoFrameWatermarkOpacityPercent
import com.ztransfer.frame.normalizePhotoFrameWatermarkSizePercent
import com.ztransfer.frame.validPhotoFrameWatermarkImageHash
import com.ztransfer.filter.normalizePhotoFilterIntensity

data class FavoritePhotoFilter(
    val catalogKey: String,
    val intensityPercent: Int,
)

data class FavoriteFrameWatermarkEffect(
    val framePreset: PhotoFramePreset,
    val watermarkEnabled: Boolean,
    val watermarkContent: PhotoFrameWatermarkContent,
    val watermarkFont: PhotoFrameWatermarkFont,
    val watermarkSizePercent: Int,
    val watermarkPosition: PhotoFrameWatermarkPosition,
    val watermarkColor: PhotoFrameWatermarkColor,
    val watermarkOpacityPercent: Int,
    val watermarkEffect: PhotoFrameWatermarkEffect,
) {
    /**
     * Applies only presentation settings. Text and image identity always come from the current
     * entry's [contentSource], so a favorite can never resurrect historical user content. The
     * source may differ from [current] when the editor displays a disabled fallback object.
     */
    fun applyTo(
        current: PhotoFrameWatermark,
        contentSource: PhotoFrameWatermark = current,
    ): PhotoFrameWatermark? {
        if (
            watermarkContent == PhotoFrameWatermarkContent.IMAGE &&
            validPhotoFrameWatermarkImageHash(contentSource.imageHash) == null
        ) {
            return null
        }
        return current.copy(
            enabled = watermarkEnabled,
            content = watermarkContent,
            text = contentSource.text,
            imageHash = contentSource.imageHash,
            font = watermarkFont,
            sizePercent = normalizePhotoFrameWatermarkSizePercent(watermarkSizePercent),
            position = watermarkPosition,
            color = watermarkColor,
            opacityPercent = normalizePhotoFrameWatermarkOpacityPercent(
                watermarkOpacityPercent,
            ),
            effect = watermarkEffect,
        )
    }

    companion object {
        fun capture(
            framePreset: PhotoFramePreset,
            watermark: PhotoFrameWatermark,
        ): FavoriteFrameWatermarkEffect = FavoriteFrameWatermarkEffect(
            framePreset = framePreset,
            watermarkEnabled = watermark.enabled,
            watermarkContent = watermark.content,
            watermarkFont = watermark.font,
            watermarkSizePercent = normalizePhotoFrameWatermarkSizePercent(
                watermark.sizePercent,
            ),
            watermarkPosition = watermark.position,
            watermarkColor = watermark.color,
            watermarkOpacityPercent = normalizePhotoFrameWatermarkOpacityPercent(
                watermark.opacityPercent,
            ),
            watermarkEffect = watermark.effect,
        )
    }
}

internal const val FAVORITE_PHOTO_FILTERS_PREFERENCE_KEY = "favorite_photo_filters_v1"
internal const val FAVORITE_FRAME_EFFECTS_PREFERENCE_KEY = "favorite_frame_effects_v1"

private const val ENTRY_SEPARATOR = ";"
private const val FIELD_SEPARATOR = ","
private val FAVORITE_CATALOG_KEY = Regex("[A-Za-z0-9._-]{1,128}")

internal fun encodeFavoritePhotoFilters(favorites: List<FavoritePhotoFilter>): String =
    favorites.joinToString(ENTRY_SEPARATOR) { favorite ->
        "${favorite.catalogKey}$FIELD_SEPARATOR${normalizePhotoFilterIntensity(favorite.intensityPercent)}"
    }

internal fun decodeFavoritePhotoFilters(
    encoded: String?,
    validCatalogKeys: Set<String>,
): List<FavoritePhotoFilter> {
    if (encoded.isNullOrBlank()) return emptyList()
    val seen = mutableSetOf<String>()
    return encoded.split(ENTRY_SEPARATOR).mapNotNull { entry ->
        val fields = entry.split(FIELD_SEPARATOR)
        val key = fields.getOrNull(0)?.takeIf(FAVORITE_CATALOG_KEY::matches)
            ?: return@mapNotNull null
        if (fields.size != 2 || key !in validCatalogKeys || !seen.add(key)) {
            return@mapNotNull null
        }
        val intensity = fields[1].toIntOrNull() ?: return@mapNotNull null
        FavoritePhotoFilter(key, normalizePhotoFilterIntensity(intensity))
    }
}

internal fun encodeFavoriteFrameEffects(
    favorites: List<FavoriteFrameWatermarkEffect>,
): String = favorites.joinToString(ENTRY_SEPARATOR) { favorite ->
    listOf(
        favorite.framePreset.name,
        favorite.watermarkEnabled,
        favorite.watermarkContent.name,
        favorite.watermarkFont.name,
        normalizePhotoFrameWatermarkSizePercent(favorite.watermarkSizePercent),
        favorite.watermarkPosition.name,
        favorite.watermarkColor.name,
        normalizePhotoFrameWatermarkOpacityPercent(favorite.watermarkOpacityPercent),
        favorite.watermarkEffect.name,
    ).joinToString(FIELD_SEPARATOR)
}

internal fun decodeFavoriteFrameEffects(
    encoded: String?,
): List<FavoriteFrameWatermarkEffect> {
    if (encoded.isNullOrBlank()) return emptyList()
    val seen = mutableSetOf<PhotoFramePreset>()
    return encoded.split(ENTRY_SEPARATOR).mapNotNull { entry ->
        val fields = entry.split(FIELD_SEPARATOR)
        if (fields.size != 9) return@mapNotNull null
        val preset = fields[0].enumOrNull<PhotoFramePreset>() ?: return@mapNotNull null
        if (!seen.add(preset)) return@mapNotNull null
        val enabled = fields[1].toBooleanStrictOrNull() ?: return@mapNotNull null
        val content = fields[2].enumOrNull<PhotoFrameWatermarkContent>()
            ?: return@mapNotNull null
        val font = fields[3].enumOrNull<PhotoFrameWatermarkFont>() ?: return@mapNotNull null
        val size = fields[4].toIntOrNull() ?: return@mapNotNull null
        val position = fields[5].enumOrNull<PhotoFrameWatermarkPosition>()
            ?: return@mapNotNull null
        val color = fields[6].enumOrNull<PhotoFrameWatermarkColor>() ?: return@mapNotNull null
        val opacity = fields[7].toIntOrNull() ?: return@mapNotNull null
        val effect = fields[8].enumOrNull<PhotoFrameWatermarkEffect>()
            ?: return@mapNotNull null
        FavoriteFrameWatermarkEffect(
            framePreset = preset,
            watermarkEnabled = enabled,
            watermarkContent = content,
            watermarkFont = font,
            watermarkSizePercent = normalizePhotoFrameWatermarkSizePercent(size),
            watermarkPosition = position,
            watermarkColor = color,
            watermarkOpacityPercent = normalizePhotoFrameWatermarkOpacityPercent(opacity),
            watermarkEffect = effect,
        )
    }
}

internal fun <T, K> orderWithFavorites(
    items: List<T>,
    favoriteKeys: List<K>,
    keyOf: (T) -> K,
): List<T> {
    val itemsByKey = items.associateBy(keyOf)
    val orderedFavoriteKeys = favoriteKeys.distinct().filter(itemsByKey::containsKey)
    val favoriteKeySet = orderedFavoriteKeys.toSet()
    return orderedFavoriteKeys.mapNotNull(itemsByKey::get) +
        items.filterNot { keyOf(it) in favoriteKeySet }
}

private inline fun <reified T : Enum<T>> String.enumOrNull(): T? =
    enumValues<T>().firstOrNull { it.name == this }
