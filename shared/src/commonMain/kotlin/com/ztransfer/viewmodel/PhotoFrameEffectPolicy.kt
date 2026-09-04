package com.ztransfer.viewmodel

import com.ztransfer.frame.DEFAULT_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT
import com.ztransfer.frame.DEFAULT_PHOTO_FRAME_WATERMARK_SIZE_PERCENT
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.PhotoFrameWatermarkContent
import com.ztransfer.frame.PhotoFrameWatermarkPosition
import com.ztransfer.frame.isPhotoPlacement
import com.ztransfer.frame.isSupportedPhotoFrameSourceExtension
import com.ztransfer.frame.migratedPhotoFrameWatermarkSizePercent
import com.ztransfer.frame.normalizePhotoFrameWatermarkOpacityPercent
import com.ztransfer.frame.normalizePhotoFrameWatermarkSizePercent
import com.ztransfer.frame.validPhotoFrameWatermarkImageHash

private const val FREE_PHOTO_FRAME_WATERMARK_SIZE_PERCENT =
    DEFAULT_PHOTO_FRAME_WATERMARK_SIZE_PERCENT
private const val FREE_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT = 80

/** Migrates the former named/1..200 size scale while preserving the rendered pixel size. */
fun restoredPhotoFrameWatermarkSizePercent(
    persisted: Any?,
    content: PhotoFrameWatermarkContent,
    usesLegacyScale: Boolean = false,
): Int {
    if (persisted == null) return DEFAULT_PHOTO_FRAME_WATERMARK_SIZE_PERCENT
    val isLegacyNamedValue = persisted is String && persisted.toIntOrNull() == null
    val rawPercent = when (persisted) {
        is Number -> persisted.toInt()
        is String -> persisted.toIntOrNull() ?: when (persisted) {
            "SMALL" -> if (content == PhotoFrameWatermarkContent.IMAGE) 47 else 58
            "MEDIUM" -> if (content == PhotoFrameWatermarkContent.IMAGE) 69 else 75
            "LARGE" -> 100
            else -> 75
        }
        else -> DEFAULT_PHOTO_FRAME_WATERMARK_SIZE_PERCENT
    }
    return if (usesLegacyScale || isLegacyNamedValue) {
        migratedPhotoFrameWatermarkSizePercent(rawPercent)
    } else {
        normalizePhotoFrameWatermarkSizePercent(rawPercent)
    }
}

/** Accepts both the former named opacity levels and the current numeric percentage. */
fun restoredPhotoFrameWatermarkOpacityPercent(persisted: Any?): Int {
    val rawPercent = when (persisted) {
        is Number -> persisted.toInt()
        is String -> persisted.toIntOrNull() ?: when (persisted) {
            "SUBTLE" -> 40
            "STANDARD" -> 72
            "STRONG" -> 100
            else -> DEFAULT_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT
        }
        else -> DEFAULT_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT
    }
    return normalizePhotoFrameWatermarkOpacityPercent(rawPercent)
}

/** Free-edition product watermark, intentionally independent of the user's Pro preference. */
fun freeEditionPhotoFrameWatermark(): PhotoFrameWatermark = PhotoFrameWatermark(
    sizePercent = FREE_PHOTO_FRAME_WATERMARK_SIZE_PERCENT,
    opacityPercent = FREE_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT,
)

/** Resolves the exact watermark used by both preview and export. */
fun effectivePhotoFrameWatermark(
    isPro: Boolean,
    preference: PhotoFrameWatermark,
    borderEnabled: Boolean = true,
): PhotoFrameWatermark {
    val permitted = if (isPro) preference else freeEditionPhotoFrameWatermark()
    val imageHash = validPhotoFrameWatermarkImageHash(permitted.imageHash)
    val content = if (
        permitted.content == PhotoFrameWatermarkContent.IMAGE && imageHash != null
    ) {
        PhotoFrameWatermarkContent.IMAGE
    } else {
        PhotoFrameWatermarkContent.TEXT
    }
    return permitted.copy(
        content = content,
        text = permitted.displayText,
        imageHash = imageHash,
        sizePercent = normalizePhotoFrameWatermarkSizePercent(permitted.sizePercent),
        opacityPercent = normalizePhotoFrameWatermarkOpacityPercent(permitted.opacityPercent),
        position = if ((!borderEnabled || content == PhotoFrameWatermarkContent.IMAGE) &&
            !permitted.position.isPhotoPlacement()
        ) {
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER
        } else {
            permitted.position
        },
    )
}

/** Normalizes stored values without replacing a position that is temporarily unavailable. */
fun normalizedPhotoFrameWatermarkPreference(
    preference: PhotoFrameWatermark,
    borderEnabled: Boolean,
): PhotoFrameWatermark = effectivePhotoFrameWatermark(
    isPro = true,
    preference = preference,
    borderEnabled = borderEnabled,
).copy(position = preference.position)

/** Videos, RAW files, and unknown formats are never sent through a bitmap effects pipeline. */
fun shouldGeneratePhotoFrame(enabled: Boolean, extension: String): Boolean =
    enabled && isSupportedPhotoFrameSourceExtension(extension)
