package com.ztransfer.ui.screen

import android.content.Context
import com.ztransfer.filter.normalizePhotoFilterIntensity
import com.ztransfer.frame.PhotoFramePreset
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

/** Persisted editor controls only. The selected source photo intentionally is not part of this model. */
internal data class LocalPhotoEffectsSettings(
    val decorationEnabled: Boolean,
    val borderEnabled: Boolean,
    val preset: PhotoFramePreset,
    val watermark: PhotoFrameWatermark,
    val filterId: String?,
    val filterEnabled: Boolean,
    val filterIntensityPercent: Int,
)

internal fun defaultLocalPhotoEffectsSettings(defaultFilterId: String?) =
    LocalPhotoEffectsSettings(
        decorationEnabled = false,
        borderEnabled = true,
        preset = PhotoFramePreset.MIST,
        watermark = PhotoFrameWatermark(),
        filterId = defaultFilterId,
        filterEnabled = false,
        filterIntensityPercent = 100,
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
        filterIntensityPercent = normalizePhotoFilterIntensity(settings.filterIntensityPercent),
    )
}

/** A separate preference file keeps phone-photo drafts independent from camera-transfer effects. */
internal class LocalPhotoEffectsPreferences(context: Context) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    fun restore(availableFilterIds: List<String>): LocalPhotoEffectsSettings {
        val fallback = defaultLocalPhotoEffectsSettings(availableFilterIds.firstOrNull())
        val availableFilterIdSet = availableFilterIds.toSet()
        if (!preferences.contains(KEY_VERSION)) {
            return normalize(fallback, availableFilterIdSet)
        }
        val values = preferences.all
        val storedFilterId = values.string(KEY_FILTER_ID)
        val restored = LocalPhotoEffectsSettings(
            decorationEnabled = values.boolean(KEY_DECORATION_ENABLED, fallback.decorationEnabled),
            borderEnabled = values.boolean(KEY_BORDER_ENABLED, fallback.borderEnabled),
            preset = values.enum(KEY_PRESET, fallback.preset),
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
        )
        return normalize(restored, availableFilterIdSet)
    }

    fun save(settings: LocalPhotoEffectsSettings) {
        preferences.edit().apply {
            putInt(KEY_VERSION, SETTINGS_VERSION)
            putBoolean(KEY_DECORATION_ENABLED, settings.decorationEnabled)
            putBoolean(KEY_BORDER_ENABLED, settings.borderEnabled)
            putString(KEY_PRESET, settings.preset.name)
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
            putInt(KEY_FILTER_INTENSITY, settings.filterIntensityPercent)
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

    private companion object {
        const val PREFERENCES_NAME = "local_photo_effects"
        const val SETTINGS_VERSION = 1
        const val KEY_VERSION = "settings_version"
        const val KEY_DECORATION_ENABLED = "decoration_enabled"
        const val KEY_BORDER_ENABLED = "border_enabled"
        const val KEY_PRESET = "frame_preset"
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
