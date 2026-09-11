package com.ztransfer.frame

fun PhotoFrameWatermark.forBrandPhoto(preset: PhotoFramePreset): PhotoFrameWatermark =
    when (preset) {
        PhotoFramePreset.BRAND_INSET -> if (position.isPhotoPlacement()) {
            this
        } else {
            copy(
                position = when (position) {
                    PhotoFrameWatermarkPosition.LEFT -> PhotoFrameWatermarkPosition.PHOTO_BOTTOM_LEFT
                    PhotoFrameWatermarkPosition.CENTER -> PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER
                    PhotoFrameWatermarkPosition.AUTO,
                    PhotoFrameWatermarkPosition.RIGHT -> PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT
                    else -> position
                }
            )
        }
        PhotoFramePreset.BRAND_GALLERY -> when {
            position.isPhotoPlacement() -> this
            position == PhotoFrameWatermarkPosition.AUTO ->
                copy(position = PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT)
            content == PhotoFrameWatermarkContent.IMAGE ->
                copy(position = PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT)
            else -> copy(enabled = false)
        }
        else -> error("Not a brand frame")
    }

fun PhotoFrameWatermark.forEditorialPhoto(preset: PhotoFramePreset): PhotoFrameWatermark {
    require(preset.isEditorialFrame())
    if (position.isPhotoPlacement()) return this
    val mappedPosition = when (position) {
        PhotoFrameWatermarkPosition.LEFT -> PhotoFrameWatermarkPosition.PHOTO_BOTTOM_LEFT
        PhotoFrameWatermarkPosition.CENTER -> PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER
        PhotoFrameWatermarkPosition.RIGHT -> PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT
        PhotoFrameWatermarkPosition.AUTO -> when (preset) {
            PhotoFramePreset.GALLERY_MAT,
            PhotoFramePreset.FILM_GALLERY -> PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER
            else -> PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT
        }
        else -> position
    }
    val shouldUsePhoto = when (preset) {
        PhotoFramePreset.CLASSIC_SIGNATURE ->
            position == PhotoFrameWatermarkPosition.AUTO ||
                content == PhotoFrameWatermarkContent.IMAGE
        PhotoFramePreset.COLOR_ARCHIVE -> true
        PhotoFramePreset.GALLERY_MAT,
        PhotoFramePreset.FILM_GALLERY -> content == PhotoFrameWatermarkContent.IMAGE
        PhotoFramePreset.FILM_EDGE -> true
        else -> false
    }
    return if (shouldUsePhoto) copy(position = mappedPosition) else copy(enabled = false)
}

fun PhotoFrameWatermark.bandWatermarkFor(preset: PhotoFramePreset): PhotoFrameWatermark? {
    if (!enabled || content != PhotoFrameWatermarkContent.TEXT || position.isPhotoPlacement()) {
        return null
    }
    val supported = when (preset) {
        PhotoFramePreset.CLASSIC_SIGNATURE -> position != PhotoFrameWatermarkPosition.AUTO
        PhotoFramePreset.GALLERY_MAT,
        PhotoFramePreset.FILM_GALLERY -> true
        PhotoFramePreset.FILM_EDGE -> false
        else -> false
    }
    if (!supported) return null
    return if (position == PhotoFrameWatermarkPosition.AUTO) {
        copy(position = PhotoFrameWatermarkPosition.CENTER)
    } else {
        this
    }
}

fun brandFrameCornerRadius(layout: PhotoFrameLayout): Float =
    (layout.photoRight - layout.photoLeft) * 0.014f

fun PhotoFrameWatermark.forBorderMode(borderEnabled: Boolean): PhotoFrameWatermark =
    if (!borderEnabled && !position.isPhotoPlacement()) {
        copy(position = PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER)
    } else {
        this
    }

fun PhotoFrameWatermark.withoutPhotoPlacement(): PhotoFrameWatermark =
    if (position.isPhotoPlacement() || content == PhotoFrameWatermarkContent.IMAGE) {
        copy(enabled = false)
    } else {
        this
    }

fun resolvedWatermarkEffect(watermark: PhotoFrameWatermark): PhotoFrameWatermarkEffect =
    when (watermark.effect) {
        PhotoFrameWatermarkEffect.AUTO -> if (watermark.position.isPhotoPlacement()) {
            PhotoFrameWatermarkEffect.SHADOW
        } else {
            PhotoFrameWatermarkEffect.NONE
        }
        else -> watermark.effect
    }

fun resolvedWatermarkPosition(
    preset: PhotoFramePreset,
    requested: PhotoFrameWatermarkPosition,
): PhotoFrameWatermarkPosition = when (requested) {
    PhotoFrameWatermarkPosition.AUTO -> when (preset) {
        PhotoFramePreset.PLAQUE -> PhotoFrameWatermarkPosition.LEFT
        PhotoFramePreset.IMMERSIVE -> PhotoFrameWatermarkPosition.AUTO
        PhotoFramePreset.BRAND_INSET,
        PhotoFramePreset.BRAND_GALLERY,
        PhotoFramePreset.CLASSIC_SIGNATURE,
        PhotoFramePreset.COLOR_ARCHIVE,
        PhotoFramePreset.FILM_EDGE -> PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT
        PhotoFramePreset.GALLERY_MAT,
        PhotoFramePreset.FILM_GALLERY -> PhotoFrameWatermarkPosition.CENTER
        else -> PhotoFrameWatermarkPosition.CENTER
    }
    else -> requested
}
