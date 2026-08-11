package com.ztransfer.filter

import java.security.MessageDigest
import java.util.Base64

/**
 * Built-in presets converted from selected Nikon NP3 files.
 *
 * Source tone curves, global controls, and NP3 Flexible Color mixer values are preserved. Nikon's
 * unpublished RAW development and color-grading pipeline cannot be reproduced pixel-for-pixel on
 * an already developed sRGB JPEG/FHD preview.
 */
object BuiltInPhotoFilters {
    val all: List<PhotoFilterPreset> by lazy {
        CURATED_NP3_FILTER_DEFINITIONS.map(::convertedNp3Preset)
    }

    private val nameResourceIdsByFilterId: Map<String, Int> by lazy {
        all.zip(CURATED_NP3_FILTER_DEFINITIONS)
            .associate { (filter, definition) -> filter.id to definition.nameResId }
    }

    private val catalogKeysByFilterId: Map<String, String> by lazy {
        all.zip(CURATED_NP3_FILTER_DEFINITIONS)
            .associate { (filter, definition) -> filter.id to definition.sourceSha256 }
    }

    fun nameResId(filterId: String): Int? = nameResourceIdsByFilterId[filterId]

    /** Stable source identity used for user preferences even if the converter version changes. */
    fun catalogKey(filterId: String): String? = catalogKeysByFilterId[filterId]

    private fun convertedNp3Preset(
        definition: CuratedNp3FilterDefinition,
    ): PhotoFilterPreset = PhotoFilterPreset(
        id = convertedPresetId(definition.sourceSha256, NP3_SRGB_CONVERTER_VERSION),
        name = definition.fallbackName,
        parameters = Np3PhotoFilterParameters(
            contrast = definition.contrast,
            highlights = definition.highlights,
            shadows = definition.shadows,
            whites = definition.whites,
            blacks = definition.blacks,
            saturation = definition.saturation,
            colorBands = decodeNp3ColorMixer(definition.colorMixerBase64),
            toneCurve = definition.toneCurveBase64?.let(::decodeToneCurve),
        ),
    )

    private fun decodeToneCurve(encoded: String): IntArray {
        val bytes = Base64.getDecoder().decode(encoded)
        require(bytes.size == TONE_CURVE_BYTE_COUNT)
        return IntArray(PHOTO_FILTER_TONE_CURVE_POINT_COUNT) { index ->
            val offset = index * 2
            ((bytes[offset].toInt() and 0xff) shl 8) or
                (bytes[offset + 1].toInt() and 0xff)
        }
    }

    private fun decodeNp3ColorMixer(encoded: String): List<PhotoFilterColorBand> {
        val bytes = Base64.getDecoder().decode(encoded)
        require(bytes.size == NP3_COLOR_MIXER_BYTE_COUNT)
        return PHOTO_FILTER_COLOR_BAND_CENTERS.mapIndexed { index, center ->
            val offset = index * NP3_COLOR_MIXER_VALUES_PER_BAND
            PhotoFilterColorBand(
                centerDegrees = center,
                hue = (bytes[offset].toInt() and 0xff) - NP3_NEUTRAL_VALUE,
                chroma = (bytes[offset + 1].toInt() and 0xff) - NP3_NEUTRAL_VALUE,
                brightness = (bytes[offset + 2].toInt() and 0xff) - NP3_NEUTRAL_VALUE,
            )
        }
    }

    private fun convertedPresetId(sourceSha256: String, converterVersion: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest("$sourceSha256|$converterVersion".toByteArray(Charsets.UTF_8))
            .joinToString("") { byte ->
                (byte.toInt() and 0xff).toString(16).padStart(2, '0')
            }

    private const val TONE_CURVE_BYTE_COUNT = PHOTO_FILTER_TONE_CURVE_POINT_COUNT * 2
    private const val NP3_COLOR_MIXER_VALUES_PER_BAND = 3
    private const val NP3_COLOR_MIXER_BYTE_COUNT = 8 * NP3_COLOR_MIXER_VALUES_PER_BAND
    private const val NP3_NEUTRAL_VALUE = 128
    private const val NP3_SRGB_CONVERTER_VERSION = "np3-srgb-v1"
}
