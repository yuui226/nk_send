package com.ztransfer.frame

import com.ztransfer.filter.PhotoFilterSelection

private const val PHOTO_FRAME_WATERMARK_RENDER_VERSION = 2
private const val PHOTO_FRAME_LOCATION_RENDER_VERSION = 1
private const val BRAND_FRAME_RENDER_VERSION = 4
private const val EDITORIAL_FRAME_RENDER_VERSION = 2
private const val FILM_GALLERY_RENDER_VERSION = 1
private const val PHOTO_FILTER_RENDER_VERSION = 2

/** Stable, unhashed output identity. Each platform hashes the material with SHA-256. */
data class PhotoFrameOutputIdentity(
    val styleSuffix: String,
    val watermarkFingerprintMaterial: String?,
    val filterFingerprintMaterial: String?,
    val filterIntensityPercent: Int?,
)

fun photoFrameOutputIdentity(
    preset: PhotoFramePreset,
    watermark: PhotoFrameWatermark = PhotoFrameWatermark(),
    borderEnabled: Boolean = true,
    metadataSettings: PhotoFrameMetadataSettings = defaultPhotoFrameMetadataSettings(preset),
    filter: PhotoFilterSelection? = null,
): PhotoFrameOutputIdentity {
    val renderedWatermark = watermark.forBorderMode(borderEnabled)
    val renderedMetadataSettings = if (borderEnabled) {
        metadataSettings
    } else {
        defaultPhotoFrameMetadataSettings(preset)
    }
    val decorationEnabled = borderEnabled || renderedWatermark.enabled
    return PhotoFrameOutputIdentity(
        styleSuffix = when {
            borderEnabled -> "frame_${preset.fileSuffix}"
            renderedWatermark.enabled -> "watermark"
            filter != null -> "filter"
            else -> "watermark"
        },
        watermarkFingerprintMaterial = if (decorationEnabled) {
            photoFrameWatermarkFingerprintMaterial(
                renderedWatermark,
                preset,
                renderedMetadataSettings,
            )
        } else {
            null
        },
        filterFingerprintMaterial = filter?.let(::photoFilterRenderFingerprintMaterial),
        filterIntensityPercent = filter?.normalizedIntensityPercent,
    )
}

/** Changes only when filter pixels change. */
fun photoFilterRenderFingerprintMaterial(filter: PhotoFilterSelection): String =
    "v=$PHOTO_FILTER_RENDER_VERSION\u0000${filter.preset.id}"

/** Contains all rendered configuration but is hashed before it becomes part of a filename. */
fun photoFrameWatermarkFingerprintMaterial(
    watermark: PhotoFrameWatermark,
    preset: PhotoFramePreset,
    metadataSettings: PhotoFrameMetadataSettings = defaultPhotoFrameMetadataSettings(preset),
): String {
    val effectiveMetadataSettings = normalizePhotoFrameMetadataSettings(metadataSettings)
    val metadataToken = photoFrameMetadataSettingsFingerprintToken(preset, effectiveMetadataSettings)
    val baseIdentity = if (watermark.enabled) {
        val renderedPosition = resolvedWatermarkPosition(preset, watermark.position)
        buildList {
            add("v=$PHOTO_FRAME_WATERMARK_RENDER_VERSION")
            if (preset.isBrandFrame()) add("brand-v=$BRAND_FRAME_RENDER_VERSION")
            if (preset.isEditorialFrame()) add("editorial-v=$EDITORIAL_FRAME_RENDER_VERSION")
            if (preset == PhotoFramePreset.FILM_GALLERY) {
                add("film-gallery-v=$FILM_GALLERY_RENDER_VERSION")
            }
            add("on")
            add(watermark.content.name)
            add(watermarkSizeFingerprintToken(watermark))
            add(renderedPosition.name)
            add("opacity=${watermarkOpacityFingerprintToken(watermark.opacityPercent)}")
            when (watermark.content) {
                PhotoFrameWatermarkContent.TEXT -> {
                    add(watermark.displayText)
                    add(watermark.font.name)
                    add(watermark.color.name)
                    add("effect=${watermark.effect.name}")
                }
                PhotoFrameWatermarkContent.IMAGE -> {
                    add(requireNotNull(validPhotoFrameWatermarkImageHash(watermark.imageHash)))
                }
            }
        }.joinToString("\u0000")
    } else if (preset.isBrandFrame()) {
        "brand-v=$BRAND_FRAME_RENDER_VERSION\u0000off"
    } else if (preset.isEditorialFrame()) {
        buildList {
            add("editorial-v=$EDITORIAL_FRAME_RENDER_VERSION")
            if (preset == PhotoFramePreset.FILM_GALLERY) {
                add("film-gallery-v=$FILM_GALLERY_RENDER_VERSION")
            }
            add("off")
        }.joinToString("\u0000")
    } else {
        "off"
    }
    val identity = if (metadataToken == null) {
        baseIdentity
    } else {
        "$baseIdentity\u0000metadata=$metadataToken"
    }
    return if (
        effectiveMetadataSettings.showCoordinates || effectiveMetadataSettings.showAltitude
    ) {
        "$identity\u0000location-v=$PHOTO_FRAME_LOCATION_RENDER_VERSION"
    } else {
        identity
    }
}

private fun watermarkSizeFingerprintToken(watermark: PhotoFrameWatermark): String {
    val sizePercent = legacyPhotoFrameWatermarkSizePercent(watermark.sizePercent)
    return when (watermark.content) {
        PhotoFrameWatermarkContent.TEXT -> when (sizePercent) {
            58 -> "SMALL"
            75 -> "MEDIUM"
            100 -> "LARGE"
            else -> "${sizePercent}P"
        }
        PhotoFrameWatermarkContent.IMAGE -> when (sizePercent) {
            47 -> "SMALL"
            69 -> "MEDIUM"
            100 -> "LARGE"
            else -> "${sizePercent}P"
        }
    }
}

private fun watermarkOpacityFingerprintToken(opacityPercent: Int): String =
    when (val normalized = normalizePhotoFrameWatermarkOpacityPercent(opacityPercent)) {
        40 -> "SUBTLE"
        72 -> "STANDARD"
        100 -> "STRONG"
        else -> "${normalized}P"
    }
