package com.ztransfer.frame

/** Selectable derived-photo style. Enum names are persisted and must remain stable. */
enum class PhotoFramePreset(val fileSuffix: String) {
    MIST("mist"),
    CINEMA("dark"),
    MINIMAL("clean"),
    FROSTED("glass"),
    PLAQUE("plaque"),
    IMMERSIVE("immersive"),
    BRAND_INSET("brand_inset"),
    BRAND_GALLERY("brand_gallery"),
    CLASSIC_SIGNATURE("classic_signature"),
    GALLERY_MAT("gallery_mat"),
    COLOR_ARCHIVE("color_archive"),
    FILM_GALLERY("film_gallery"),
    FILM_EDGE("film_edge"),
}

/** Watermark enum names are persisted and must remain stable. */
enum class PhotoFrameWatermarkFont { SIGNATURE, ELEGANT, CALLIGRAPHY, SIMPLE, BOLD }

enum class PhotoFrameWatermarkContent { TEXT, IMAGE }

enum class PhotoFrameWatermarkPosition {
    AUTO,
    LEFT,
    CENTER,
    RIGHT,
    PHOTO_TOP_LEFT,
    PHOTO_TOP_CENTER,
    PHOTO_TOP_RIGHT,
    PHOTO_CENTER,
    PHOTO_BOTTOM_LEFT,
    PHOTO_BOTTOM_CENTER,
    PHOTO_BOTTOM_RIGHT,
}

enum class PhotoFrameWatermarkEffect { AUTO, NONE, SHADOW, OUTLINE }

enum class PhotoFrameWatermarkColor {
    ADAPTIVE,
    WHITE,
    BLACK,
    GOLD,
    MIST_BLUE,
    ROSE_GOLD,
}

data class PhotoFrameWatermark(
    val enabled: Boolean = true,
    val content: PhotoFrameWatermarkContent = PhotoFrameWatermarkContent.TEXT,
    val text: String = DEFAULT_PHOTO_FRAME_WATERMARK_TEXT,
    val imageHash: String? = null,
    val font: PhotoFrameWatermarkFont = PhotoFrameWatermarkFont.CALLIGRAPHY,
    val sizePercent: Int = DEFAULT_PHOTO_FRAME_WATERMARK_SIZE_PERCENT,
    val position: PhotoFrameWatermarkPosition = PhotoFrameWatermarkPosition.AUTO,
    val color: PhotoFrameWatermarkColor = PhotoFrameWatermarkColor.ADAPTIVE,
    val opacityPercent: Int = DEFAULT_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT,
    val effect: PhotoFrameWatermarkEffect = PhotoFrameWatermarkEffect.AUTO,
) {
    val displayText: String
        get() = limitPhotoFrameWatermarkText(text.trim())
            .ifEmpty { DEFAULT_PHOTO_FRAME_WATERMARK_TEXT }
}

const val DEFAULT_PHOTO_FRAME_WATERMARK_TEXT = "ZTransfer"
const val MAX_PHOTO_FRAME_WATERMARK_LENGTH = 24
const val MIN_PHOTO_FRAME_WATERMARK_SIZE_PERCENT = 1
const val MAX_PHOTO_FRAME_WATERMARK_SIZE_PERCENT = 300
const val DEFAULT_PHOTO_FRAME_WATERMARK_SIZE_PERCENT = 80
private const val PHOTO_FRAME_WATERMARK_SIZE_PERCENT_OFFSET = 49
const val MIN_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT = 1
const val MAX_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT = 100
const val DEFAULT_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT = 72
const val PHOTO_FRAME_WATERMARK_IMAGE_DIRECTORY = "photo-frame-watermarks"
private val PHOTO_FRAME_WATERMARK_IMAGE_HASH = Regex("[0-9a-f]{64}")
private val PHOTO_FRAME_WATERMARK_LINE_BREAKS = Regex("[\\r\\n\\t]+")
private val PHOTO_FRAME_SOURCE_EXTENSIONS = setOf("jpg", "jpeg", "png")

fun isSupportedPhotoFrameSourceExtension(extension: String): Boolean =
    extension.removePrefix(".").lowercase() in PHOTO_FRAME_SOURCE_EXTENSIONS

/** Keeps one line and truncates by Unicode code point without splitting a surrogate pair. */
fun limitPhotoFrameWatermarkText(value: String): String {
    val singleLine = value
        .replace(PHOTO_FRAME_WATERMARK_LINE_BREAKS, " ")
        .filterNot(Char::isISOControl)
    var offset = 0
    var codePoints = 0
    while (offset < singleLine.length && codePoints < MAX_PHOTO_FRAME_WATERMARK_LENGTH) {
        val first = singleLine[offset]
        offset += if (
            first in '\uD800'..'\uDBFF' &&
            offset + 1 < singleLine.length &&
            singleLine[offset + 1] in '\uDC00'..'\uDFFF'
        ) {
            2
        } else {
            1
        }
        codePoints++
    }
    return if (offset == singleLine.length) singleLine else singleLine.substring(0, offset)
}

fun normalizePhotoFrameWatermarkSizePercent(value: Int): Int =
    value.coerceIn(
        MIN_PHOTO_FRAME_WATERMARK_SIZE_PERCENT,
        MAX_PHOTO_FRAME_WATERMARK_SIZE_PERCENT,
    )

/** New 1% starts at the former 50% visual size; every following step keeps the old spacing. */
fun legacyPhotoFrameWatermarkSizePercent(value: Int): Int =
    normalizePhotoFrameWatermarkSizePercent(value) + PHOTO_FRAME_WATERMARK_SIZE_PERCENT_OFFSET

/** Converts the former 1..200 persisted scale without changing its rendered size. */
fun migratedPhotoFrameWatermarkSizePercent(value: Int): Int =
    normalizePhotoFrameWatermarkSizePercent(value - PHOTO_FRAME_WATERMARK_SIZE_PERCENT_OFFSET)

fun normalizePhotoFrameWatermarkOpacityPercent(value: Int): Int =
    value.coerceIn(
        MIN_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT,
        MAX_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT,
    )

fun photoFrameWatermarkTextSizeFraction(sizePercent: Int): Float =
    piecewiseWatermarkSizeFraction(
        sizePercent = sizePercent,
        smallPercent = 58,
        smallFraction = 0.0105f,
        mediumPercent = 75,
        mediumFraction = 0.0135f,
        largeFraction = 0.018f,
    )

fun photoFrameWatermarkImageSizeFraction(sizePercent: Int): Float =
    piecewiseWatermarkSizeFraction(
        sizePercent = sizePercent,
        smallPercent = 47,
        smallFraction = 0.035f,
        mediumPercent = 69,
        mediumFraction = 0.052f,
        largeFraction = 0.075f,
    )

private fun piecewiseWatermarkSizeFraction(
    sizePercent: Int,
    smallPercent: Int,
    smallFraction: Float,
    mediumPercent: Int,
    mediumFraction: Float,
    largeFraction: Float,
): Float {
    val percent = legacyPhotoFrameWatermarkSizePercent(sizePercent)
    return when {
        percent <= smallPercent -> smallFraction * percent / smallPercent
        percent <= mediumPercent -> {
            val progress = (percent - smallPercent).toFloat() / (mediumPercent - smallPercent)
            smallFraction + (mediumFraction - smallFraction) * progress
        }
        percent <= 100 -> {
            val progress = (percent - mediumPercent).toFloat() / (100 - mediumPercent)
            mediumFraction + (largeFraction - mediumFraction) * progress
        }
        else -> largeFraction * percent / 100f
    }
}

fun validPhotoFrameWatermarkImageHash(value: String?): String? =
    value?.lowercase()?.takeIf(PHOTO_FRAME_WATERMARK_IMAGE_HASH::matches)

/** Platform-neutral EXIF/preview values consumed by the frame presentation rules. */
data class PhotoFrameMetadata(
    val make: String?,
    val model: String?,
    val aperture: String?,
    val shutter: String?,
    val iso: String?,
    val focalLength: String?,
    val lensModel: String? = null,
    val dateTime: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val altitudeMeters: Double? = null,
    val address: String? = null,
)
