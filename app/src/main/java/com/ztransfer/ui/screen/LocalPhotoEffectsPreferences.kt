package com.ztransfer.ui.screen

import android.content.Context
import com.ztransfer.effects.FAVORITE_FRAME_EFFECTS_PREFERENCE_KEY
import com.ztransfer.effects.FAVORITE_PHOTO_FILTERS_PREFERENCE_KEY
import com.ztransfer.effects.FavoriteFrameWatermarkEffect
import com.ztransfer.effects.FavoritePhotoFilter
import com.ztransfer.effects.decodeFavoriteFrameEffects
import com.ztransfer.effects.decodeFavoritePhotoFilters
import com.ztransfer.effects.decodePhotoFilterIntensities
import com.ztransfer.effects.encodeFavoriteFrameEffects
import com.ztransfer.effects.encodeFavoritePhotoFilters
import com.ztransfer.effects.encodePhotoFilterIntensities
import com.ztransfer.filter.BuiltInPhotoFilters
import com.ztransfer.filter.normalizePhotoFilterIntensity
import com.ztransfer.filter.DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT
import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.PhotoFrameMetadataSettings
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.PhotoFrameWatermarkColor
import com.ztransfer.frame.PhotoFrameWatermarkContent
import com.ztransfer.frame.PhotoFrameWatermarkEffect
import com.ztransfer.frame.PhotoFrameWatermarkFont
import com.ztransfer.frame.PhotoFrameWatermarkPosition
import com.ztransfer.frame.limitPhotoFrameWatermarkText
import com.ztransfer.frame.normalizePhotoFrameWatermarkOpacityPercent
import com.ztransfer.frame.normalizePhotoFrameWatermarkSizePercent
import com.ztransfer.frame.photoFrameWatermarkImageFile
import com.ztransfer.frame.validPhotoFrameWatermarkImageHash
import com.ztransfer.frame.decodePhotoFrameMetadataSettings
import com.ztransfer.frame.defaultPhotoFrameMetadataSettings
import com.ztransfer.frame.encodePhotoFrameMetadataSettings
import com.ztransfer.frame.normalizePhotoFrameMetadataSettings

/** Persisted editor controls only. The selected source photo intentionally is not part of this model. */
internal data class LocalPhotoEffectsSettings(
    val decorationEnabled: Boolean,
    val borderEnabled: Boolean,
    val preset: PhotoFramePreset,
    val metadataSettings: Map<PhotoFramePreset, PhotoFrameMetadataSettings> = emptyMap(),
    val watermark: PhotoFrameWatermark,
    val filterId: String?,
    val filterEnabled: Boolean,
    val filterIntensityPercent: Int,
    val filterIntensities: Map<String, Int> = emptyMap(),
    val favoritePhotoFilters: List<FavoritePhotoFilter> = emptyList(),
    val favoriteFrameEffects: List<FavoriteFrameWatermarkEffect> = emptyList(),
)

internal fun defaultLocalPhotoEffectsSettings(defaultFilterId: String?) =
    LocalPhotoEffectsSettings(
        decorationEnabled = false,
        borderEnabled = true,
        preset = PhotoFramePreset.MIST,
        metadataSettings = emptyMap(),
        watermark = PhotoFrameWatermark(),
        filterId = defaultFilterId,
        filterEnabled = false,
        filterIntensityPercent = DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT,
        filterIntensities = emptyMap(),
        favoritePhotoFilters = emptyList(),
        favoriteFrameEffects = emptyList(),
    )

internal fun normalizeLocalPhotoEffectsSettings(
    settings: LocalPhotoEffectsSettings,
    availableFilterIds: Set<String>,
    watermarkImageExists: (String) -> Boolean,
): LocalPhotoEffectsSettings {
    val imageHash = validPhotoFrameWatermarkImageHash(settings.watermark.imageHash)
        ?.takeIf(watermarkImageExists)
    val watermarkContent = settings.watermark.content.takeUnless {
        it == PhotoFrameWatermarkContent.IMAGE && imageHash == null
    } ?: PhotoFrameWatermarkContent.TEXT
    val validFilterId = settings.filterId?.takeIf(availableFilterIds::contains)
    val validCatalogKeys = availableFilterIds
        .map { filterId -> BuiltInPhotoFilters.catalogKey(filterId) ?: filterId }
        .toSet()
    val filterIntensities = settings.filterIntensities
        .mapNotNull { (key, intensity) ->
            key.takeIf(validCatalogKeys::contains)
                ?.let { it to normalizePhotoFilterIntensity(intensity) }
        }
        .toMap()
        .toMutableMap()
    val currentCatalogKey = validFilterId?.let { filterId ->
        BuiltInPhotoFilters.catalogKey(filterId) ?: filterId
    }
    val currentIntensity = currentCatalogKey
        ?.let(filterIntensities::get)
        ?: normalizePhotoFilterIntensity(settings.filterIntensityPercent)
    if (currentCatalogKey != null) filterIntensities.putIfAbsent(currentCatalogKey, currentIntensity)
    return settings.copy(
        watermark = settings.watermark.copy(
            content = watermarkContent,
            text = limitPhotoFrameWatermarkText(settings.watermark.text),
            imageHash = imageHash,
            sizePercent = normalizePhotoFrameWatermarkSizePercent(settings.watermark.sizePercent),
            opacityPercent = normalizePhotoFrameWatermarkOpacityPercent(
                settings.watermark.opacityPercent,
            ),
        ),
        filterId = validFilterId,
        filterEnabled = settings.filterEnabled && validFilterId != null,
        filterIntensityPercent = currentIntensity,
        filterIntensities = filterIntensities,
        favoritePhotoFilters = settings.favoritePhotoFilters
            .filter { it.catalogKey in validCatalogKeys }
            .distinctBy { it.catalogKey },
        favoriteFrameEffects = settings.favoriteFrameEffects
            .distinctBy { it.framePreset },
        metadataSettings = settings.metadataSettings
            .mapNotNull { (preset, value) ->
                normalizePhotoFrameMetadataSettings(value)
                    .takeUnless { it == defaultPhotoFrameMetadataSettings(preset) }
                    ?.let { preset to it }
            }
            .toMap(),
    )
}

/** A separate preference file keeps phone-photo drafts independent from camera-transfer effects. */
internal class LocalPhotoEffectsPreferences(context: Context) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    fun restore(availableFilterIds: List<String>): LocalPhotoEffectsSettings {
        val fallback = defaultLocalPhotoEffectsSettings(availableFilterIds.firstOrNull())
        val availableFilterIdSet = availableFilterIds.toSet()
        val validCatalogKeys = availableFilterIds
            .map { filterId -> BuiltInPhotoFilters.catalogKey(filterId) ?: filterId }
            .toSet()
        if (!preferences.contains(KEY_VERSION)) {
            return normalize(
                fallback.copy(
                    favoritePhotoFilters = decodeFavoritePhotoFilters(
                        legacyFavoriteValue(
                            storedVersion = 0,
                            key = FAVORITE_PHOTO_FILTERS_PREFERENCE_KEY,
                        ),
                        validCatalogKeys,
                    ),
                    favoriteFrameEffects = decodeFavoriteFrameEffects(
                        legacyFavoriteValue(
                            storedVersion = 0,
                            key = FAVORITE_FRAME_EFFECTS_PREFERENCE_KEY,
                        ),
                    ),
                ),
                availableFilterIdSet,
            )
        }
        val values = preferences.all
        val storedVersion = values.int(KEY_VERSION, 0)
        val storedFilterId = values.string(KEY_FILTER_ID)
        val restored = LocalPhotoEffectsSettings(
            decorationEnabled = values.boolean(KEY_DECORATION_ENABLED, fallback.decorationEnabled),
            borderEnabled = values.boolean(KEY_BORDER_ENABLED, fallback.borderEnabled),
            preset = values.enum(KEY_PRESET, fallback.preset),
            metadataSettings = decodePhotoFrameMetadataSettings(
                values.string(KEY_METADATA_SETTINGS),
            ),
            watermark = PhotoFrameWatermark(
                enabled = values.boolean(KEY_WATERMARK_ENABLED, fallback.watermark.enabled),
                content = values.enum(KEY_WATERMARK_CONTENT, fallback.watermark.content),
                text = values.string(KEY_WATERMARK_TEXT) ?: fallback.watermark.text,
                imageHash = values.string(KEY_WATERMARK_IMAGE_HASH),
                font = values.enum(KEY_WATERMARK_FONT, fallback.watermark.font),
                sizePercent = values.int(KEY_WATERMARK_SIZE, fallback.watermark.sizePercent),
                position = values.enum(KEY_WATERMARK_POSITION, fallback.watermark.position),
                color = values.enum(KEY_WATERMARK_COLOR, fallback.watermark.color),
                opacityPercent = values.int(
                    KEY_WATERMARK_OPACITY,
                    fallback.watermark.opacityPercent,
                ),
                effect = values.enum(KEY_WATERMARK_EFFECT, fallback.watermark.effect),
            ),
            filterId = storedFilterId,
            filterEnabled = values.boolean(KEY_FILTER_ENABLED, fallback.filterEnabled),
            filterIntensityPercent = values.int(
                KEY_FILTER_INTENSITY,
                fallback.filterIntensityPercent,
            ),
            filterIntensities = decodePhotoFilterIntensities(
                values.string(KEY_FILTER_INTENSITIES),
                validCatalogKeys,
            ),
            favoritePhotoFilters = decodeFavoritePhotoFilters(
                values.string(KEY_FAVORITE_PHOTO_FILTERS)
                    ?: legacyFavoriteValue(
                        storedVersion = storedVersion,
                        key = FAVORITE_PHOTO_FILTERS_PREFERENCE_KEY,
                    ),
                validCatalogKeys,
            ),
            favoriteFrameEffects = decodeFavoriteFrameEffects(
                values.string(KEY_FAVORITE_FRAME_EFFECTS)
                    ?: legacyFavoriteValue(
                        storedVersion = storedVersion,
                        key = FAVORITE_FRAME_EFFECTS_PREFERENCE_KEY,
                    ),
            ),
        )
        return normalize(restored, availableFilterIdSet)
    }

    fun save(settings: LocalPhotoEffectsSettings) {
        preferences.edit().apply {
            putInt(KEY_VERSION, SETTINGS_VERSION)
            putBoolean(KEY_DECORATION_ENABLED, settings.decorationEnabled)
            putBoolean(KEY_BORDER_ENABLED, settings.borderEnabled)
            putString(KEY_PRESET, settings.preset.name)
            putString(
                KEY_METADATA_SETTINGS,
                encodePhotoFrameMetadataSettings(settings.metadataSettings),
            )
            putBoolean(KEY_WATERMARK_ENABLED, settings.watermark.enabled)
            putString(KEY_WATERMARK_CONTENT, settings.watermark.content.name)
            putString(KEY_WATERMARK_TEXT, settings.watermark.text)
            if (settings.watermark.imageHash == null) remove(KEY_WATERMARK_IMAGE_HASH)
            else putString(KEY_WATERMARK_IMAGE_HASH, settings.watermark.imageHash)
            putString(KEY_WATERMARK_FONT, settings.watermark.font.name)
            putInt(KEY_WATERMARK_SIZE, settings.watermark.sizePercent)
            putString(KEY_WATERMARK_POSITION, settings.watermark.position.name)
            putString(KEY_WATERMARK_COLOR, settings.watermark.color.name)
            putInt(KEY_WATERMARK_OPACITY, settings.watermark.opacityPercent)
            putString(KEY_WATERMARK_EFFECT, settings.watermark.effect.name)
            if (settings.filterId == null) remove(KEY_FILTER_ID)
            else putString(KEY_FILTER_ID, settings.filterId)
            putBoolean(KEY_FILTER_ENABLED, settings.filterEnabled)
            remove(KEY_FILTER_INTENSITY)
            putString(
                KEY_FILTER_INTENSITIES,
                encodePhotoFilterIntensities(settings.filterIntensities),
            )
            putString(
                KEY_FAVORITE_PHOTO_FILTERS,
                encodeFavoritePhotoFilters(settings.favoritePhotoFilters),
            )
            putString(
                KEY_FAVORITE_FRAME_EFFECTS,
                encodeFavoriteFrameEffects(settings.favoriteFrameEffects),
            )
        }.apply()
    }

    private fun normalize(
        settings: LocalPhotoEffectsSettings,
        availableFilterIds: Set<String>,
    ): LocalPhotoEffectsSettings = normalizeLocalPhotoEffectsSettings(
        settings = settings,
        availableFilterIds = availableFilterIds,
        watermarkImageExists = { hash -> photoFrameWatermarkImageFile(appContext, hash).isFile },
    )

    /**
     * Before v3 both editors used the transfer preference file. Seed the phone editor once so an
     * upgrade does not discard visible stars, then save() writes an independent local copy.
     */
    private fun legacyFavoriteValue(storedVersion: Int, key: String): String? {
        if (storedVersion >= SETTINGS_VERSION) return null
        return appContext.getSharedPreferences(LEGACY_SHARED_PREFERENCES_NAME, Context.MODE_PRIVATE)
            .getString(key, null)
    }

    private companion object {
        const val PREFERENCES_NAME = "local_photo_effects"
        const val LEGACY_SHARED_PREFERENCES_NAME = "ztransfer"
        const val SETTINGS_VERSION = 3
        const val KEY_VERSION = "settings_version"
        const val KEY_DECORATION_ENABLED = "decoration_enabled"
        const val KEY_BORDER_ENABLED = "border_enabled"
        const val KEY_PRESET = "frame_preset"
        const val KEY_METADATA_SETTINGS = "frame_metadata_settings_v1"
        const val KEY_WATERMARK_ENABLED = "watermark_enabled"
        const val KEY_WATERMARK_CONTENT = "watermark_content"
        const val KEY_WATERMARK_TEXT = "watermark_text"
        const val KEY_WATERMARK_IMAGE_HASH = "watermark_image_hash"
        const val KEY_WATERMARK_FONT = "watermark_font"
        const val KEY_WATERMARK_SIZE = "watermark_size"
        const val KEY_WATERMARK_POSITION = "watermark_position"
        const val KEY_WATERMARK_COLOR = "watermark_color"
        const val KEY_WATERMARK_OPACITY = "watermark_opacity"
        const val KEY_WATERMARK_EFFECT = "watermark_effect"
        const val KEY_FILTER_ID = "filter_id"
        const val KEY_FILTER_ENABLED = "filter_enabled"
        const val KEY_FILTER_INTENSITY = "filter_intensity"
        const val KEY_FILTER_INTENSITIES = "filter_intensities_v1"
        const val KEY_FAVORITE_PHOTO_FILTERS = "favorite_photo_filters_v1"
        const val KEY_FAVORITE_FRAME_EFFECTS = "favorite_frame_effects_v1"
    }
}

private fun Map<String, *>.boolean(key: String, fallback: Boolean): Boolean =
    this[key] as? Boolean ?: fallback

private fun Map<String, *>.int(key: String, fallback: Int): Int = when (val value = this[key]) {
    is Number -> value.toInt()
    is String -> value.toIntOrNull() ?: fallback
    else -> fallback
}

private fun Map<String, *>.string(key: String): String? = this[key] as? String

private inline fun <reified T : Enum<T>> Map<String, *>.enum(key: String, fallback: T): T =
    string(key)?.let { stored -> enumValues<T>().firstOrNull { it.name == stored } } ?: fallback
