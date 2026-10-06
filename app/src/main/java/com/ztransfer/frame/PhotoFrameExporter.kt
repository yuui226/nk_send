package com.ztransfer.frame

import android.annotation.SuppressLint
import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import androidx.core.content.res.ResourcesCompat
import com.ztransfer.R
import com.ztransfer.diagnostics.PhotoGenerationProbe
import com.ztransfer.filter.PhotoFilterRenderer
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.util.applyExifOrientation
import com.ztransfer.util.formatDegreesMinutesCoordinates
import java.io.ByteArrayInputStream
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive

/** 未完成的边框派生文件；仅在完整写入后改成正式名称，App 下次启动会清理遗留项。 */
internal const val PHOTO_FRAME_PART_PREFIX = ".nkframe_"
internal const val PHOTO_FRAME_OUTPUT_DIRECTORY = "ZTFrames"
internal const val PHOTO_FRAME_JPEG_QUALITY = 100
// 较大分块显著减少 JPEG region decoder 从文件头重复扫描；单块 RGBA + 滤镜缓冲约 32MiB。
internal const val PHOTO_FRAME_REGION_TARGET_PIXELS = 4 * 1024 * 1024
private val PHOTO_FRAME_SESSION_PREFIX =
    "$PHOTO_FRAME_PART_PREFIX${UUID.randomUUID().toString().take(8)}_"
private const val PLAQUE_BAND_TO_WIDTH = 0.12f
private const val BRAND_FRAME_SIDE_TO_PHOTO_WIDTH = 0.032f
private const val BRAND_INSET_BOTTOM_TO_PHOTO_WIDTH = 0.032f
private const val BRAND_GALLERY_BOTTOM_TO_PHOTO_WIDTH = 0.16f
private const val CLASSIC_SIGNATURE_SIDE_TO_PHOTO_WIDTH = 0.03f
private const val CLASSIC_SIGNATURE_TOP_TO_PHOTO_WIDTH = 0.095f
private const val CLASSIC_SIGNATURE_BOTTOM_TO_PHOTO_WIDTH = 0.15f
private const val FILM_GALLERY_SIDE_TO_PHOTO_WIDTH = 0.085f
private const val FILM_GALLERY_TOP_TO_PHOTO_WIDTH = 0.16f
internal const val FILM_GALLERY_BAR_TO_PHOTO_WIDTH = 0.09f
private const val FILM_GALLERY_BOTTOM_TO_PHOTO_WIDTH = 0.34f
private const val FILM_EDGE_SIDE_TO_PHOTO_WIDTH = 0.07f
private const val FILM_EDGE_TOP_TO_PHOTO_WIDTH = 0.035f
private const val FILM_EDGE_BOTTOM_TO_PHOTO_WIDTH = 0.085f
private const val FILM_NEGATIVE_SIDE_TO_PHOTO_WIDTH = 0.026f
private const val FILM_NEGATIVE_TOP_TO_PHOTO_WIDTH = 0.085f
private const val FILM_NEGATIVE_BOTTOM_TO_PHOTO_WIDTH = 0.16f
private const val COLOR_ARCHIVE_SIDE_TO_PHOTO_WIDTH = 0.04f
private const val COLOR_ARCHIVE_TOP_TO_PHOTO_WIDTH = 0.04f
private const val COLOR_ARCHIVE_BOTTOM_TO_PHOTO_WIDTH = 0.17f
private val COLOR_ARCHIVE_FALLBACK_PALETTE = intArrayOf(
    0xFF262F12.toInt(),
    0xFF697B6C.toInt(),
    0xFFCDD8E0.toInt(),
    0xFF4A4B26.toInt(),
)

@Suppress("NOTHING_TO_INLINE")
private inline fun generationProbeClock(): Long =
    if (PhotoGenerationProbe.enabled) SystemClock.elapsedRealtime() else 0L

private inline fun recordGenerationStage(
    sessionId: Long,
    name: String,
    durationMs: Long,
    detail: () -> String = { "" },
) {
    if (PhotoGenerationProbe.enabled && sessionId != PhotoGenerationProbe.NO_SESSION) {
        PhotoGenerationProbe.stage(sessionId, name, durationMs, detail())
    }
}

/** 设置页可选的成片样式。名称是持久化键，不要随意改名。 */
enum class PhotoFramePreset(internal val fileSuffix: String) {
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
    FILM_NEGATIVE("film_negative"),
    PARAMETER_POSTER("parameter_poster"),
}

/** 自定义水印选项。枚举名称会直接持久化，新增档位可以，已有名称不要修改。 */
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

internal const val DEFAULT_PHOTO_FRAME_WATERMARK_TEXT = "ZTransfer"
internal const val MAX_PHOTO_FRAME_WATERMARK_LENGTH = 24
internal const val MIN_PHOTO_FRAME_WATERMARK_SIZE_PERCENT = 1
internal const val MAX_PHOTO_FRAME_WATERMARK_SIZE_PERCENT = 300
internal const val DEFAULT_PHOTO_FRAME_WATERMARK_SIZE_PERCENT = 80
private const val PHOTO_FRAME_WATERMARK_SIZE_PERCENT_OFFSET = 49
internal const val MIN_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT = 1
internal const val MAX_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT = 100
internal const val DEFAULT_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT = 72
internal const val PHOTO_FRAME_WATERMARK_IMAGE_DIRECTORY = "photo-frame-watermarks"
private val PHOTO_FRAME_WATERMARK_IMAGE_HASH = Regex("[0-9a-f]{64}")
private val PHOTO_FRAME_WATERMARK_LINE_BREAKS = Regex("[\\r\\n\\t]+")
private val PHOTO_FRAME_SOURCE_EXTENSIONS = setOf("jpg", "jpeg", "png")

internal fun isSupportedPhotoFrameSourceExtension(extension: String): Boolean =
    extension.removePrefix(".").lowercase(Locale.ROOT) in PHOTO_FRAME_SOURCE_EXTENSIONS

/** 保持单行并按 Unicode code point 截断，避免粘贴控制符或切断 emoji 代理对。 */
internal fun limitPhotoFrameWatermarkText(value: String): String {
    val singleLine = value
        .replace(PHOTO_FRAME_WATERMARK_LINE_BREAKS, " ")
        .filterNot(Char::isISOControl)
    val count = singleLine.codePointCount(0, singleLine.length)
    if (count <= MAX_PHOTO_FRAME_WATERMARK_LENGTH) return singleLine
    return singleLine.substring(
        0,
        singleLine.offsetByCodePoints(0, MAX_PHOTO_FRAME_WATERMARK_LENGTH),
    )
}

internal fun normalizePhotoFrameWatermarkSizePercent(value: Int): Int =
    value.coerceIn(
        MIN_PHOTO_FRAME_WATERMARK_SIZE_PERCENT,
        MAX_PHOTO_FRAME_WATERMARK_SIZE_PERCENT,
    )

/** New 1% starts at the former 50% visual size; every following step keeps the old spacing. */
internal fun legacyPhotoFrameWatermarkSizePercent(value: Int): Int =
    normalizePhotoFrameWatermarkSizePercent(value) + PHOTO_FRAME_WATERMARK_SIZE_PERCENT_OFFSET

/** Converts a persisted value from the former 1..200 scale without changing its rendered size. */
internal fun migratedPhotoFrameWatermarkSizePercent(value: Int): Int =
    normalizePhotoFrameWatermarkSizePercent(value - PHOTO_FRAME_WATERMARK_SIZE_PERCENT_OFFSET)

internal fun normalizePhotoFrameWatermarkOpacityPercent(value: Int): Int =
    value.coerceIn(
        MIN_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT,
        MAX_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT,
    )

/** 百分比连续变化，同时精确经过旧小/中/大三个尺寸锚点，升级后像素尺寸不跳变。 */
internal fun photoFrameWatermarkTextSizeFraction(sizePercent: Int): Float =
    piecewiseWatermarkSizeFraction(
        sizePercent = sizePercent,
        smallPercent = 58,
        smallFraction = 0.0105f,
        mediumPercent = 75,
        mediumFraction = 0.0135f,
        largeFraction = 0.018f,
    )

internal fun photoFrameWatermarkImageSizeFraction(sizePercent: Int): Float =
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

internal fun validPhotoFrameWatermarkImageHash(value: String?): String? =
    value?.lowercase(Locale.ROOT)?.takeIf(PHOTO_FRAME_WATERMARK_IMAGE_HASH::matches)

internal fun photoFrameWatermarkImageFile(context: Context, imageHash: String): File {
    val safeHash = requireNotNull(validPhotoFrameWatermarkImageHash(imageHash)) {
        "Invalid watermark image hash"
    }
    return File(File(context.filesDir, PHOTO_FRAME_WATERMARK_IMAGE_DIRECTORY), "$safeHash.image")
}

data class PhotoFrameExportResult(
    val displayName: String,
    val relativePath: String? = null,
)

internal const val LOCAL_PHOTO_FALLBACK_RELATIVE_PATH = "Pictures/ZTransfer"
private const val PHOTO_FRAME_EXPORT_TAG = "PhotoFrameExporter"

internal data class PhotoFrameDestination(
    val directoryUri: Uri,
    val occupiedNames: MutableSet<String>,
)

private fun concurrentPhotoFrameNames(names: Collection<String>): MutableSet<String> =
    ConcurrentHashMap.newKeySet<String>().apply { addAll(names) }

private fun reservePhotoFrameName(preferred: String, occupiedNames: MutableSet<String>): String =
    synchronized(occupiedNames) {
        uniqueName(preferred, occupiedNames).also(occupiedNames::add)
    }

/** A phone photo together with its preferred MediaStore album and a reliable fallback album. */
internal data class PhotoFrameMediaStoreSource(
    val sourceUri: Uri,
    val displayName: String,
    val collectionUri: Uri,
    val fallbackCollectionUri: Uri,
    val relativePath: String?,
    val relatedMediaUri: Uri?,
    val occupiedNames: MutableSet<String>,
)

private data class PhotoFrameMediaStoreRow(
    val displayName: String,
    val relativePath: String?,
    val volumeName: String?,
)

internal fun resolveWritableMediaVolume(
    reportedVolume: String?,
    uriVolume: String?,
    writableVolumes: Set<String>,
): String? = sequenceOf(reportedVolume, uriVolume)
    .filterNotNull()
    .mapNotNull { candidate ->
        writableVolumes.firstOrNull { it.equals(candidate, ignoreCase = true) }
    }
    .firstOrNull()

internal fun defaultWritableMediaVolume(writableVolumes: Set<String>): String? =
    writableVolumes.firstOrNull {
        it.equals(MediaStore.VOLUME_EXTERNAL_PRIMARY, ignoreCase = true)
    } ?: writableVolumes.sorted().firstOrNull()

internal fun isStandardImageRelativePath(relativePath: String): Boolean {
    val primaryDirectory = relativePath
        .trimStart('/', '\\')
        .substringBefore('/')
        .substringBefore('\\')
    return primaryDirectory.equals("DCIM", ignoreCase = true) ||
        primaryDirectory.equals("Pictures", ignoreCase = true)
}

internal fun canCreateDerivedImageInOriginalPath(
    relativePath: String,
    hasRelatedMediaUri: Boolean,
    sdkInt: Int,
): Boolean = isStandardImageRelativePath(relativePath) ||
    (sdkInt >= Build.VERSION_CODES.R && hasRelatedMediaUri)

internal data class PhotoFrameLayout(
    val canvasWidth: Int,
    val canvasHeight: Int,
    val photoLeft: Float,
    val photoTop: Float,
    val photoRight: Float,
    val photoBottom: Float,
    val metadataTop: Float,
    // Styling units are independent of expanded margins. Defaults preserve every legacy layout.
    val designWidth: Float = canvasWidth.toFloat(),
    val designHeight: Float = canvasHeight.toFloat(),
    val designMetadataTop: Float = metadataTop,
    val posterLayout: MeasuredPosterComposition? = null,
    val posterLayoutScale: Float = 1f,
    val textLayout: MeasuredFrameTextPlan? = null,
    val textLayoutScale: Float = 1f,
    val photoTextLayout: MeasuredFrameTextPlan? = null,
)

internal data class OrientedPhotoSize(val width: Int, val height: Int)
internal data class OrientedPhotoRegion(
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
) {
    val width: Int get() = right - left
    val height: Int get() = bottom - top
}

internal fun orientedPhotoSize(
    rawWidth: Int,
    rawHeight: Int,
    orientation: Int,
): OrientedPhotoSize {
    require(rawWidth > 0 && rawHeight > 0)
    val swapsAxes = orientation == ExifInterface.ORIENTATION_TRANSPOSE ||
        orientation == ExifInterface.ORIENTATION_ROTATE_90 ||
        orientation == ExifInterface.ORIENTATION_TRANSVERSE ||
        orientation == ExifInterface.ORIENTATION_ROTATE_270
    return if (swapsAxes) {
        OrientedPhotoSize(rawHeight, rawWidth)
    } else {
        OrientedPhotoSize(rawWidth, rawHeight)
    }
}

internal fun photoFrameRegionRows(sourceWidth: Int): Int {
    require(sourceWidth > 0)
    return (PHOTO_FRAME_REGION_TARGET_PIXELS / sourceWidth).coerceAtLeast(1)
}

internal fun orientedRegionRect(
    rawRegion: Rect,
    rawWidth: Int,
    rawHeight: Int,
    orientation: Int,
): Rect {
    val mapped = orientedPhotoRegion(
        rawLeft = rawRegion.left,
        rawTop = rawRegion.top,
        rawRight = rawRegion.right,
        rawBottom = rawRegion.bottom,
        rawWidth = rawWidth,
        rawHeight = rawHeight,
        orientation = orientation,
    )
    return Rect(mapped.left, mapped.top, mapped.right, mapped.bottom)
}

/**
 * Fills three destination points for mapping an unrotated tile directly through Canvas.
 * Point order matches source (top-left, top-right, bottom-left).
 */
internal fun fillOrientedTileDestinationTriangle(
    left: Float,
    top: Float,
    right: Float,
    bottom: Float,
    orientation: Int,
    output: FloatArray,
) {
    require(output.size >= 6)
    when (orientation) {
        ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> {
            output[0] = right; output[1] = top
            output[2] = left; output[3] = top
            output[4] = right; output[5] = bottom
        }
        ExifInterface.ORIENTATION_ROTATE_180 -> {
            output[0] = right; output[1] = bottom
            output[2] = left; output[3] = bottom
            output[4] = right; output[5] = top
        }
        ExifInterface.ORIENTATION_FLIP_VERTICAL -> {
            output[0] = left; output[1] = bottom
            output[2] = right; output[3] = bottom
            output[4] = left; output[5] = top
        }
        ExifInterface.ORIENTATION_TRANSPOSE -> {
            output[0] = left; output[1] = top
            output[2] = left; output[3] = bottom
            output[4] = right; output[5] = top
        }
        ExifInterface.ORIENTATION_ROTATE_90 -> {
            output[0] = right; output[1] = top
            output[2] = right; output[3] = bottom
            output[4] = left; output[5] = top
        }
        ExifInterface.ORIENTATION_TRANSVERSE -> {
            output[0] = right; output[1] = bottom
            output[2] = right; output[3] = top
            output[4] = left; output[5] = bottom
        }
        ExifInterface.ORIENTATION_ROTATE_270 -> {
            output[0] = left; output[1] = bottom
            output[2] = left; output[3] = top
            output[4] = right; output[5] = bottom
        }
        else -> {
            output[0] = left; output[1] = top
            output[2] = right; output[3] = top
            output[4] = left; output[5] = bottom
        }
    }
}

internal fun orientedPhotoRegion(
    rawLeft: Int,
    rawTop: Int,
    rawRight: Int,
    rawBottom: Int,
    rawWidth: Int,
    rawHeight: Int,
    orientation: Int,
): OrientedPhotoRegion {
    require(rawLeft >= 0 && rawTop >= 0)
    require(rawRight <= rawWidth && rawBottom <= rawHeight)
    require(rawRight > rawLeft && rawBottom > rawTop)
    return when (orientation) {
        ExifInterface.ORIENTATION_FLIP_HORIZONTAL ->
            OrientedPhotoRegion(rawWidth - rawRight, rawTop, rawWidth - rawLeft, rawBottom)
        ExifInterface.ORIENTATION_ROTATE_180 ->
            OrientedPhotoRegion(
                rawWidth - rawRight,
                rawHeight - rawBottom,
                rawWidth - rawLeft,
                rawHeight - rawTop,
            )
        ExifInterface.ORIENTATION_FLIP_VERTICAL ->
            OrientedPhotoRegion(rawLeft, rawHeight - rawBottom, rawRight, rawHeight - rawTop)
        ExifInterface.ORIENTATION_TRANSPOSE ->
            OrientedPhotoRegion(rawTop, rawLeft, rawBottom, rawRight)
        ExifInterface.ORIENTATION_ROTATE_90 ->
            OrientedPhotoRegion(rawHeight - rawBottom, rawLeft, rawHeight - rawTop, rawRight)
        ExifInterface.ORIENTATION_TRANSVERSE ->
            OrientedPhotoRegion(
                rawHeight - rawBottom,
                rawWidth - rawRight,
                rawHeight - rawTop,
                rawWidth - rawLeft,
            )
        ExifInterface.ORIENTATION_ROTATE_270 ->
            OrientedPhotoRegion(rawTop, rawWidth - rawRight, rawBottom, rawWidth - rawLeft)
        else -> OrientedPhotoRegion(rawLeft, rawTop, rawRight, rawBottom)
    }
}

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
    val city: String? = null,
    val region: String? = null,
    val brandStyle: PhotoFrameBrandStyle = PhotoFrameBrandStyle.TEXT,
)

internal data class FrameTextVisualBounds(
    /** 相对基线的顶部坐标，通常为负数。 */
    val top: Float,
    /** 相对基线的底部坐标，通常为零或正数。 */
    val bottom: Float,
)

internal data class PhotoWatermarkTextBounds(
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float,
)

internal data class PhotoWatermarkPlacement(
    val originX: Float,
    val baseline: Float,
)

internal data class BrandFrameBounds(
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float,
) {
    val width: Float get() = right - left
    val height: Float get() = bottom - top

    fun intersects(other: BrandFrameBounds): Boolean =
        left < other.right && other.left < right && top < other.bottom && other.top < bottom
}

private sealed interface PhotoWatermarkRenderLayout {
    val bounds: RectF

    data class Text(
        override val bounds: RectF,
        val text: String,
        val originX: Float,
        val baseline: Float,
        val paint: Paint,
        val style: PhotoFrameWatermark,
    ) : PhotoWatermarkRenderLayout

    data class Image(
        override val bounds: RectF,
        val bitmap: Bitmap,
        val alpha: Int,
    ) : PhotoWatermarkRenderLayout
}

/**
 * 边框导出器：读取已传输原片，在原片外创建新画布并另存 JPG。
 *
 * 接收 Android 可稳定解码的 JPG/JPEG/PNG。各代 NEF 无法可靠解码，强行支持会在不同
 * 手机上产生黑图或方向错误；RAW+JPEG 拍摄时应选择 JPG 成员生成效果图。
 */
object PhotoFrameExporter {
    // 派生图是原片的高品质版本，不允许静默缩成分享图。JPEG 仍必须重新编码，但使用
    // Android 编码器的最高质量档，照片主体的像素尺寸由原图完整保留。
    private const val COPY_BUFFER_BYTES = 256 * 1024
    // Preserve photographic/capture metadata, including the GPS written by the camera. The
    // source orientation is intentionally not copied because the pixels are normalized during
    // decode.
    private val COPIED_EXIF_TAGS = arrayOf(
        ExifInterface.TAG_MAKE,
        ExifInterface.TAG_MODEL,
        ExifInterface.TAG_SOFTWARE,
        ExifInterface.TAG_DATETIME,
        ExifInterface.TAG_DATETIME_ORIGINAL,
        ExifInterface.TAG_DATETIME_DIGITIZED,
        ExifInterface.TAG_EXPOSURE_TIME,
        ExifInterface.TAG_F_NUMBER,
        ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY,
        ExifInterface.TAG_FOCAL_LENGTH,
        ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM,
        ExifInterface.TAG_LENS_MAKE,
        ExifInterface.TAG_LENS_MODEL,
        ExifInterface.TAG_EXPOSURE_PROGRAM,
        ExifInterface.TAG_EXPOSURE_BIAS_VALUE,
        ExifInterface.TAG_METERING_MODE,
        ExifInterface.TAG_FLASH,
        ExifInterface.TAG_WHITE_BALANCE,
        ExifInterface.TAG_COLOR_SPACE,
        ExifInterface.TAG_GPS_VERSION_ID,
        ExifInterface.TAG_GPS_LATITUDE_REF,
        ExifInterface.TAG_GPS_LATITUDE,
        ExifInterface.TAG_GPS_LONGITUDE_REF,
        ExifInterface.TAG_GPS_LONGITUDE,
        ExifInterface.TAG_GPS_ALTITUDE_REF,
        ExifInterface.TAG_GPS_ALTITUDE,
        ExifInterface.TAG_GPS_TIMESTAMP,
        ExifInterface.TAG_GPS_DATESTAMP,
        ExifInterface.TAG_GPS_PROCESSING_METHOD,
        ExifInterface.TAG_GPS_SPEED_REF,
        ExifInterface.TAG_GPS_SPEED,
        ExifInterface.TAG_GPS_TRACK_REF,
        ExifInterface.TAG_GPS_TRACK,
    )
    private val EMPTY_METADATA =
        PhotoFrameMetadata(null, null, null, null, null, null)
    private val bundledTypefaceCache = mutableMapOf<PhotoFrameWatermarkFont, Typeface>()
    private val watermarkImageCache = linkedMapOf<String, Bitmap>()
    private class RegionDecodeUnavailableException(cause: Throwable?) :
        Exception("Source provider does not support region decoding", cause)

    internal suspend fun export(
        context: Context,
        resolver: ContentResolver,
        destination: PhotoFrameDestination,
        sourceUri: Uri,
        sourceName: String,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        borderEnabled: Boolean = true,
        metadataSettings: PhotoFrameMetadataSettings = defaultPhotoFrameMetadataSettings(preset),
        filter: PhotoFilterSelection? = null,
        probeSessionId: Long = PhotoGenerationProbe.NO_SESSION,
        metadataSnapshot: PhotoFrameMetadata? = null,
        allowLocalMetadataRead: Boolean = true,
        placeAlreadyPrepared: Boolean = false,
    ): Result<PhotoFrameExportResult> {
        return try {
            currentCoroutineContext().ensureActive()
            require(
                isSupportedPhotoFrameSourceExtension(sourceName.substringAfterLast('.', "")),
            ) {
                "Only JPG/JPEG/PNG supports borders or watermarks"
            }
            // Normalize legacy preferences before any metadata read. Legacy full addresses stay off.
            val effectiveMetadataSettings = normalizePhotoFrameMetadataSettings(metadataSettings)
            val renderedWatermark = watermark.forBorderMode(borderEnabled)
            val renderStartedAtMs = generationProbeClock()
            val rendered = renderSource(
                context = context,
                resolver = resolver,
                sourceUri = sourceUri,
                preset = preset,
                watermark = renderedWatermark,
                borderEnabled = borderEnabled,
                metadataSettings = effectiveMetadataSettings,
                metadataSnapshot = metadataSnapshot,
                filter = filter,
                probeSessionId = probeSessionId,
                allowLocalMetadataRead = allowLocalMetadataRead,
                placeAlreadyPrepared = placeAlreadyPrepared,
            )
            recordGenerationStage(
                probeSessionId,
                "render_total",
                generationProbeClock() - renderStartedAtMs,
            ) { "output=${rendered.width}x${rendered.height}" }
            val saved = try {
                currentCoroutineContext().ensureActive()
                val saveStartedAtMs = generationProbeClock()
                saveRendered(
                    resolver = resolver,
                    destination = destination,
                    sourceUri = sourceUri,
                    sourceName = sourceName,
                    preset = preset,
                    watermark = renderedWatermark,
                    borderEnabled = borderEnabled,
                    metadataSettings = effectiveMetadataSettings,
                    filter = filter,
                    bitmap = rendered,
                    probeSessionId = probeSessionId,
                    cameraMetadata = metadataSnapshot,
                ).also {
                    recordGenerationStage(
                        probeSessionId,
                        "save_total",
                        generationProbeClock() - saveStartedAtMs,
                    )
                }
            } finally {
                rendered.recycle()
            }
            Result.success(saved)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (outOfMemory: OutOfMemoryError) {
            // 派生图允许优雅失败，原片已经安全落盘；资源均由上面的 finally 回收。
            Result.failure(outOfMemory)
        } catch (error: Exception) {
            Result.failure(error)
        }
    }

    /**
     * Exports a user-picked phone photo back into its own MediaStore album. The row stays pending
     * until JPEG compression succeeds, so gallery apps never observe a partially written image.
     */
    internal suspend fun exportBesideSource(
        context: Context,
        resolver: ContentResolver,
        source: PhotoFrameMediaStoreSource,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        borderEnabled: Boolean = true,
        metadataSettings: PhotoFrameMetadataSettings = defaultPhotoFrameMetadataSettings(preset),
        filter: PhotoFilterSelection? = null,
    ): Result<PhotoFrameExportResult> {
        var stage = "render"
        return try {
            currentCoroutineContext().ensureActive()
            val effectiveMetadataSettings = normalizePhotoFrameMetadataSettings(metadataSettings)
            val renderedWatermark = watermark.forBorderMode(borderEnabled)
            val rendered = renderSource(
                context = context,
                resolver = resolver,
                sourceUri = source.sourceUri,
                // Picker/document providers may expose a transformed descriptor without the
                // original EXIF block.  When available, read metadata from the canonical
                // MediaStore URI resolved alongside the picker URI while still decoding pixels
                // from the granted source URI.
                metadataSourceUri = source.relatedMediaUri ?: source.sourceUri,
                preset = preset,
                watermark = renderedWatermark,
                borderEnabled = borderEnabled,
                metadataSettings = effectiveMetadataSettings,
                filter = filter,
            )
            stage = "save"
            val saved = try {
                currentCoroutineContext().ensureActive()
                saveRenderedToMediaStore(
                    resolver = resolver,
                    source = source,
                    preset = preset,
                    watermark = renderedWatermark,
                    borderEnabled = borderEnabled,
                    metadataSettings = effectiveMetadataSettings,
                    filter = filter,
                    bitmap = rendered,
                )
            } finally {
                rendered.recycle()
            }
            Result.success(saved)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (outOfMemory: OutOfMemoryError) {
            Result.failure(LocalPhotoExportException(stage, outOfMemory))
        } catch (error: Exception) {
            Log.e(
                PHOTO_FRAME_EXPORT_TAG,
                "Local photo export failed (authority=${source.sourceUri.authority})",
                error,
            )
            Result.failure(LocalPhotoExportException(stage, error))
        }
    }

    /** Resolves the source album when possible and always prepares a specific writable fallback. */
    @SuppressLint("NewApi") // The first statement rejects pre-Q devices before any Q API runs.
    internal fun prepareMediaStoreSource(
        context: Context,
        resolver: ContentResolver,
        sourceUri: Uri,
    ): Result<PhotoFrameMediaStoreSource> = runCatching {
        check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            "Saving beside the source requires Android 10 or newer"
        }
        val lookupUris = buildList {
            add(sourceUri)
            runCatching { MediaStore.getMediaUri(context, sourceUri) }
                .getOrNull()
                ?.takeIf { it != sourceUri }
                ?.let(::add)
            resolveMediaDocumentUri(sourceUri)?.takeIf { it != sourceUri }?.let(::add)
        }.distinct()
        val resolvedRows = lookupUris.mapNotNull { lookupUri ->
            queryMediaStoreRow(resolver, lookupUri)?.let { row -> lookupUri to row }
        }
        val resolved = resolvedRows.firstOrNull { (lookupUri, row) ->
            lookupUri.authority == MediaStore.AUTHORITY && !row.relativePath.isNullOrBlank()
        } ?: resolvedRows.firstOrNull { (_, row) -> !row.relativePath.isNullOrBlank() }
        val relatedMediaUri = resolvedRows.firstOrNull { (lookupUri, _) ->
            lookupUri.authority == MediaStore.AUTHORITY
        }?.first
        val writableVolumes = runCatching { MediaStore.getExternalVolumeNames(context) }
            .getOrDefault(emptySet())
        val reportedVolume = resolved?.second?.volumeName
        val uriVolume = relatedMediaUri?.pathSegments?.firstOrNull()
        val sourceVolume = resolveWritableMediaVolume(
            reportedVolume = reportedVolume,
            uriVolume = uriVolume,
            writableVolumes = writableVolumes,
        )
        val fallbackVolumeName = defaultWritableMediaVolume(writableVolumes)
            ?: MediaStore.VOLUME_EXTERNAL_PRIMARY
        val volumeName = sourceVolume ?: fallbackVolumeName
        val collectionUri = MediaStore.Images.Media.getContentUri(volumeName)
        val fallbackCollectionUri = MediaStore.Images.Media.getContentUri(fallbackVolumeName)
        val relativePath = resolved?.second?.relativePath
            ?.takeIf { sourceVolume != null && it.isNotBlank() }
        val displayName = resolved?.second?.displayName
            ?: resolvedRows.firstOrNull()?.second?.displayName
            ?: displayNameOf(resolver, sourceUri)
            ?: "photo.jpg"
        // Android 13+ may grant only the picked item's read permission rather than collection-wide
        // access. Name discovery is therefore best-effort; MediaStore itself resolves any physical
        // filename collision during insert, and the inserted row is queried again after publish.
        val occupiedNames = relativePath?.let { path ->
            runCatching {
                resolver.query(
                    collectionUri,
                    arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
                    "${MediaStore.MediaColumns.RELATIVE_PATH} = ?",
                    arrayOf(path),
                    null,
                )?.use { cursor ->
                    val nameColumn = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
                    buildSet {
                        if (nameColumn >= 0) {
                            while (cursor.moveToNext()) {
                                cursor.getString(nameColumn)?.let(::add)
                            }
                        }
                    }
                }.orEmpty()
            }.getOrDefault(emptySet())
        }?.toMutableSet() ?: mutableSetOf()
        PhotoFrameMediaStoreSource(
            sourceUri = sourceUri,
            displayName = displayName,
            collectionUri = collectionUri,
            fallbackCollectionUri = fallbackCollectionUri,
            relativePath = relativePath,
            relatedMediaUri = relatedMediaUri,
            occupiedNames = occupiedNames,
        )
    }.onFailure { error ->
        Log.w(
            PHOTO_FRAME_EXPORT_TAG,
            "Cannot resolve local photo destination (authority=${sourceUri.authority}): " +
                "${error.javaClass.simpleName}: ${error.message}",
        )
    }

    private fun resolveMediaDocumentUri(uri: Uri): Uri? {
        if (uri.authority != "com.android.providers.media.documents") return null
        val documentId = runCatching { DocumentsContract.getDocumentId(uri) }.getOrNull()
            ?: return null
        val parts = documentId.split(':', limit = 2)
        if (parts.size != 2 || parts[0] != "image") return null
        val mediaId = parts[1].toLongOrNull() ?: return null
        return ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, mediaId)
    }

    private fun queryMediaStoreRow(
        resolver: ContentResolver,
        uri: Uri,
    ): PhotoFrameMediaStoreRow? = runCatching {
        resolver.query(
            uri,
            arrayOf(
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.RELATIVE_PATH,
                MediaStore.MediaColumns.VOLUME_NAME,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            if (!cursor.moveToFirst()) return@use null
            val nameColumn = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
            val pathColumn = cursor.getColumnIndex(MediaStore.MediaColumns.RELATIVE_PATH)
            val volumeColumn = cursor.getColumnIndex(MediaStore.MediaColumns.VOLUME_NAME)
            val displayName = if (nameColumn >= 0) cursor.getString(nameColumn) else null
            displayName?.let {
                PhotoFrameMediaStoreRow(
                    displayName = it,
                    relativePath = if (pathColumn >= 0) cursor.getString(pathColumn) else null,
                    volumeName = if (volumeColumn >= 0) cursor.getString(volumeColumn) else null,
                )
            }
        }
    }.getOrNull()

    /** Decodes a correctly oriented, bounded preview without changing or retaining the source. */
    internal fun decodePreview(
        resolver: ContentResolver,
        sourceUri: Uri,
        maxEdge: Int = 1_920,
    ): Bitmap? = decodeBounded(resolver, sourceUri, maxEdge)

    internal fun readPreviewMetadata(
        resolver: ContentResolver,
        sourceUri: Uri,
    ): PhotoFrameMetadata = readMetadata(resolver, sourceUri)

    private suspend fun renderSource(
        context: Context,
        resolver: ContentResolver,
        sourceUri: Uri,
        metadataSourceUri: Uri = sourceUri,
        metadataSnapshot: PhotoFrameMetadata? = null,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        borderEnabled: Boolean,
        metadataSettings: PhotoFrameMetadataSettings,
        filter: PhotoFilterSelection?,
        probeSessionId: Long = PhotoGenerationProbe.NO_SESSION,
        allowLocalMetadataRead: Boolean = true,
        placeAlreadyPrepared: Boolean = false,
    ): Bitmap {
        val metadataStartedAtMs = generationProbeClock()
        val metadataTrace: ((String) -> Unit)? =
            if (probeSessionId == PhotoGenerationProbe.NO_SESSION) {
                null
            } else {
                { message ->
                    PhotoGenerationProbe.frameNote(
                        sessionId = probeSessionId,
                        category = "FRAME-META",
                        message = message,
                    )
                }
        }
        suspend fun resolvePlace(metadata: PhotoFrameMetadata): PhotoFrameMetadata =
            if (placeAlreadyPrepared) {
                // A mode/network transition after preparation must still hide cached addresses.
                if (PhotoFrameLocationResolver.allowed(context)) metadata
                else metadata.copy(city = null, region = null, address = null)
            } else PhotoFrameLocationResolver.resolve(context, metadata, metadataSettings, metadataTrace)
        val metadata = if (borderEnabled) {
            if (metadataSnapshot != null || !allowLocalMetadataRead) {
                val authoritativeMetadata = metadataSnapshot ?: EMPTY_METADATA
                val snapshotWithPlace = resolvePlace(authoritativeMetadata)
                metadataTrace?.invoke(
                    "source=camera-header result=${snapshotWithPlace.debugSummary()} " +
                        "fields=${metadataSettings.showCity}/${metadataSettings.showRegion}/" +
                        "${metadataSettings.showCoordinates}/${metadataSettings.showAltitude}",
                )
                snapshotWithPlace.withPresentation(metadataSettings)
            } else {
                val requireLocation = (metadataSettings.showCity || metadataSettings.showRegion) ||
                    metadataSettings.showCoordinates || metadataSettings.showAltitude
                val metadataUris = buildList {
                    add(metadataSourceUri)
                    // A downloaded original is often exposed through a DocumentsProvider URI while
                    // its MediaStore row remains the only descriptor that contains the camera GPS
                    // block. Resolving this alternate URI is cheap and only attempted when a GPS
                    // field is enabled for the frame.
                    if (requireLocation && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        runCatching { MediaStore.getMediaUri(context, sourceUri) }
                            .getOrNull()
                            ?.takeIf { it != metadataSourceUri }
                            ?.let(::add)
                    }
                    sourceUri.takeIf { it != metadataSourceUri }?.let(::add)
                }.distinct()
                metadataTrace?.invoke(
                    "source=local candidates=${metadataUris.joinToString(", ", transform = ::debugUri)} " +
                        "requireLocation=$requireLocation fields=${metadataSettings.showCity}/${metadataSettings.showRegion}/" +
                        "${metadataSettings.showCoordinates}/${metadataSettings.showAltitude}",
                )
                // Providers can split EXIF between descriptor and stream (or between the picker and
                // MediaStore URI). Merge location fields from every candidate; camera fields stay
                // anchored to the first URI so the existing frame layout remains unchanged.
                val merged = metadataUris.drop(1).fold(
                    readMetadata(
                        resolver,
                        metadataUris.first(),
                        null,
                        requireLocation = requireLocation,
                        trace = metadataTrace,
                    ),
                ) { current, uri ->
                    current.mergeLocationFrom(
                        readMetadata(
                            resolver,
                            uri,
                            null,
                            requireLocation = true,
                            trace = metadataTrace,
                        ),
                    )
                }
                val presented = resolvePlace(merged).withPresentation(metadataSettings)
                PhotoGenerationProbe.frameNote(
                    sessionId = probeSessionId,
                    category = "FRAME-EXPORT",
                    message = "metadata " +
                        "raw=${merged.debugSummary()} " +
                        "gpsValid=${merged.hasValidCoordinates()} " +
                        "fields=${metadataSettings.showCity}/${metadataSettings.showRegion}/${metadataSettings.showCoordinates}/" +
                        metadataSettings.showAltitude +
                        " visibleRows=${frameLocationRows(presented).size} uriCount=${metadataUris.size}",
                )
                presented
            }
        } else {
            EMPTY_METADATA
        }
        recordGenerationStage(
            probeSessionId,
            "metadata_read",
            generationProbeClock() - metadataStartedAtMs,
        ) {
            if (!borderEnabled) {
                "enabled=false"
            } else {
                "enabled=true " +
                    "parsedGps=${metadata.latitude != null && metadata.longitude != null} " +
                    "alt=${metadata.altitudeMeters != null} " +
                    "addr=${!metadata.address.isNullOrBlank()} " +
                    "visibleRows=${frameLocationRows(metadata).size} " +
                    "localMetadata=$allowLocalMetadataRead"
            }
        }
        if (borderEnabled && preset != PhotoFramePreset.IMMERSIVE) {
            return renderOriginalFrameByRegions(
                context = context,
                resolver = resolver,
                sourceUri = sourceUri,
                metadata = metadata,
                preset = preset,
                watermark = watermark,
                filter = filter,
                probeSessionId = probeSessionId,
                widthPercent = metadataSettings.widthPercent,
                backdropSettings = metadataSettings,
            )
        }
        val decodeStartedAtMs = generationProbeClock()
        val decoded = decodeOriginal(context, resolver, sourceUri,
            extraBytes = if (filter != null) 24L * 1024 * 1024 else 0L)
            ?: error("Cannot decode source photo")
        recordGenerationStage(
            probeSessionId,
            "full_decode",
            generationProbeClock() - decodeStartedAtMs,
        ) { "source=${decoded.width}x${decoded.height}" }
        return try {
            val renderContext = currentCoroutineContext()
            renderContext.ensureActive()
            if (filter != null) {
                val preparationStarted = generationProbeClock()
                val preparedFilter = PhotoFilterRenderer.prepareOriginalFilter(filter) { !renderContext.isActive }
                recordGenerationStage(probeSessionId, "filter_lookup_prepare",
                    generationProbeClock() - preparationStarted) { "kernel=${preparedFilter.cubeExecution.label} grid=${preparedFilter.cubeMapper?.gridSize ?: 0}" }
                val filterStartedAtMs = generationProbeClock()
                PhotoFilterRenderer.renderInPlace(
                    decoded,
                    preparedFilter,
                    isCancelled = { !renderContext.isActive },
                )
                recordGenerationStage(
                    probeSessionId,
                    "filter_pixels",
                    generationProbeClock() - filterStartedAtMs,
                ) { "pixels=${decoded.width.toLong() * decoded.height}" }
            }
            renderContext.ensureActive()
            val composeStartedAtMs = generationProbeClock()
            val rendered = renderFrame(
                context,
                decoded,
                metadata,
                preset,
                watermark,
                borderEnabled,
                widthPercent = metadataSettings.widthPercent,
                backdropSettings = metadataSettings,
            )
            recordGenerationStage(
                probeSessionId,
                "frame_compose",
                generationProbeClock() - composeStartedAtMs,
            )
            if (rendered !== decoded) decoded.recycle()
            rendered
        } catch (error: Throwable) {
            decoded.recycle()
            throw error
        }
    }

    /**
     * 在用户选择的保存目录下复用或创建固定成片目录，并只在首次准备时扫描一次已有名称。
     * 调用方按根目录缓存结果；名称集合支持并行导出，后续名称由 [saveRendered] 原子预留。
     */
    internal fun prepareDestination(
        resolver: ContentResolver,
        treeUri: Uri,
        parentDirectoryUri: Uri,
    ): PhotoFrameDestination {
        val parentId = DocumentsContract.getDocumentId(parentDirectoryUri)
        val directoryUri = findFrameDirectory(resolver, treeUri, parentId)
            ?: DocumentsContract.createDocument(
                resolver,
                parentDirectoryUri,
                DocumentsContract.Document.MIME_TYPE_DIR,
                PHOTO_FRAME_OUTPUT_DIRECTORY,
            )
            ?: error("Cannot create frame output directory")
        return PhotoFrameDestination(
            directoryUri = directoryUri,
            occupiedNames = concurrentPhotoFrameNames(
                listChildNames(resolver, treeUri, directoryUri),
            ),
        )
    }

    private fun findFrameDirectory(
        resolver: ContentResolver,
        treeUri: Uri,
        parentDocumentId: String,
    ): Uri? {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            parentDocumentId,
        )
        return resolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            val idColumn =
                cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameColumn =
                cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeColumn =
                cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            if (idColumn < 0 || nameColumn < 0 || mimeColumn < 0) return@use null
            while (cursor.moveToNext()) {
                val isTarget =
                    cursor.getString(nameColumn).equals(
                        PHOTO_FRAME_OUTPUT_DIRECTORY,
                        ignoreCase = true,
                    ) &&
                        cursor.getString(mimeColumn) ==
                        DocumentsContract.Document.MIME_TYPE_DIR
                if (isTarget) {
                    return@use DocumentsContract.buildDocumentUriUsingTree(
                        treeUri,
                        cursor.getString(idColumn),
                    )
                }
            }
            null
        }
    }

    private fun listChildNames(
        resolver: ContentResolver,
        treeUri: Uri,
        directoryUri: Uri,
    ): Set<String> {
        val documentId = DocumentsContract.getDocumentId(directoryUri)
        val childrenUri =
            DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, documentId)
        return resolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            val idColumn =
                cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameColumn =
                cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            if (nameColumn < 0) return@use emptySet()
            buildSet {
                while (cursor.moveToNext()) {
                    val name = cursor.getString(nameColumn) ?: continue
                    if (name.startsWith(PHOTO_FRAME_PART_PREFIX)) {
                        // 新目录把临时文件也放在内部；清理旧进程遗留项，但绝不碰本会话任务。
                        if (
                            !isCurrentPhotoFrameTempName(name) &&
                            idColumn >= 0
                        ) {
                            val childId = cursor.getString(idColumn) ?: continue
                            runCatching {
                                DocumentsContract.deleteDocument(
                                    resolver,
                                    DocumentsContract.buildDocumentUriUsingTree(
                                        treeUri,
                                        childId,
                                    ),
                                )
                            }
                        }
                    } else {
                        add(name)
                    }
                }
            }
        } ?: emptySet()
    }

    private fun readMetadata(
        resolver: ContentResolver,
        uri: Uri,
        context: Context? = null,
        requireLocation: Boolean = false,
        trace: ((String) -> Unit)? = null,
    ): PhotoFrameMetadata {
        var descriptorOpened = false
        var descriptorError: Throwable? = null
        val descriptorResult = runCatching {
            resolver.openFileDescriptor(uri, "r")?.use { pfd ->
                descriptorOpened = true
                metadataFrom(ExifInterface(pfd.fileDescriptor), context, trace)
            }
        }.onFailure { descriptorError = it }.getOrNull()
        trace?.invoke(
            "candidate=${debugUri(uri)} descriptor=" +
                (if (descriptorOpened) {
                    descriptorResult?.debugSummary() ?: "empty"
                } else {
                    "unavailable"
                }) + descriptorError?.let { " error=${it.javaClass.simpleName}" }.orEmpty(),
        )
        if (descriptorResult != null && !requireLocation) {
            trace?.invoke("candidate=${debugUri(uri)} selected=descriptor")
            return descriptorResult
        }

        // 少数 DocumentsProvider 返回不可 seek 的文件描述符，但输入流仍可正常读取。
        var streamOpened = false
        var streamError: Throwable? = null
        val streamResult = runCatching {
            resolver.openInputStream(uri)?.use { input ->
                streamOpened = true
                BufferedInputStream(input).use { metadataFrom(ExifInterface(it), context, trace) }
            }
        }.onFailure { streamError = it }.getOrNull()
        trace?.invoke(
            "candidate=${debugUri(uri)} stream=" +
                (if (streamOpened) {
                    streamResult?.debugSummary() ?: "empty"
                } else {
                    "unavailable"
                }) + streamError?.let { " error=${it.javaClass.simpleName}" }.orEmpty(),
        )
        val selected = when {
            descriptorResult != null && streamResult != null ->
                descriptorResult.mergeLocationFrom(streamResult)
            descriptorResult != null -> descriptorResult
            streamResult != null -> streamResult
            else -> EMPTY_METADATA
        }
        trace?.invoke(
            "candidate=${debugUri(uri)} selected=" +
                when {
                    descriptorResult != null && streamResult != null -> "descriptor+stream"
                    descriptorResult != null -> "descriptor"
                    streamResult != null -> "stream"
                    else -> "empty"
                } + " result=${selected.debugSummary()}",
        )
        return selected
    }

    private fun PhotoFrameMetadata.mergeLocationFrom(fallback: PhotoFrameMetadata): PhotoFrameMetadata =
        copy(
            latitude = if (hasValidCoordinates()) latitude else fallback.latitude,
            longitude = if (hasValidCoordinates()) longitude else fallback.longitude,
            altitudeMeters = altitudeMeters ?: fallback.altitudeMeters,
            address = address ?: fallback.address,
            city = city ?: fallback.city,
            region = region ?: fallback.region,
        )

    private fun PhotoFrameMetadata.hasValidCoordinates(): Boolean =
        validFrameCoordinates(latitude, longitude)

    private fun PhotoFrameMetadata.debugSummary(): String = buildString {
        append("make=").append(make?.trim().orEmpty().ifEmpty { "none" })
        append(" model=").append(model?.trim().orEmpty().ifEmpty { "none" })
        append(" lens=").append(lensModel?.trim().orEmpty().ifEmpty { "none" })
        append(" focal=").append(focalLength ?: "none")
        append(" aperture=").append(aperture ?: "none")
        append(" shutter=").append(shutter ?: "none")
        append(" iso=").append(iso ?: "none")
        append(" date=").append(dateTime ?: "none")
        append(" gps=").append(
            if (hasValidCoordinates()) {
                String.format(
                    Locale.US,
                    "%.6f,%.6f",
                    checkNotNull(latitude),
                    checkNotNull(longitude),
                )
            } else {
                "none"
            },
        )
        append(" altitude=").append(
            altitudeMeters?.takeIf { it.isFinite() && it != 0.0 }
                ?.let { String.format(Locale.US, "%.1fm", it) } ?: "none",
        )
        append(" address=").append(
            address?.trim()?.replace(Regex("\\s+"), " ")?.take(80)
                ?.ifEmpty { "none" } ?: "none",
        )
    }

    private fun debugUri(uri: Uri): String =
        uri.toString().replace(Regex("[\\r\\n\\t]+"), " ").take(180)

    private fun metadataFrom(
        exif: ExifInterface,
        context: Context? = null,
        trace: ((String) -> Unit)? = null,
    ): PhotoFrameMetadata {
        val fNumber = exif.getAttributeDouble(ExifInterface.TAG_F_NUMBER, Double.NaN)
            .takeIf { it.isFinite() && it > 0.0 }
            ?: exif.getAttributeDouble(ExifInterface.TAG_APERTURE_VALUE, Double.NaN)
                .takeIf { it.isFinite() }
                ?.let { 2.0.pow(it / 2.0) }
        val exposureSeconds =
            exif.getAttributeDouble(ExifInterface.TAG_EXPOSURE_TIME, Double.NaN)
                .takeIf { it.isFinite() && it > 0.0 }
                ?: exif.getAttributeDouble(
                    ExifInterface.TAG_SHUTTER_SPEED_VALUE,
                    Double.NaN,
                ).takeIf { it.isFinite() }?.let { 2.0.pow(-it) }
        val coordinates = exif.latLong?.takeIf { validFrameCoordinates(it.getOrNull(0), it.getOrNull(1)) }
        // ExifInterface may expose a present-but-zero latLong pair when the GPS IFD contains
        // malformed/placeholder values.  Do not let that suppress valid raw DMS tags.
        val latitude = (coordinates?.getOrNull(0)
            ?.takeIf { it.isFinite() && it in -90.0..90.0 }
            ?: parseExifCoordinate(
                exif.getAttribute(ExifInterface.TAG_GPS_LATITUDE),
                exif.getAttribute(ExifInterface.TAG_GPS_LATITUDE_REF),
            ))
            ?.takeIf { it.isFinite() && it in -90.0..90.0 }
        val longitude = (coordinates?.getOrNull(1)
            ?.takeIf { it.isFinite() && it in -180.0..180.0 }
            ?: parseExifCoordinate(
                exif.getAttribute(ExifInterface.TAG_GPS_LONGITUDE),
                exif.getAttribute(ExifInterface.TAG_GPS_LONGITUDE_REF),
            ))
            ?.takeIf { it.isFinite() && it in -180.0..180.0 }
        val altitude = exif.getAltitude(Double.NaN)
            .takeIf { it.isFinite() && it != 0.0 }
            ?: parseExifRational(exif.getAttribute(ExifInterface.TAG_GPS_ALTITUDE).orEmpty())
                ?.takeIf { it.isFinite() && it != 0.0 }
                ?.let { value ->
                    if (exif.getAttributeInt(ExifInterface.TAG_GPS_ALTITUDE_REF, 0) == 1) -value
                    else value
                }
        return PhotoFrameMetadata(
            make = exif.getAttribute(ExifInterface.TAG_MAKE),
            model = exif.getAttribute(ExifInterface.TAG_MODEL),
            aperture = fNumber?.let(::formatAperture),
            shutter = exposureSeconds?.let(::formatShutter),
            iso = normalizeIso(
                exif.getAttribute(ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY),
            ),
            focalLength = exif.getAttributeDouble(
                ExifInterface.TAG_FOCAL_LENGTH,
                Double.NaN,
            ).takeIf { it.isFinite() && it > 0.0 }
                ?.let { String.format(Locale.US, "%.0fmm", it) },
            lensModel = exif.getAttribute(ExifInterface.TAG_LENS_MODEL)
                ?.trim()
                ?.takeIf(String::isNotEmpty),
            dateTime = sequenceOf(
                ExifInterface.TAG_DATETIME_ORIGINAL,
                ExifInterface.TAG_DATETIME_DIGITIZED,
                ExifInterface.TAG_DATETIME,
            ).mapNotNull(exif::getAttribute)
                .mapNotNull(::normalizeCaptureDateTime)
                .firstOrNull(),
            latitude = latitude,
            longitude = longitude,
            altitudeMeters = altitude,
        )
    }

    /** Parses the same camera EXIF header used by the live preview for export fallback. */
    internal fun metadataFromExifHeader(
        context: Context?,
        bytes: ByteArray,
    ): PhotoFrameMetadata = metadataFromExifHeaderResult(context, bytes).getOrDefault(EMPTY_METADATA)

    internal fun metadataFromExifHeaderResult(
        context: Context?,
        bytes: ByteArray,
    ): Result<PhotoFrameMetadata> = runCatching {
        metadataFrom(ExifInterface(ByteArrayInputStream(bytes)), context)
    }

    private fun parseExifCoordinate(value: String?, reference: String?): Double? {
        val parts = value
            ?.trim()
            ?.removePrefix("[")
            ?.removeSuffix("]")
            ?.split(Regex("[,;\\s]+"))
            ?.map { it.trim().trim('"', '\'') }
            ?.filter(String::isNotEmpty)
            ?: return null
        val absolute = when {
            parts.size == 1 -> parseExifRational(parts[0]) ?: return null
            parts.size >= 3 -> {
                val degrees = parseExifRational(parts[0]) ?: return null
                val minutes = parseExifRational(parts[1]) ?: return null
                val seconds = parseExifRational(parts[2]) ?: return null
                degrees + minutes / 60.0 + seconds / 3600.0
            }
            else -> return null
        }
        return if (reference.equals("S", ignoreCase = true) ||
            reference.equals("W", ignoreCase = true)
        ) -absolute else absolute
    }

    private fun parseExifRational(value: String): Double? {
        val pieces = value.split('/', limit = 2)
        if (pieces.size == 1) return pieces[0].toDoubleOrNull()
        val numerator = pieces[0].toDoubleOrNull() ?: return null
        val denominator = pieces[1].toDoubleOrNull()?.takeIf { it != 0.0 } ?: return null
        return numerator / denominator
    }

    private fun decodeBounded(
        resolver: ContentResolver,
        uri: Uri,
        maxEdge: Int,
    ): Bitmap? = decodeBitmap(
        resolver = resolver,
        uri = uri,
        maxEdge = maxEdge,
        mutable = false,
        honorExifOrientation = true,
    )

    private fun decodeOriginal(
        context: Context,
        resolver: ContentResolver,
        uri: Uri,
        extraBytes: Long = 0L,
    ): Bitmap? = decodeBitmap(
        resolver = resolver,
        uri = uri,
        maxEdge = null,
        mutable = true,
        honorExifOrientation = true,
        allocationExtraBytes = extraBytes,
        allocationContext = context,
    )

    private fun decodeBitmap(
        resolver: ContentResolver,
        uri: Uri,
        maxEdge: Int?,
        mutable: Boolean,
        honorExifOrientation: Boolean,
        allocationExtraBytes: Long = 0L,
        allocationContext: Context? = null,
    ): Bitmap? {
        require(maxEdge == null || maxEdge > 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && honorExifOrientation) {
            try {
                return ImageDecoder.decodeBitmap(
                    ImageDecoder.createSource(resolver, uri),
                ) { decoder, info, _ ->
                    val width = info.size.width
                    val height = info.size.height
                    if (maxEdge == null) ensurePhotoAllocation(requireNotNull(allocationContext), width, height, extraBytes = allocationExtraBytes, javaBytes = allocationExtraBytes)
                    if (maxEdge != null) {
                        val scale = min(1f, maxEdge.toFloat() / maxOf(width, height))
                        decoder.setTargetSize(
                            (width * scale).roundToInt().coerceAtLeast(1),
                            (height * scale).roundToInt().coerceAtLeast(1),
                        )
                    }
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                    decoder.isMutableRequired = mutable
                    // 分享平台最终普遍以 sRGB 展示；显式色彩管理也能避免广色域 JPEG
                    // 被解成 RGBA_F16，令解码位图内存意外翻倍。
                    decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
                }
            } catch (_: Exception) {
                // 个别定制系统的 DocumentsProvider 可被 BitmapFactory 读取，却无法被
                // ImageDecoder.createSource 正常映射。回退到兼容路径；OOM 等 Error
                // 不在这里吞掉，避免内存不足时立刻再做一次同等规模解码。
            }
        }

        // Android 8，或较新系统上 ImageDecoder 与定制 DocumentsProvider 不兼容时使用。
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openFileDescriptor(uri, "r")?.use {
            BitmapFactory.decodeFileDescriptor(it.fileDescriptor, null, bounds)
        }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        if (maxEdge != null) {
            while (maxOf(bounds.outWidth / sample, bounds.outHeight / sample) > maxEdge) {
                sample *= 2
            }
        }
        val orientation = if (honorExifOrientation) {
            runCatching {
                resolver.openFileDescriptor(uri, "r")?.use {
                    ExifInterface(it.fileDescriptor).getAttributeInt(
                        ExifInterface.TAG_ORIENTATION,
                        ExifInterface.ORIENTATION_NORMAL,
                    )
                } ?: ExifInterface.ORIENTATION_NORMAL
            }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
        } else {
            ExifInterface.ORIENTATION_NORMAL
        }
        if (maxEdge == null) ensurePhotoAllocation(requireNotNull(allocationContext), bounds.outWidth, bounds.outHeight,
            copies = if (orientation == ExifInterface.ORIENTATION_NORMAL) 1 else 2,
            extraBytes = allocationExtraBytes, javaBytes = allocationExtraBytes)
        val decoded = resolver.openFileDescriptor(uri, "r")?.use {
            BitmapFactory.decodeFileDescriptor(
                it.fileDescriptor,
                null,
                BitmapFactory.Options().apply {
                    inSampleSize = sample
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                    inMutable = mutable
                },
            )
        } ?: return null
        var oriented: Bitmap? = null
        return try {
            oriented = applyExifOrientation(decoded, orientation)
            val normalized = checkNotNull(oriented)
            if (mutable && !normalized.isMutable) {
                val mutableCopy = normalized.copy(Bitmap.Config.ARGB_8888, true)
                    ?: error("Cannot create mutable source photo")
                normalized.recycle()
                mutableCopy
            } else {
                normalized
            }
        } catch (error: Throwable) {
            oriented?.takeIf { it !== decoded && !it.isRecycled }?.recycle()
            if (!decoded.isRecycled) decoded.recycle()
            throw error
        }
    }

    internal fun renderPreview(
        context: Context,
        source: Bitmap,
        metadata: PhotoFrameMetadata,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        borderEnabled: Boolean = true,
        metadataSettings: PhotoFrameMetadataSettings = defaultPhotoFrameMetadataSettings(preset),
        longEdge: Int,
        filter: PhotoFilterSelection? = null,
        previewPlaceholders: Boolean = true,
    ): Bitmap {
        val input = filter?.let { PhotoFilterRenderer.render(source, it) } ?: source
        return try {
            renderFrame(
                context = context,
                source = input,
                metadata = metadata.withPresentation(
                    metadataSettings,
                    preview = previewPlaceholders,
                    previewLocale = context.resources.configuration.locales[0] ?: Locale.getDefault(),
                ),
                preset = preset,
                watermark = watermark.forBorderMode(borderEnabled),
                borderEnabled = borderEnabled,
                // Preview must match export: filter only the photo, never the frame backdrop.
                backdropSource = source,
                longEdge = longEdge,
                widthPercent = normalizePhotoFrameWidthPercent(metadataSettings.widthPercent),
                backdropSettings = metadataSettings,
            )
        } finally {
            if (input !== source) input.recycle()
        }
    }

    private fun renderFrame(
        context: Context,
        source: Bitmap,
        metadata: PhotoFrameMetadata,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        borderEnabled: Boolean,
        backdropSource: Bitmap = source,
        longEdge: Int? = null,
        widthPercent: Int = 100,
        backdropSettings: PhotoFrameMetadataSettings = defaultPhotoFrameMetadataSettings(preset),
    ): Bitmap {
        require(longEdge == null || longEdge > 0)
        if (!borderEnabled) {
            return renderWatermarkOnly(
                context,
                source,
                watermark,
                longEdge ?: maxOf(source.width, source.height),
                allowInPlace = longEdge == null,
            )
        }
        val expandedLayout = if (preset != PhotoFramePreset.IMMERSIVE) {
            calculateMeasuredFrame(context, source.width, source.height, preset, widthPercent, metadata, watermark)
                .fitPreview(longEdge, allowUpscale = true)
        } else calculateImmersiveFrameLayout(source.width, source.height, longEdge ?: maxOf(source.width, source.height))

        return renderFrameWithLayout(context, source, metadata, preset, watermark, backdropSource, longEdge, expandedLayout, backdropSettings)
    }

    private fun renderFrameWithLayout(
        context: Context, source: Bitmap, metadata: PhotoFrameMetadata,
        preset: PhotoFramePreset, watermark: PhotoFrameWatermark, backdropSource: Bitmap,
        longEdge: Int?, layout: PhotoFrameLayout,
        backdropSettings: PhotoFrameMetadataSettings,
    ): Bitmap {
        if (
            longEdge == null &&
            preset == PhotoFramePreset.IMMERSIVE &&
            source.isMutable
        ) {
            drawImmersiveFrame(
                context = context,
                canvas = Canvas(source),
                source = source,
                layout = layout,
                metadata = metadata,
                watermark = watermark,
                drawSource = false,
            )
            return source
        }
        if (longEdge == null) ensurePhotoAllocation(context, layout.canvasWidth, layout.canvasHeight)
        val output = Bitmap.createBitmap(
            layout.canvasWidth,
            layout.canvasHeight,
            Bitmap.Config.ARGB_8888,
        )
        try {
            val canvas = Canvas(output)
            if (preset == PhotoFramePreset.PLAQUE) {
                drawPlaqueFrame(context, canvas, source, layout, watermark)
                return output
            }
            if (preset == PhotoFramePreset.IMMERSIVE) {
                drawImmersiveFrame(context, canvas, source, layout, metadata, watermark)
                return output
            }
            if (preset.isBrandFrame()) {
                drawBrandFrame(context, canvas, source, layout, preset, watermark)
                return output
            }
            if (preset.isEditorialFrame()) {
                drawEditorialFrame(
                    context,
                    canvas,
                    source,
                    backdropSource,
                    layout,
                    preset,
                    metadata,
                    watermark,
                    backdropSettings,
                )
                return output
            }
            drawBackdrop(canvas, backdropSource, preset, backdropSettings)

            val photoRect = RectF(
                layout.photoLeft,
                layout.photoTop,
                layout.photoRight,
                layout.photoBottom,
            )
            // 照片和毛玻璃参数卡共用同一圆角尺度，形成统一的卡片语言。
            val radius = photoFrameCornerRadius(layout)
            drawPhotoElevation(canvas, photoRect, radius, preset)
            val clip = Path().apply {
                addRoundRect(photoRect, radius, radius, Path.Direction.CW)
            }
            canvas.save()
            canvas.clipPath(clip)
            canvas.drawBitmap(
                source,
                null,
                photoRect,
                Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG or Paint.DITHER_FLAG),
            )
            drawPhotoWatermark(context, canvas, photoRect, preset, watermark, min(layout.designWidth, layout.designHeight))
            canvas.restore()
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = maxOf(1f, layout.designWidth * 0.0012f)
                color = if (preset != PhotoFramePreset.MINIMAL) {
                    Color.argb(70, 255, 255, 255)
                } else {
                    Color.argb(45, 20, 28, 35)
                }
                canvas.drawRoundRect(photoRect, radius, radius, this)
            }

            drawMetadata(canvas, layout, preset)
            return output
        } catch (error: Throwable) {
            output.recycle()
            throw error
        }
    }

    /**
     * 两层柔影模拟照片浮放在衬纸上的高度：大而淡的环境影负责分离背景，小而稍深的
     * 落影给出方向。比单个浓重高斯阴影更自然，也不会形成廉价的黑色光晕。
     */
    private fun drawPhotoElevation(
        canvas: Canvas,
        photoRect: RectF,
        radius: Float,
        preset: PhotoFramePreset,
    ) {
        val shortEdge = min(canvas.width, canvas.height).toFloat()
        val shadowStrength = when (preset) {
            PhotoFramePreset.CINEMA -> 1.15f
            PhotoFramePreset.MINIMAL -> 0.78f
            PhotoFramePreset.MIST, PhotoFramePreset.FROSTED -> 1f
            PhotoFramePreset.PLAQUE -> 0f
            PhotoFramePreset.IMMERSIVE -> 0f
            PhotoFramePreset.BRAND_INSET,
            PhotoFramePreset.BRAND_GALLERY -> 0.78f
            PhotoFramePreset.COLOR_ARCHIVE -> 0.78f
            PhotoFramePreset.CLASSIC_SIGNATURE,
            PhotoFramePreset.GALLERY_MAT,
            PhotoFramePreset.FILM_GALLERY,
            PhotoFramePreset.FILM_EDGE,
            PhotoFramePreset.FILM_NEGATIVE -> 0f
            PhotoFramePreset.PARAMETER_POSTER -> 1f
        }
        // ShadowLayer 在原尺寸高像素画布上直接做两次软件模糊代价很高。阴影本身没有
        // 高频细节，先在 1/4 尺寸透明代理图渲染，再双线性放大，视觉一致而参与
        // 模糊的像素数约为原来的 1/16。
        val proxyScale = 0.25f
        val proxyWidth = (canvas.width * proxyScale).roundToInt().coerceAtLeast(1)
        val proxyHeight = (canvas.height * proxyScale).roundToInt().coerceAtLeast(1)
        val proxy = Bitmap.createBitmap(proxyWidth, proxyHeight, Bitmap.Config.ARGB_8888)
        try {
            val proxyCanvas = Canvas(proxy)
            val proxyRect = RectF(
                photoRect.left * proxyScale,
                photoRect.top * proxyScale,
                photoRect.right * proxyScale,
                photoRect.bottom * proxyScale,
            )
            val proxyRadius = radius * proxyScale
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.argb(18, 0, 0, 0)
                setShadowLayer(
                    shortEdge * 0.020f * proxyScale,
                    0f,
                    shortEdge * 0.003f * proxyScale,
                    Color.argb((48 * shadowStrength).roundToInt(), 8, 15, 21),
                )
                proxyCanvas.drawRoundRect(proxyRect, proxyRadius, proxyRadius, this)
                clearShadowLayer()
            }
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.argb(20, 0, 0, 0)
                setShadowLayer(
                    shortEdge * 0.009f * proxyScale,
                    0f,
                    shortEdge * 0.009f * proxyScale,
                    Color.argb((64 * shadowStrength).roundToInt(), 5, 11, 16),
                )
                proxyCanvas.drawRoundRect(proxyRect, proxyRadius, proxyRadius, this)
                clearShadowLayer()
            }
            canvas.drawBitmap(
                proxy,
                null,
                RectF(0f, 0f, canvas.width.toFloat(), canvas.height.toFloat()),
                Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG),
            )
        } finally {
            proxy.recycle()
        }
    }

    private fun drawBackdrop(canvas: Canvas, source: Bitmap, preset: PhotoFramePreset,
        backdropSettings: PhotoFrameMetadataSettings) {
        val blur = backdropSettings.backgroundBlurPercent.coerceIn(0, 200)
        fun mask(alpha: Int) = (alpha * backdropSettings.backgroundMaskPercent.coerceIn(0, 200) / 100f).roundToInt().coerceIn(0, 255)
        when (preset) {
            PhotoFramePreset.MINIMAL -> {
                // 极轻的暖纸渐变比纯白更耐看，也能让白色照片边缘和阴影保持可见。
                Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    shader = LinearGradient(
                        0f,
                        0f,
                        0f,
                        canvas.height.toFloat(),
                        Color.rgb(250, 249, 247),
                        Color.rgb(239, 237, 232),
                        Shader.TileMode.CLAMP,
                    )
                    canvas.drawRect(
                        0f,
                        0f,
                        canvas.width.toFloat(),
                        canvas.height.toFloat(),
                        this,
                    )
                }
            }
            PhotoFramePreset.MIST,
            PhotoFramePreset.CINEMA,
            PhotoFramePreset.FROSTED,
            PhotoFramePreset.FILM_GALLERY -> {
                // 先缩图，再做两轮可控盒式模糊，最后双线性放大。相比单纯把 72px 图硬拉大，
                // 渐变更连续、没有色块，同时不依赖仅 API 31 可用的 RenderEffect。
                val blurLongEdge = if (blur in 1..49) 384 else 192
                val blurWidth: Int
                val blurHeight: Int
                if (canvas.width >= canvas.height) {
                    blurWidth = blurLongEdge
                    blurHeight =
                        (blurLongEdge * canvas.height.toFloat() / canvas.width).roundToInt().coerceAtLeast(96)
                } else {
                    blurHeight = blurLongEdge
                    blurWidth =
                        (blurLongEdge * canvas.width.toFloat() / canvas.height).roundToInt().coerceAtLeast(96)
                }
                if (blur == 0) {
                    canvas.drawCenterCrop(source, RectF(0f, 0f, canvas.width.toFloat(), canvas.height.toFloat()))
                    if (preset == PhotoFramePreset.CINEMA || preset == PhotoFramePreset.FILM_GALLERY) {
                        drawCinemaBackdropTreatment(canvas, backdropSettings.backgroundMaskPercent)
                    }
                } else {
                    val tiny = Bitmap.createBitmap(blurWidth, blurHeight, Bitmap.Config.ARGB_8888)
                    try {
                        val tinyCanvas = Canvas(tiny)
                        tinyCanvas.drawCenterCrop(
                            source,
                            RectF(0f, 0f, blurWidth.toFloat(), blurHeight.toFloat()),
                        )
                        blurBitmapInPlace(tiny, radius = (8f * blur / 100f * blurLongEdge / 192f).roundToInt().coerceAtLeast(1), passes = 2)
                        // CINEMA overlays have no high-frequency detail. Compositing them on the
                        // 192px proxy before its single upscale avoids two extra 31MP canvas passes.
                        if (
                            preset == PhotoFramePreset.CINEMA ||
                            preset == PhotoFramePreset.FILM_GALLERY
                        ) {
                            drawCinemaBackdropTreatment(tinyCanvas, backdropSettings.backgroundMaskPercent)
                        }
                        canvas.drawBitmap(
                            tiny,
                            null,
                            RectF(0f, 0f, canvas.width.toFloat(), canvas.height.toFloat()),
                            Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG),
                        )
                    } finally {
                        tiny.recycle()
                    }
                }

                when (preset) {
                    PhotoFramePreset.MIST -> {
                        // 只轻提亮，不抹掉照片本身的主色；底部连续暗化，为白色品牌/参数提供
                        // 稳定对比度。雪景会得到银灰质感，蓝天则保留克制的蓝色氛围。
                        canvas.drawColor(Color.argb(mask(62), 238, 244, 248))
                        Paint(Paint.ANTI_ALIAS_FLAG).apply {
                            shader = LinearGradient(
                                0f,
                                canvas.height * 0.60f,
                                0f,
                                canvas.height.toFloat(),
                                Color.argb(0, 3, 10, 15),
                                Color.argb(178, 3, 10, 15),
                                Shader.TileMode.CLAMP,
                            )
                            canvas.drawRect(
                                0f,
                                canvas.height * 0.58f,
                                canvas.width.toFloat(),
                                canvas.height.toFloat(),
                                this,
                            )
                        }
                    }
                    PhotoFramePreset.CINEMA -> Unit
                    PhotoFramePreset.FILM_GALLERY -> {
                        canvas.drawColor(Color.argb(mask(66), 18, 12, 10))
                        Paint(Paint.ANTI_ALIAS_FLAG).apply {
                            shader = LinearGradient(
                                0f,
                                canvas.height * 0.50f,
                                0f,
                                canvas.height.toFloat(),
                                Color.argb(0, 0, 0, 0),
                                Color.argb(mask(92), 15, 10, 8),
                                Shader.TileMode.CLAMP,
                            )
                            canvas.drawRect(
                                0f,
                                canvas.height * 0.48f,
                                canvas.width.toFloat(),
                                canvas.height.toFloat(),
                                this,
                            )
                        }
                    }
                    PhotoFramePreset.FROSTED -> {
                        // 保留照片主色的同时覆盖一层冷白雾面，让整块外框像透过磨砂玻璃；
                        // 参数区还会叠一层独立玻璃胶囊，形成清晰的材质层级。
                        Paint(Paint.ANTI_ALIAS_FLAG).apply {
                            shader = LinearGradient(
                                0f,
                                0f,
                                0f,
                                canvas.height.toFloat(),
                                Color.argb(mask(92), 250, 253, 255),
                                Color.argb(mask(132), 231, 239, 245),
                                Shader.TileMode.CLAMP,
                            )
                            canvas.drawRect(
                                0f,
                                0f,
                                canvas.width.toFloat(),
                                canvas.height.toFloat(),
                                this,
                            )
                        }
                    }
                    PhotoFramePreset.MINIMAL -> Unit
                    PhotoFramePreset.PLAQUE -> Unit
                    PhotoFramePreset.IMMERSIVE -> Unit
                    PhotoFramePreset.BRAND_INSET,
                    PhotoFramePreset.BRAND_GALLERY -> Unit
                    PhotoFramePreset.CLASSIC_SIGNATURE,
                    PhotoFramePreset.GALLERY_MAT,
                    PhotoFramePreset.COLOR_ARCHIVE,
                    PhotoFramePreset.FILM_EDGE,
                    PhotoFramePreset.FILM_NEGATIVE,
                    PhotoFramePreset.PARAMETER_POSTER -> Unit
                }
            }
            PhotoFramePreset.PLAQUE -> canvas.drawColor(Color.WHITE)
            PhotoFramePreset.IMMERSIVE -> Unit
            PhotoFramePreset.BRAND_INSET,
            PhotoFramePreset.BRAND_GALLERY -> canvas.drawColor(Color.WHITE)
            PhotoFramePreset.CLASSIC_SIGNATURE,
            PhotoFramePreset.GALLERY_MAT,
            PhotoFramePreset.COLOR_ARCHIVE -> canvas.drawColor(Color.WHITE)
            PhotoFramePreset.FILM_EDGE,
            PhotoFramePreset.FILM_NEGATIVE -> canvas.drawColor(Color.rgb(8, 8, 9))
            PhotoFramePreset.PARAMETER_POSTER -> drawBackdrop(canvas, source, PhotoFramePreset.CINEMA, backdropSettings)
        }
    }

    /**
     * 小图两阶段滑动窗口盒式模糊。只在最多 192×192 的背景代理图上执行，
     * 两轮耗时很小且内存固定；alpha 始终按不透明处理，避免边缘发黑。
     */
    private fun blurBitmapInPlace(bitmap: Bitmap, radius: Int, passes: Int) {
        val width = bitmap.width
        val height = bitmap.height
        var source = IntArray(width * height)
        var target = IntArray(source.size)
        bitmap.getPixels(source, 0, width, 0, 0, width, height)
        val diameter = radius * 2 + 1

        repeat(passes) {
            for (y in 0 until height) {
                var red = 0L
                var green = 0L
                var blue = 0L
                for (offset in -radius..radius) {
                    val color = source[y * width + offset.coerceIn(0, width - 1)]
                    red += (color ushr 16) and 0xFF
                    green += (color ushr 8) and 0xFF
                    blue += color and 0xFF
                }
                for (x in 0 until width) {
                    target[y * width + x] = Color.rgb(
                        (red / diameter).toInt(),
                        (green / diameter).toInt(),
                        (blue / diameter).toInt(),
                    )
                    val leaving = source[y * width + (x - radius).coerceIn(0, width - 1)]
                    val entering = source[y * width + (x + radius + 1).coerceIn(0, width - 1)]
                    red += ((entering ushr 16) and 0xFF) - ((leaving ushr 16) and 0xFF)
                    green += ((entering ushr 8) and 0xFF) - ((leaving ushr 8) and 0xFF)
                    blue += (entering and 0xFF) - (leaving and 0xFF)
                }
            }
            source = target.also { target = source }

            for (x in 0 until width) {
                var red = 0L
                var green = 0L
                var blue = 0L
                for (offset in -radius..radius) {
                    val color = source[offset.coerceIn(0, height - 1) * width + x]
                    red += (color ushr 16) and 0xFF
                    green += (color ushr 8) and 0xFF
                    blue += color and 0xFF
                }
                for (y in 0 until height) {
                    target[y * width + x] = Color.rgb(
                        (red / diameter).toInt(),
                        (green / diameter).toInt(),
                        (blue / diameter).toInt(),
                    )
                    val leaving = source[(y - radius).coerceIn(0, height - 1) * width + x]
                    val entering = source[(y + radius + 1).coerceIn(0, height - 1) * width + x]
                    red += ((entering ushr 16) and 0xFF) - ((leaving ushr 16) and 0xFF)
                    green += ((entering ushr 8) and 0xFF) - ((leaving ushr 8) and 0xFF)
                    blue += (entering and 0xFF) - (leaving and 0xFF)
                }
            }
            source = target.also { target = source }
        }
        bitmap.setPixels(source, 0, width, 0, 0, width, height)
    }

    private fun Canvas.drawCenterCrop(bitmap: Bitmap, target: RectF) {
        val scale = maxOf(target.width() / bitmap.width, target.height() / bitmap.height)
        val width = bitmap.width * scale
        val height = bitmap.height * scale
        val rect = RectF(
            target.centerX() - width / 2f,
            target.centerY() - height / 2f,
            target.centerX() + width / 2f,
            target.centerY() + height / 2f,
        )
        drawBitmap(bitmap, null, rect, Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG))
    }



    /** Pure geometry/text work before either preview or full-resolution canvas allocation. */
    internal fun calculateMeasuredFrame(
        context: Context, width: Int, height: Int, preset: PhotoFramePreset, percent: Int,
        metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark,
    ): PhotoFrameLayout {
        if (preset == PhotoFramePreset.PARAMETER_POSTER) {
            return calculateMeasuredParameterPosterLayout(width, height, percent, metadata)
        }
        if (preset.isEditorialFrame() || preset.isBrandFrame() || preset == PhotoFramePreset.PLAQUE) {
            return calculateMeasuredTemplateFrame(context, width, height, preset, percent, metadata, watermark)
        }
        val reference = calculateOriginalQualityPhotoFrameLayout(1000, (height.toDouble() / width * 1000).roundToInt().coerceAtLeast(1))
        val p = percent / 100f
        val light = preset == PhotoFramePreset.MIST || preset == PhotoFramePreset.CINEMA
        val ink = if (light) Color.rgb(248, 250, 252) else Color.rgb(25, 31, 38)
        val muted = if (light) Color.rgb(220, 227, 233) else Color.rgb(70, 79, 88)
        fun paint(fraction: Float, primary: Boolean = false, italic: Boolean = false) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = if (primary) ink else muted
            textSize = reference.designWidth * fraction
            typeface = Typeface.create("sans-serif", if (italic) Typeface.BOLD_ITALIC else Typeface.NORMAL)
            textAlign = Paint.Align.LEFT
        }
        var side = reference.photoLeft * p
        val top = reference.photoTop * p
        // The glass panel follows the photograph, not the expanding outer canvas.
        val frosted = preset == PhotoFramePreset.FROSTED
        val inset = if (frosted) 60f else reference.designWidth * 0.08f
        val columnWidth = (if (frosted) 1000f else 1000f + side * 2) - inset * 2
        val rows = mutableListOf<FrameTextRow>()
        val rowGap = reference.designWidth * 0.0125f * p.coerceIn(0.65f, 1f)
        fun addDescription(text: String?, style: Paint, gap: Float = rowGap, watermarkStyle: PhotoFrameWatermark? = null) {
            if (text.isNullOrBlank()) return
            val lines = wrapFrameDescription(text, style, columnWidth)
            lines.forEachIndexed { index, line ->
                rows += FrameTextRow(listOf(FrameTextRun(line, Paint(style), watermark = watermarkStyle)),
                    gapAfter = if (index == lines.lastIndex) gap else style.textSize * 0.18f,
                    align = when (watermarkStyle?.position) {
                        PhotoFrameWatermarkPosition.LEFT -> Paint.Align.LEFT
                        PhotoFrameWatermarkPosition.RIGHT -> Paint.Align.RIGHT
                        else -> Paint.Align.CENTER
                    })
            }
        }
        val brand = normalizeCameraMake(metadata.make)
        val model = normalizeCameraModel(metadata.make, metadata.model)
        val title = buildList {
            if (brand.isNotBlank()) add(FrameTextRun(brand, paint(0.032f, true, true), metadata.useBrandLogo))
            if (model.isNotBlank()) add(FrameTextRun(model, paint(0.024f, true)))
        }
        val titleRow = FrameTextRow(title, reference.designWidth * 0.016f, rowGap * 1.5f)
        if (title.isNotEmpty()) {
            if (titleRow.width <= columnWidth) rows += titleRow
            else title.forEach { run ->
                if (run.logo) rows += FrameTextRow(listOf(run), gapAfter = rowGap)
                else addDescription(run.text, run.paint)
            }
        }
        addDescription(metadata.lensModel, paint(0.0185f).apply { typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL) }, rowGap * 1.5f)
        addDescription(listOf(frameDetailLine(metadata), metadata.dateTime.orEmpty()).filter(String::isNotBlank).joinToString("   "), paint(0.020f))
        frameLocationRows(metadata).forEach { addDescription(it, paint(0.020f)) }
        val bandWatermark = watermark.withoutPhotoPlacement()
        if (bandWatermark.enabled && bandWatermark.content == PhotoFrameWatermarkContent.TEXT) {
            val style = createWatermarkPaint(context, Canvas(), preset, bandWatermark,
                Float.MAX_VALUE, min(reference.designWidth, reference.designHeight)).apply { textAlign = Paint.Align.LEFT }
            // Preserve the user's type size; wrap a long signature instead of shrinking it away.
            addDescription(bandWatermark.displayText, style, watermarkStyle = bandWatermark)
        }
        val requiredWidth = rows.maxOfOrNull { it.width } ?: 0f
        if (!frosted) side = maxOf(side, (requiredWidth + inset * 2 - 1000f) / 2)
        val canvasWidth = 1000f + side * 2
        val baseBottom = reference.canvasHeight - reference.photoBottom
        val baseContentHeight = baseBottom * if (preset == PhotoFramePreset.FROSTED) 0.84f else 1f
        val basePadding = frameMetadataVerticalPadding(baseContentHeight) * p.coerceIn(0.65f, 1f)
        val avoidPhotoShadow = preset == PhotoFramePreset.MINIMAL ||
            preset == PhotoFramePreset.CINEMA || preset == PhotoFramePreset.MIST
        // Elevation uses the canvas short edge. Width is its upper bound, so this also
        // protects wide photographs without coupling the padding to the final band height.
        val padding = if (avoidPhotoShadow && rows.isNotEmpty())
            maxOf(basePadding, canvasWidth * 0.012f) else basePadding
        // Clear the stronger shadow without adding another layer of top whitespace.
        // Bottom breathing room remains independent; spare band space is centered below.
        val topPadding = if (avoidPhotoShadow && rows.isNotEmpty()) canvasWidth * 0.020f else padding
        val preferredGap = reference.designWidth * if (avoidPhotoShadow) 0.010f else 0.0125f
        // Keep the original type sizes; shrinking margins must not be spent on bigger gaps.
        val baselineInkHeight = rows.sumOf { it.height.toDouble() }.toFloat()
        val gapCount = (rows.size - 1).coerceAtLeast(0)
        val defaultGap = if (gapCount == 0) 0f else minOf(
            preferredGap,
            baseContentHeight * 0.09f,
            ((baseContentHeight - maxOf(frameMetadataVerticalPadding(baseContentHeight), topPadding) -
                frameMetadataVerticalPadding(baseContentHeight) - baselineInkHeight) /
                gapCount).coerceAtLeast(0f),
        )
        val measuredRows = rows.map { it.copy(gapAfter = minOf(it.gapAfter, defaultGap * minOf(p, 1f))) }
        val rowHeight = frameRowsHeight(measuredRows)
        val requiredBottom = if (rows.isEmpty()) padding * 2 else
            (rowHeight + topPadding + padding) / if (preset == PhotoFramePreset.FROSTED) 0.84f else 1f
        val bottom = maxOf((reference.canvasHeight - reference.photoBottom) * p, requiredBottom)
        val sourceHeight = height.toDouble().div(width).times(1000).toFloat()
        val bandTop = top + sourceHeight
        val panelInset = if (preset == PhotoFramePreset.FROSTED) bottom * 0.08f else 0f
        val plan = positionFrameRows(measuredRows, (if (frosted) side else 0f) + inset,
            bandTop + panelInset + topPadding,
            (if (frosted) 1000f else canvasWidth) - inset * 2,
            bottom - panelInset * 2 - topPadding - padding)
        val scale = width / 1000f
        fun px(value: Float): Int {
            val result = kotlin.math.ceil(value.toDouble() * scale)
            require(result.isFinite() && result in 0.0..Int.MAX_VALUE.toDouble()) { "Frame content is too large" }
            return result.toInt()
        }
        val x = px(side)
        val y = px(top)
        return PhotoFrameLayout(Math.addExact(width, Math.multiplyExact(x, 2)),
            Math.addExact(Math.addExact(height, y), px(bottom)), x.toFloat(), y.toFloat(),
            x + width.toFloat(), y + height.toFloat(), y + height.toFloat(),
            designWidth = reference.designWidth * scale, designHeight = reference.designHeight * scale,
            designMetadataTop = reference.designMetadataTop * scale,
            textLayout = plan, textLayoutScale = scale)
    }

    /** Template-specific columns; only measurement and positioning are shared. */
    private fun calculateMeasuredTemplateFrame(
        context: Context, width: Int, height: Int, preset: PhotoFramePreset, percent: Int,
        metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark,
    ): PhotoFrameLayout {
        val photoHeight = height.toDouble().div(width).times(1000).toFloat()
        val base = calculateOriginalQualityFrameLayout(1000, photoHeight.roundToInt().coerceAtLeast(1), preset)
        val p = percent / 100f
        val dark = preset !in listOf(PhotoFramePreset.FILM_GALLERY, PhotoFramePreset.FILM_EDGE, PhotoFramePreset.FILM_NEGATIVE)
        val ink = when {
            dark -> Color.rgb(24, 27, 30)
            preset == PhotoFramePreset.FILM_NEGATIVE -> Color.rgb(238, 173, 117)
            preset == PhotoFramePreset.FILM_EDGE -> Color.rgb(224, 170, 124)
            else -> Color.rgb(250, 249, 246)
        }
        val gap = if (preset == PhotoFramePreset.COLOR_ARCHIVE)
            (base.canvasHeight - base.photoBottom) * 0.055f * minOf(p, 1f) else 10f * p.coerceIn(0.65f, 1f)
        fun style(size: Float, headline: Boolean = false) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ink
            textSize = size
            typeface = Typeface.create(
                if (preset == PhotoFramePreset.FILM_EDGE || preset == PhotoFramePreset.FILM_NEGATIVE) "sans-serif-condensed" else "sans-serif",
                if (headline) Typeface.BOLD else Typeface.NORMAL,
            )
            textAlign = Paint.Align.LEFT
        }
        fun descriptions(texts: List<String>, size: Float, available: Float, align: Paint.Align): List<FrameTextRow> =
            texts.filter(String::isNotBlank).flatMap { text ->
                val paint = style(size, preset == PhotoFramePreset.COLOR_ARCHIVE && size == 22f)
                wrapFrameDescription(text, paint, available).map {
                    FrameTextRow(listOf(FrameTextRun(it, paint, measureInkOnly = preset == PhotoFramePreset.COLOR_ARCHIVE)), gapAfter = gap, align = align)
                }
            }
        fun identity(available: Float, align: Paint.Align, size: Float): List<FrameTextRow> {
            val brand = normalizeCameraMake(metadata.make).let {
                if (preset in listOf(PhotoFramePreset.CLASSIC_SIGNATURE, PhotoFramePreset.COLOR_ARCHIVE, PhotoFramePreset.BRAND_GALLERY)) it.uppercase(Locale.ROOT) else it
            }
            val model = normalizeCameraModel(metadata.make, metadata.model)
            val identityPaint = style(size, preset != PhotoFramePreset.GALLERY_MAT).apply {
                if (preset == PhotoFramePreset.CLASSIC_SIGNATURE) typeface = Typeface.create("sans-serif-black", Typeface.BOLD_ITALIC)
            }
            val runs = buildList {
                if (brand.isNotBlank()) add(FrameTextRun(brand, identityPaint, metadata.useBrandLogo, preset.brandLogoScale(),
                    measureInkOnly = preset == PhotoFramePreset.COLOR_ARCHIVE))
                if (model.isNotBlank()) add(FrameTextRun(model, Paint(identityPaint), measureInkOnly = preset == PhotoFramePreset.COLOR_ARCHIVE))
            }
            if (runs.isEmpty()) return emptyList()
            val row = FrameTextRow(runs, 12f,
                if (preset == PhotoFramePreset.COLOR_ARCHIVE) gap else gap * 1.5f, align)
            return if (row.width <= available) listOf(row) else runs.flatMap {
                if (it.logo) listOf(FrameTextRow(listOf(it), gapAfter = gap, align = align))
                else descriptions(listOf(it.text), it.paint.textSize, available, align)
            }
        }
        var left = base.photoLeft * p
        var right = (base.canvasWidth - base.photoRight) * p
        var top = base.photoTop * p
        var bottom = (base.canvasHeight - base.photoBottom) * (percent / 100f)
        var clearance = 0f
        val padding = 20f * p.coerceIn(0.65f, 1f)
        if (preset == PhotoFramePreset.GALLERY_MAT) {
            clearance = min(1000f, photoHeight) * 0.045f + 12f
            left = maxOf(left, clearance + padding); right = maxOf(right, clearance + padding)
            top = maxOf(top, clearance + padding)
        }
        if (preset == PhotoFramePreset.FILM_GALLERY) {
            val bar = 1000f * FILM_GALLERY_BAR_TO_PHOTO_WIDTH
            top = bar + (base.photoTop - bar).coerceAtLeast(0f) * p
            bottom = bar + (base.canvasHeight - base.photoBottom - bar).coerceAtLeast(0f) * p
            left = maxOf(left, 18f + padding); right = maxOf(right, 18f + padding)
            clearance = bar + 20f
        }
        if (preset == PhotoFramePreset.FILM_EDGE) {
            // Rotated decorative lettering must fit even when information is disabled.
            left = maxOf(left, 42f); right = maxOf(right, 42f)
        }
        if (preset == PhotoFramePreset.FILM_NEGATIVE) {
            left = maxOf(left, 18f + padding)
            right = maxOf(right, 18f + padding)
            clearance = 42f
        }
        val center = Paint.Align.CENTER
        var firstWidth = 900f
        var firstOffset = 50f
        var secondOffset = 0f
        var secondWidth = 0f
        var first = emptyList<FrameTextRow>()
        var second = emptyList<FrameTextRow>()
        var header = emptyList<FrameTextRow>()
        var stripIdentity: FrameTextRow? = null
        var stripDate: FrameTextRow? = null
        val plaqueLeftSignature = preset == PhotoFramePreset.PLAQUE && watermark.enabled &&
            watermark.content == PhotoFrameWatermarkContent.TEXT &&
            resolvedWatermarkPosition(preset, watermark.position) == PhotoFrameWatermarkPosition.LEFT
        when (preset) {
            PhotoFramePreset.PLAQUE -> {
                left = 0f; right = 0f; top = 0f
                val hasIdentity = plaqueLeftSignature || !metadata.make.isNullOrBlank() || !metadata.model.isNullOrBlank() || !metadata.lensModel.isNullOrBlank()
                val rightAvailable = if (hasIdentity) 350f else 884f
                val exposureAndDate = listOf(frameDetailLine(metadata), metadata.dateTime.orEmpty()).filter(String::isNotBlank)
                val combined = exposureAndDate.joinToString("   ")
                val rightInfo = (if (combined.isBlank()) emptyList() else if (style(20f).measureText(combined) <= rightAvailable)
                    listOf(combined) else exposureAndDate) + frameLocationRows(metadata)
                firstOffset = 58f
                firstWidth = if (rightInfo.isNotEmpty()) 460f else 884f
                val brand = metadata.make?.trim()?.takeIf(String::isNotBlank)?.uppercase(Locale.ROOT)
                val model = metadata.model?.trim()?.takeIf(String::isNotBlank)
                val lens = metadata.lensModel?.trim()?.takeIf(String::isNotBlank)
                val primary = brand ?: model ?: lens
                val secondary = listOfNotNull(model?.takeIf { brand != null && !it.equals(brand, true) },
                    lens?.takeIf { it != primary }).joinToString(" · ")
                val headline = primary?.let { FrameTextRun(it, style(27f, true), brand != null && metadata.useBrandLogo, preset.brandLogoScale()) }
                first = headline?.let {
                    if (it.logo) listOf(FrameTextRow(listOf(it), gapAfter = gap, align = Paint.Align.LEFT))
                    else descriptions(listOf(it.text), 27f, firstWidth, Paint.Align.LEFT)
                }.orEmpty() + descriptions(listOf(secondary), 16.5f, firstWidth, Paint.Align.LEFT)
                secondOffset = if (hasIdentity) 600f else 58f
                secondWidth = if (hasIdentity) 350f else 884f
                second = descriptions(rightInfo, 20f, secondWidth, Paint.Align.LEFT)
            }
            PhotoFramePreset.CLASSIC_SIGNATURE -> {
                header = identity(900f, center, base.designWidth * 0.034f)
                first = descriptions(listOfNotNull(metadata.lensModel,
                    classicSignatureDetailLine(metadata).takeIf(String::isNotBlank), metadata.dateTime) +
                    frameLocationRows(metadata), base.designWidth * 0.024f, firstWidth, center)
                top = maxOf(top, frameRowsHeight(header) + padding * 2)
            }
            PhotoFramePreset.COLOR_ARCHIVE -> {
                firstWidth = 680f; firstOffset = 0f
                first = identity(firstWidth, Paint.Align.LEFT, 27f) +
                    descriptions(listOfNotNull(metadata.lensModel), 19.5f, firstWidth, Paint.Align.LEFT) +
                    descriptions(listOf(colorArchiveDetailLine(metadata)), 22f, firstWidth, Paint.Align.LEFT) +
                    descriptions(listOfNotNull(metadata.dateTime) + frameLocationRows(metadata), 18.5f, firstWidth, Paint.Align.LEFT)
                bottom = maxOf(bottom, 38f + padding * 2) // palette height
            }
            PhotoFramePreset.FILM_GALLERY -> {
                val filmPaint = style(21f, true).apply { color = Color.rgb(184, 132, 99) }
                val brand = normalizeCameraMake(metadata.make)
                val model = normalizeCameraModel(metadata.make, metadata.model)
                val stripTitle = FrameTextRow(buildList {
                    if (brand.isNotBlank()) add(FrameTextRun(brand, filmPaint, metadata.useBrandLogo, preset.brandLogoScale()))
                    if (model.isNotBlank()) add(FrameTextRun(model, filmPaint))
                }, runGap = 6f, align = Paint.Align.LEFT)
                val date = metadata.dateTime?.takeIf(String::isNotBlank)?.let {
                    FrameTextRow(listOf(FrameTextRun(it, filmPaint)))
                }
                stripIdentity = stripTitle.takeIf { it.runs.isNotEmpty() && it.width <= 580f && it.height <= 30f }
                stripDate = date?.takeIf { it.width <= 720f && it.height <= 30f }
                // A long identity belongs in the information band, never in microscopic strip text.
                first = (if (stripIdentity == null) identity(firstWidth, center, 21f) else emptyList()) +
                    descriptions(listOfNotNull(metadata.lensModel, frameDetailLine(metadata).takeIf(String::isNotBlank)) +
                        frameLocationRows(metadata) + if (stripDate == null) listOfNotNull(metadata.dateTime) else emptyList(),
                        21f, firstWidth, center)
            }
            PhotoFramePreset.FILM_EDGE -> {
                // Preserve the film strip's compact contact-sheet caption rather than stacking every field.
                val brand = normalizeCameraMake(metadata.make)
                val tail = listOf(normalizeCameraModel(metadata.make, metadata.model), metadata.lensModel.orEmpty(),
                    frameDetailLine(metadata), metadata.dateTime.orEmpty()).filter(String::isNotBlank).joinToString("   ")
                val caption = FrameTextRow(buildList {
                    if (brand.isNotBlank()) add(FrameTextRun(brand, style(16f), metadata.useBrandLogo, preset.brandLogoScale()))
                    if (tail.isNotBlank()) add(FrameTextRun(tail, style(16f)))
                }, runGap = 12f * p, gapAfter = gap, align = center)
                first = (if (caption.runs.isEmpty()) emptyList() else if (caption.width <= firstWidth) listOf(caption)
                    else identity(firstWidth, center, 16f) + descriptions(
                        listOfNotNull(metadata.lensModel, frameDetailLine(metadata).takeIf(String::isNotBlank), metadata.dateTime)
                            .joinToString("   ").let(::listOf), 16f, firstWidth, center)) +
                    descriptions(frameLocationRows(metadata), 16f, firstWidth, center)
            }
            PhotoFramePreset.FILM_NEGATIVE -> {
                firstWidth = 900f
                firstOffset = 50f
                first = descriptions(
                        listOfNotNull(
                            metadata.lensModel,
                            frameDetailLine(metadata).takeIf(String::isNotBlank),
                            metadata.dateTime,
                        ) + frameLocationRows(metadata),
                        18f,
                        firstWidth,
                        center,
                    )
                bottom = maxOf(bottom, 170f * p + frameRowsHeight(first) + padding * 2)
            }
            PhotoFramePreset.BRAND_INSET -> Unit // All information already belongs inside the photo.
            PhotoFramePreset.BRAND_GALLERY -> {
                first = identity(firstWidth, center, base.designWidth * 0.052f)
            }
            PhotoFramePreset.GALLERY_MAT -> {
                val info = listOfNotNull(metadata.lensModel, frameDetailLine(metadata).takeIf(String::isNotBlank),
                    metadata.dateTime) + frameLocationRows(metadata)
                first = identity(firstWidth, center, 28f) + descriptions(info, 20f, firstWidth, center)
            }
            else -> error("Template has its own measured layout")
        }
        val bandWatermark = when {
            preset == PhotoFramePreset.PLAQUE -> watermark.withoutPhotoPlacement().takeIf { it.enabled && it.content == PhotoFrameWatermarkContent.TEXT }
            preset == PhotoFramePreset.BRAND_GALLERY -> watermark.takeIf { it.enabled && it.content == PhotoFrameWatermarkContent.TEXT && !it.position.isPhotoPlacement() && it.position != PhotoFrameWatermarkPosition.AUTO }
            preset.isEditorialFrame() -> watermark.bandWatermarkFor(preset)
            else -> null
        }
        var signature = bandWatermark?.let { original ->
            val selected = if (preset == PhotoFramePreset.BRAND_GALLERY && original.color == PhotoFrameWatermarkColor.ADAPTIVE)
                original.copy(color = PhotoFrameWatermarkColor.BLACK) else original
            val paint = createWatermarkPaint(context, Canvas(), preset, selected, Float.MAX_VALUE,
                min(base.designWidth, base.designHeight)).apply { textAlign = Paint.Align.LEFT }
            wrapFrameDescription(selected.displayText, paint, if (plaqueLeftSignature) firstWidth else 884f).map {
                FrameTextRow(listOf(FrameTextRun(it, paint, watermark = selected)), gapAfter = gap,
                    align = when (resolvedWatermarkPosition(preset, selected.position)) {
                        PhotoFrameWatermarkPosition.LEFT -> Paint.Align.LEFT
                        PhotoFrameWatermarkPosition.RIGHT -> Paint.Align.RIGHT
                        else -> center
                    })
            }
        }.orEmpty()
        if (plaqueLeftSignature) {
            // A signature belongs to the left identity column, not below the taller column.
            first = first + signature
            signature = emptyList()
        }
        val infoHeight = maxOf(frameRowsHeight(first), frameRowsHeight(second))
        val signatureGap = if (signature.isNotEmpty() && infoHeight > 0) gap * 1.5f else 0f
        val contentHeight = infoHeight + signatureGap + frameRowsHeight(signature)
        if (preset != PhotoFramePreset.BRAND_INSET) bottom = maxOf(bottom, clearance + contentHeight + padding * 2)
        val firstExtra = ((first.maxOfOrNull { it.width } ?: 0f) - firstWidth).coerceAtLeast(0f)
        val secondExtra = ((second.maxOfOrNull { it.width } ?: 0f) - secondWidth).coerceAtLeast(0f)
        val pairedColumns = first.isNotEmpty() && second.isNotEmpty()
        val columnsExtra = if (pairedColumns) firstExtra + secondExtra else maxOf(firstExtra, secondExtra)
        val extraWidth = maxOf(columnsExtra,
            (header.maxOfOrNull { it.width } ?: 0f) - 900f,
            (signature.maxOfOrNull { it.width } ?: 0f) - 884f,
            0f)
        left += extraWidth / 2; right += extraWidth / 2
        // Expand the entire band, keeping the original gap between columns intact.
        // Any width needed only by a header/signature stays as trailing whitespace.
        firstWidth += if (pairedColumns) firstExtra else extraWidth
        secondWidth += if (pairedColumns) secondExtra else extraWidth
        if (pairedColumns) secondOffset += firstExtra
        if (preset == PhotoFramePreset.GALLERY_MAT) {
            // Increase the shorter dimension, preserving square shape and photo pixels.
            val edge = maxOf(1000f + left + right, photoHeight + top + bottom)
            val sideExtra = edge - (1000f + left + right)
            left += sideExtra / 2; right += sideExtra / 2
            val verticalExtra = edge - (photoHeight + top + bottom)
            top += verticalExtra * 0.45f; bottom += verticalExtra * 0.55f
        }
        val output = mutableListOf<PositionedFrameText>()
        stripIdentity?.let { output += positionFrameRows(listOf(it), left + 132f,
            top - 90f + 2f, 580f, 30f).items }
        stripDate?.let { output += positionFrameRows(listOf(it), left + 225f,
            top + photoHeight + 58f, 720f, 30f).items }
        val bandY = top + photoHeight
        val contentY = bandY + clearance + (bottom - clearance - contentHeight) / 2
        // Brand Gallery's explicit band signature precedes the brand at default width too.
        val signatureFirst = preset == PhotoFramePreset.BRAND_GALLERY && signature.isNotEmpty()
        val informationY = contentY + if (signatureFirst) frameRowsHeight(signature) + signatureGap else 0f
        val signatureY = if (signatureFirst) contentY else contentY + infoHeight + signatureGap
        if (first.isNotEmpty()) output += positionFrameRows(first, left + firstOffset - extraWidth / 2,
            informationY, firstWidth, infoHeight).items
        if (second.isNotEmpty()) output += positionFrameRows(second, left + secondOffset - extraWidth / 2,
            informationY, secondWidth, infoHeight).items
        if (signature.isNotEmpty()) output += positionFrameRows(signature, left + 58f - extraWidth / 2,
            signatureY, 884f + extraWidth, frameRowsHeight(signature)).items
        if (header.isNotEmpty()) output += positionFrameRows(header, (1000f + left + right - 900f - extraWidth) / 2,
            0f, 900f + extraWidth, top).items
        val scale = width / 1000f
        fun px(value: Float): Int {
            val result = kotlin.math.ceil(value.toDouble() * scale)
            require(result.isFinite() && result in 0.0..Int.MAX_VALUE.toDouble()) { "Frame content is too large" }
            return result.toInt()
        }
        val x = px(left); val y = px(top)
        var canvasWidth = Math.addExact(Math.addExact(width, x), px(right))
        var canvasHeight = Math.addExact(Math.addExact(height, y), px(bottom))
        if (preset == PhotoFramePreset.GALLERY_MAT) {
            val edge = maxOf(canvasWidth, canvasHeight); canvasWidth = edge; canvasHeight = edge
        }
        return PhotoFrameLayout(canvasWidth, canvasHeight, x.toFloat(), y.toFloat(),
            x + width.toFloat(), y + height.toFloat(), y + height.toFloat(),
            designWidth = base.designWidth * scale, designHeight = base.designHeight * scale,
            designMetadataTop = base.designMetadataTop * scale,
            textLayout = MeasuredFrameTextPlan(output), textLayoutScale = scale,
            photoTextLayout = if (preset.isBrandFrame()) measureBrandPhotoText(context,
                photoHeight, base, preset, metadata, watermark) else null)
    }

    /** Photo-relative coordinates: outer border changes never squeeze the inner information. */
    private fun measureBrandPhotoText(
        context: Context, height: Float, base: PhotoFrameLayout, preset: PhotoFramePreset,
        metadata: PhotoFrameMetadata, watermark: PhotoFrameWatermark,
    ): MeasuredFrameTextPlan {
        val shortEdge = min(1000f, height)
        val gap = shortEdge * if (preset == PhotoFramePreset.BRAND_INSET) 0.020f else 0.016f
        val availableWidth = 780f
        fun paint(size: Float, bold: Boolean = false) =
            (if (bold) fittedBrandPaint("", size, Float.MAX_VALUE, Color.WHITE).apply {
                setShadowLayer(size * 0.13f, 0f, size * 0.07f, Color.argb(190, 0, 0, 0))
            } else fittedBrandDetailPaint("", size, Float.MAX_VALUE)).apply {
                textAlign = Paint.Align.LEFT
            }
        fun run(text: String, style: Paint, logo: Boolean = false) = FrameTextRun(text, style,
            logo, preset.brandLogoScale(), measureInkOnly = true)
        fun description(text: String?, size: Float, inheritedPaint: Paint? = null): List<FrameTextRow> {
            if (text.isNullOrBlank()) return emptyList()
            val style = inheritedPaint ?: paint(size)
            return wrapFrameDescription(text, style, availableWidth).map {
                FrameTextRow(listOf(run(it, style)), gapAfter = gap)
            }
        }
        val rows = buildList {
            if (preset == PhotoFramePreset.BRAND_INSET) {
                val brand = normalizeCameraMake(metadata.make)
                val model = normalizeCameraModel(metadata.make, metadata.model)
                val style = paint(min(43f, shortEdge * 0.095f), true)
                val identity = FrameTextRow(buildList {
                    if (brand.isNotBlank()) add(run(brand, style, metadata.useBrandLogo))
                    if (model.isNotBlank()) add(run(model, style))
                }, runGap = style.textSize * 0.3f, gapAfter = gap)
                if (identity.width <= availableWidth) {
                    if (identity.runs.isNotEmpty()) add(identity)
                } else identity.runs.forEach { item ->
                    if (item.logo) add(FrameTextRow(listOf(item), gapAfter = gap))
                    else addAll(description(item.text, style.textSize, Paint(item.paint)))
                }
            }
            addAll(description(metadata.lensModel, min(19f, shortEdge * 0.042f)))
            val details = listOf(listOf(frameDetailLine(metadata), metadata.dateTime.orEmpty())
                .filter(String::isNotBlank).joinToString("   ")).filter(String::isNotBlank) + frameLocationRows(metadata)
            details.forEach { addAll(description(it, min(21f, shortEdge * 0.047f))) }
        }
        if (rows.isEmpty()) return MeasuredFrameTextPlan(emptyList())
        val photo = RectF(0f, 0f, 1000f, height)
        val occupied = layoutPhotoWatermark(context, Canvas(), photo, preset, watermark.forBrandPhoto(preset),
            min(base.designWidth, base.designHeight))?.bounds?.toBrandFrameBounds()
        val blockWidth = rows.maxOf { it.width }
        val blockHeight = frameRowsHeight(rows)
        val area = placeBrandMetadataBlock(photo.toBrandFrameBounds(), height - shortEdge * (if (preset == PhotoFramePreset.BRAND_INSET) 0.030f else 0.035f),
            blockHeight, blockWidth, occupied, shortEdge * 0.04f)
        // The legacy placer has a last-resort overlapping fallback. Measured output must not use it.
        require(occupied == null || !area.intersects(occupied)) { "Frame information and watermark need more space" }
        return positionFrameRows(rows, area.left, area.top, area.width, area.height)
    }

    private fun drawMeasuredFrameText(canvas: Canvas, layout: PhotoFrameLayout) {
        val plan = layout.textLayout ?: return
        drawMeasuredText(canvas, plan, layout.textLayoutScale) { item ->
            drawWatermarkText(canvas, item.run.text, item.x, item.baseline, item.run.paint, checkNotNull(item.run.watermark))
        }
    }

    private fun drawMetadata(
        canvas: Canvas, layout: PhotoFrameLayout, preset: PhotoFramePreset,
    ) {
        val plan = checkNotNull(layout.textLayout)
        if (preset == PhotoFramePreset.FROSTED && plan.items.isNotEmpty()) {
            drawFrostedMetadataPanel(canvas, layout, frostedMetadataPanelBounds(layout))
        }
        drawMeasuredFrameText(canvas, layout)
    }

    private fun renderWatermarkOnly(
        context: Context,
        source: Bitmap,
        watermark: PhotoFrameWatermark,
        longEdge: Int,
        allowInPlace: Boolean,
    ): Bitmap {
        val scale = min(1f, longEdge.toFloat() / maxOf(source.width, source.height))
        val width = (source.width * scale).roundToInt().coerceAtLeast(1)
        val height = (source.height * scale).roundToInt().coerceAtLeast(1)
        // Preview sources can be shared by filter, comparison and completed-frame caches.
        // Never bake a watermark into those inputs, even when no resizing is needed.
        if (allowInPlace && width == source.width && height == source.height && source.isMutable) {
            val photoRect = RectF(0f, 0f, width.toFloat(), height.toFloat())
            drawPhotoWatermark(
                context,
                Canvas(source),
                photoRect,
                PhotoFramePreset.MIST,
                watermark,
            )
            return source
        }
        val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(output)
            val photoRect = RectF(0f, 0f, width.toFloat(), height.toFloat())
            canvas.drawBitmap(
                source,
                null,
                photoRect,
                Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG or Paint.DITHER_FLAG),
            )
            // 无边框时“自适应”固定使用带阴影的亮色方案，不受隐藏的边框预设影响。
            drawPhotoWatermark(
                context,
                canvas,
                photoRect,
                PhotoFramePreset.MIST,
                watermark,
            )
            return output
        } catch (error: Throwable) {
            output.recycle()
            throw error
        }
    }

    private fun drawFrostedMetadataPanel(
        canvas: Canvas,
        layout: PhotoFrameLayout,
        panel: RectF,
    ) {
        val radius = photoFrameCornerRadius(layout)
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(150, 250, 253, 255)
            setShadowLayer(
                layout.designWidth * 0.009f,
                0f,
                layout.designHeight * 0.004f,
                Color.argb(52, 20, 35, 46),
            )
            canvas.drawRoundRect(panel, radius, radius, this)
            clearShadowLayer()
        }
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = maxOf(1f, layout.designWidth * 0.0011f)
            color = Color.argb(178, 255, 255, 255)
            canvas.drawRoundRect(panel, radius, radius, this)
        }
    }

    internal fun frostedMetadataPanelBounds(layout: PhotoFrameLayout): RectF {
        val bandHeight = layout.canvasHeight - layout.photoBottom
        val verticalInset = bandHeight * 0.08f
        return RectF(
            layout.photoLeft,
            layout.photoBottom + verticalInset,
            layout.photoRight,
            layout.canvasHeight - verticalInset,
        )
    }

    private fun createWatermarkPaint(
        context: Context,
        canvas: Canvas,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        maxWidth: Float,
        referenceShortEdge: Float = min(canvas.width, canvas.height).toFloat(),
    ): Paint {
        val shortEdge = referenceShortEdge
        return Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
            color = when (watermark.color) {
                // 显式颜色保持低饱和与轻透明，作为照片署名而不是浮在画面上的贴纸。
                PhotoFrameWatermarkColor.WHITE -> Color.rgb(244, 239, 228)
                PhotoFrameWatermarkColor.BLACK -> Color.rgb(50, 55, 60)
                PhotoFrameWatermarkColor.GOLD -> Color.rgb(204, 172, 112)
                PhotoFrameWatermarkColor.MIST_BLUE -> Color.rgb(132, 157, 180)
                PhotoFrameWatermarkColor.ROSE_GOLD -> Color.rgb(185, 128, 121)
                PhotoFrameWatermarkColor.ADAPTIVE -> when (preset) {
                    PhotoFramePreset.MIST,
                    PhotoFramePreset.CINEMA -> Color.rgb(250, 252, 253)
                    PhotoFramePreset.MINIMAL,
                    PhotoFramePreset.FROSTED -> Color.rgb(24, 31, 38)
                    PhotoFramePreset.PLAQUE -> Color.rgb(24, 31, 38)
                    PhotoFramePreset.IMMERSIVE -> Color.rgb(250, 252, 253)
                    PhotoFramePreset.BRAND_INSET,
                    PhotoFramePreset.BRAND_GALLERY -> Color.rgb(250, 252, 253)
                    PhotoFramePreset.CLASSIC_SIGNATURE,
                    PhotoFramePreset.GALLERY_MAT,
                    PhotoFramePreset.COLOR_ARCHIVE -> Color.rgb(24, 27, 30)
                    PhotoFramePreset.FILM_GALLERY,
                    PhotoFramePreset.FILM_EDGE,
                    PhotoFramePreset.FILM_NEGATIVE,
                    PhotoFramePreset.PARAMETER_POSTER -> Color.rgb(250, 249, 246)
                }
            }
            alpha = watermarkAlpha(watermark.opacityPercent)
            // 100% 对应旧“大号”，200% 即旧最大尺寸的两倍。
            textSize = shortEdge * photoFrameWatermarkTextSizeFraction(watermark.sizePercent)
            typeface = when (watermark.font) {
                PhotoFrameWatermarkFont.SIGNATURE,
                PhotoFrameWatermarkFont.ELEGANT,
                PhotoFrameWatermarkFont.CALLIGRAPHY ->
                    bundledWatermarkTypeface(context, watermark.font)
                PhotoFrameWatermarkFont.SIMPLE ->
                    Typeface.create("sans-serif", Typeface.NORMAL)
                PhotoFrameWatermarkFont.BOLD ->
                    Typeface.create("sans-serif", Typeface.BOLD)
            }
            textAlign = Paint.Align.CENTER
            val measured = measureText(watermark.displayText)
            if (measured > maxWidth && measured > 0f) {
                textSize *= maxWidth / measured
            }
        }
    }

    /**
     * 三款艺术字体随 APK 离线分发并缓存 Typeface，避免预览连续重绘时重复解析字体文件。
     * 资源异常时仍回退到系统字体，不能让一张效果图因为字体加载失败而中断导出。
     */
    private fun bundledWatermarkTypeface(
        context: Context,
        font: PhotoFrameWatermarkFont,
    ): Typeface = synchronized(bundledTypefaceCache) {
        bundledTypefaceCache.getOrPut(font) {
            val resourceId = when (font) {
                PhotoFrameWatermarkFont.SIGNATURE -> R.font.great_vibes_regular
                PhotoFrameWatermarkFont.ELEGANT -> R.font.cormorant_garamond_medium_italic
                PhotoFrameWatermarkFont.CALLIGRAPHY -> R.font.bebas_neue_regular
                PhotoFrameWatermarkFont.SIMPLE,
                PhotoFrameWatermarkFont.BOLD -> error("System font does not use bundled resources")
            }
            ResourcesCompat.getFont(context.applicationContext, resourceId)
                ?: Typeface.create("serif", Typeface.NORMAL)
        }
    }

    private fun drawPhotoWatermark(
        context: Context,
        canvas: Canvas,
        photoRect: RectF,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        referenceShortEdge: Float = min(canvas.width, canvas.height).toFloat(),
    ) {
        val layout = layoutPhotoWatermark(context, canvas, photoRect, preset, watermark, referenceShortEdge) ?: return
        drawPhotoWatermarkLayout(canvas, layout)
    }

    private fun layoutPhotoWatermark(
        context: Context,
        canvas: Canvas,
        photoRect: RectF,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        referenceShortEdge: Float = min(canvas.width, canvas.height).toFloat(),
    ): PhotoWatermarkRenderLayout? {
        if (!watermark.enabled || !watermark.position.isPhotoPlacement()) return null
        val safeInset = min(photoRect.width(), photoRect.height()) * 0.04f
        if (watermark.content == PhotoFrameWatermarkContent.IMAGE) {
            return layoutPhotoImageWatermark(context, photoRect, safeInset, watermark)
        }
        val paint = createWatermarkPaint(
            context = context,
            canvas = canvas,
            preset = preset,
            watermark = watermark,
            maxWidth = (photoRect.width() - safeInset * 2f).coerceAtLeast(1f),
            referenceShortEdge = referenceShortEdge,
        ).apply {
            // The placement calculation uses the actual glyph bounds from a left-aligned origin.
            textAlign = Paint.Align.LEFT
        }
        val text = watermark.displayText
        val bounds = Rect().also { paint.getTextBounds(text, 0, text.length, it) }
        val placement = calculatePhotoWatermarkPlacement(
            photoLeft = photoRect.left,
            photoTop = photoRect.top,
            photoRight = photoRect.right,
            photoBottom = photoRect.bottom,
            textBounds = PhotoWatermarkTextBounds(
                left = bounds.left.toFloat(),
                top = bounds.top.toFloat(),
                right = bounds.right.toFloat(),
                bottom = bounds.bottom.toFloat(),
            ),
            position = watermark.position,
        )
        val effectPadding = when (resolvedWatermarkEffect(watermark)) {
            PhotoFrameWatermarkEffect.NONE -> 0f
            PhotoFrameWatermarkEffect.SHADOW -> paint.textSize * 0.18f
            PhotoFrameWatermarkEffect.OUTLINE -> maxOf(1f, paint.textSize * 0.075f)
            PhotoFrameWatermarkEffect.AUTO -> error("AUTO must be resolved before layout")
        }
        return PhotoWatermarkRenderLayout.Text(
            bounds = RectF(
                placement.originX + bounds.left - effectPadding,
                placement.baseline + bounds.top - effectPadding,
                placement.originX + bounds.right + effectPadding,
                placement.baseline + bounds.bottom + effectPadding,
            ),
            text = text,
            originX = placement.originX,
            baseline = placement.baseline,
            paint = paint,
            style = watermark,
        )
    }

    private fun layoutPhotoImageWatermark(
        context: Context,
        photoRect: RectF,
        safeInset: Float,
        watermark: PhotoFrameWatermark,
    ): PhotoWatermarkRenderLayout.Image {
        val imageHash = requireNotNull(validPhotoFrameWatermarkImageHash(watermark.imageHash)) {
            "Image watermark has no valid private copy"
        }
        val bitmap = loadWatermarkImage(context, imageHash)
        val shortEdge = min(photoRect.width(), photoRect.height())
        // 图片与文字采用同一百分比语义：100% 是旧“大号”，最大可到旧值两倍。
        var targetHeight = shortEdge *
            photoFrameWatermarkImageSizeFraction(watermark.sizePercent)
        var targetWidth = targetHeight * bitmap.width / bitmap.height.toFloat()
        val maxWidth = (photoRect.width() - safeInset * 2f).coerceAtLeast(1f)
        if (targetWidth > maxWidth) {
            val scale = maxWidth / targetWidth
            targetWidth *= scale
            targetHeight *= scale
        }
        val bounds = PhotoWatermarkTextBounds(
            left = 0f,
            top = -targetHeight,
            right = targetWidth,
            bottom = 0f,
        )
        val placement = calculatePhotoWatermarkPlacement(
            photoLeft = photoRect.left,
            photoTop = photoRect.top,
            photoRight = photoRect.right,
            photoBottom = photoRect.bottom,
            textBounds = bounds,
            position = watermark.position,
        )
        val destination = RectF(
            placement.originX,
            placement.baseline - targetHeight,
            placement.originX + targetWidth,
            placement.baseline,
        )
        return PhotoWatermarkRenderLayout.Image(
            bounds = destination,
            bitmap = bitmap,
            alpha = watermarkAlpha(watermark.opacityPercent),
        )
    }

    private fun drawPhotoWatermarkLayout(
        canvas: Canvas,
        layout: PhotoWatermarkRenderLayout,
    ) {
        when (layout) {
            is PhotoWatermarkRenderLayout.Text -> drawWatermarkText(
                canvas = canvas,
                text = layout.text,
                x = layout.originX,
                baseline = layout.baseline,
                paint = layout.paint,
                watermark = layout.style,
            )
            is PhotoWatermarkRenderLayout.Image -> drawDownsampledWatermarkBitmap(
                canvas = canvas,
                source = layout.bitmap,
                destination = layout.bounds,
                alpha = layout.alpha,
            )
        }
    }

    private fun drawCinemaBackdropTreatment(canvas: Canvas, maskPercent: Int) {
        canvas.drawColor(Color.argb((150 * maskPercent.coerceIn(0, 200) / 100f).roundToInt().coerceIn(0, 255), 3, 9, 15))
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(
                0f,
                canvas.height * 0.62f,
                0f,
                canvas.height.toFloat(),
                Color.argb(0, 0, 0, 0),
                Color.argb(110, 0, 0, 0),
                Shader.TileMode.CLAMP,
            )
            canvas.drawRect(
                0f,
                canvas.height * 0.60f,
                canvas.width.toFloat(),
                canvas.height.toFloat(),
                this,
            )
        }
    }

    /**
     * Logo 通常带有细线和透明边缘。一次把大图缩到几十像素会跨过过多源像素，导致细线
     * 呈断续状；逐级减半相当于建立临时 mip 层，再完成最后一次缩放。源文件和缓存位图
     * 始终不变，预览与导出共用这一采样路径。
     */
    private fun drawDownsampledWatermarkBitmap(
        canvas: Canvas,
        source: Bitmap,
        destination: RectF,
        alpha: Int,
    ) {
        val targetWidth = destination.width().roundToInt().coerceAtLeast(1)
        val targetHeight = destination.height().roundToInt().coerceAtLeast(1)
        var sampled = source
        try {
            while (sampled.width > targetWidth * 2 && sampled.height > targetHeight * 2) {
                val next = Bitmap.createScaledBitmap(
                    sampled,
                    maxOf(targetWidth, sampled.width / 2),
                    maxOf(targetHeight, sampled.height / 2),
                    true,
                )
                if (sampled !== source && sampled !== next) sampled.recycle()
                sampled = next
            }
            canvas.drawBitmap(
                sampled,
                null,
                destination,
                Paint(
                    Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG or Paint.DITHER_FLAG,
                ).apply {
                    this.alpha = alpha
                },
            )
        } finally {
            if (sampled !== source) sampled.recycle()
        }
    }

    private fun loadWatermarkImage(context: Context, imageHash: String): Bitmap =
        synchronized(watermarkImageCache) {
            watermarkImageCache[imageHash]?.let { return@synchronized it }
            val file = photoFrameWatermarkImageFile(context.applicationContext, imageHash)
            require(file.isFile) { "Private watermark image is missing" }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, bounds)
            require(bounds.outWidth > 0 && bounds.outHeight > 0) {
                "Private watermark image cannot be decoded"
            }
            var sampleSize = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / sampleSize > 2048) {
                sampleSize *= 2
            }
            val bitmap = BitmapFactory.decodeFile(
                file.absolutePath,
                BitmapFactory.Options().apply { inSampleSize = sampleSize },
            ) ?: error("Private watermark image cannot be decoded")
            watermarkImageCache[imageHash] = bitmap
            while (watermarkImageCache.size > 3) {
                watermarkImageCache.remove(watermarkImageCache.keys.first())
            }
            bitmap
        }

    private fun drawWatermarkText(
        canvas: Canvas,
        text: String,
        x: Float,
        baseline: Float,
        paint: Paint,
        watermark: PhotoFrameWatermark,
    ) {
        when (resolvedWatermarkEffect(watermark)) {
            PhotoFrameWatermarkEffect.NONE -> canvas.drawText(text, x, baseline, paint)
            PhotoFrameWatermarkEffect.SHADOW -> {
                paint.setShadowLayer(
                    paint.textSize * 0.12f,
                    0f,
                    paint.textSize * 0.06f,
                    contrastingWatermarkColor(paint.color, paint.alpha),
                )
                canvas.drawText(text, x, baseline, paint)
                paint.clearShadowLayer()
            }
            PhotoFrameWatermarkEffect.OUTLINE -> {
                val outline = Paint(paint).apply {
                    style = Paint.Style.STROKE
                    strokeWidth = maxOf(1f, paint.textSize * 0.075f)
                    strokeJoin = Paint.Join.ROUND
                    color = contrastingWatermarkColor(paint.color, paint.alpha)
                }
                canvas.drawText(text, x, baseline, outline)
                canvas.drawText(text, x, baseline, paint)
            }
            PhotoFrameWatermarkEffect.AUTO -> error("AUTO must be resolved before drawing")
        }
    }

    private fun watermarkHorizontalPlacement(
        area: RectF,
        preset: PhotoFramePreset,
        requested: PhotoFrameWatermarkPosition,
    ): Pair<Float, Paint.Align> {
        val position = resolvedWatermarkPosition(preset, requested)
        val inset = area.width() * if (preset == PhotoFramePreset.PLAQUE) 0.058f else 0.07f
        return when (position) {
            PhotoFrameWatermarkPosition.LEFT -> area.left + inset to Paint.Align.LEFT
            PhotoFrameWatermarkPosition.RIGHT -> area.right - inset to Paint.Align.RIGHT
            PhotoFrameWatermarkPosition.CENTER,
            PhotoFrameWatermarkPosition.AUTO -> area.centerX() to Paint.Align.CENTER
            else -> error("Photo placement must not be drawn in the metadata area")
        }
    }

    private fun textVisualBounds(
        text: String, paint: Paint, logo: Boolean = false, logoScale: Float = 1.35f,
    ): FrameTextVisualBounds = frameIdentityVisualBounds(text, paint, logo, logoScale)

    private fun mergeTextVisualBounds(
        first: FrameTextVisualBounds,
        second: FrameTextVisualBounds,
    ): FrameTextVisualBounds = FrameTextVisualBounds(
        top = min(first.top, second.top),
        bottom = maxOf(first.bottom, second.bottom),
    )

    /**
     * Full-bleed signature treatment inspired by in-camera sharing watermarks. Camera identity and
     * the AUTO text watermark share the first line; exposure details sit below. The restrained
     * gradient is only a contrast aid and never turns into a visible panel or border.
     */
    private fun drawImmersiveFrame(
        context: Context,
        canvas: Canvas,
        source: Bitmap,
        layout: PhotoFrameLayout,
        metadata: PhotoFrameMetadata,
        watermark: PhotoFrameWatermark,
        drawSource: Boolean = true,
    ) {
        val photoRect = RectF(0f, 0f, layout.canvasWidth.toFloat(), layout.canvasHeight.toFloat())
        if (drawSource) {
            canvas.drawBitmap(
                source,
                null,
                photoRect,
                Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG or Paint.DITHER_FLAG),
            )
        }

        val metadataWatermark = watermark.withoutPhotoPlacement()
        val brand = normalizeCameraMake(metadata.make)
        val model = normalizeCameraModel(metadata.make, metadata.model)
        val cameraName = listOf(brand, model)
            .filter(String::isNotBlank)
            .joinToString(" ")
        val lens = metadata.lensModel?.trim().orEmpty()
        // Keep camera details separate from location.  The address gets its own row, while the
        // compact coordinate/altitude pair shares one row.
        val cameraDetailLine = listOf(
            immersiveFrameDetailLine(metadata),
            metadata.dateTime.orEmpty(),
        )
            .filter(String::isNotBlank)
            .joinToString("  ")
        val locationDetailLines = frameLocationRows(metadata)
        val detailLines = buildList {
            cameraDetailLine.takeIf(String::isNotBlank)?.let(::add)
            addAll(locationDetailLines)
        }
        val inlineWatermark = metadataWatermark.takeIf {
            it.enabled && it.content == PhotoFrameWatermarkContent.TEXT &&
                it.position == PhotoFrameWatermarkPosition.AUTO
        }
        val separateWatermark = metadataWatermark.takeIf {
            it.enabled && it.content == PhotoFrameWatermarkContent.TEXT &&
                it.position != PhotoFrameWatermarkPosition.AUTO
        }
        val inlineWatermarkText = inlineWatermark?.displayText.orEmpty()
        val separateWatermarkText = separateWatermark?.displayText.orEmpty()

        val shortEdge = min(photoRect.width(), photoRect.height())
        val cameraPaint = cameraName.takeIf(String::isNotEmpty)?.let {
            Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
                color = Color.rgb(250, 251, 252)
                textSize = shortEdge * 0.030f
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                setShadowLayer(textSize * 0.11f, 0f, textSize * 0.055f, Color.argb(178, 0, 0, 0))
            }
        }
        val detailPaint = detailLines.takeIf(List<String>::isNotEmpty)?.let {
            Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
                color = Color.rgb(247, 249, 251)
                textSize = shortEdge * 0.0235f
                textAlign = Paint.Align.CENTER
                typeface = Typeface.create("sans-serif", Typeface.NORMAL)
                setShadowLayer(textSize * 0.12f, 0f, textSize * 0.06f, Color.argb(188, 0, 0, 0))
            }
        }
        val lensPaint = lens.takeIf(String::isNotEmpty)?.let {
            Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
                color = Color.rgb(240, 243, 246)
                textSize = shortEdge * 0.0205f
                textAlign = Paint.Align.CENTER
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                setShadowLayer(textSize * 0.12f, 0f, textSize * 0.06f, Color.argb(188, 0, 0, 0))
            }
        }
        val inlineWatermarkPaint = inlineWatermark?.let {
            createWatermarkPaint(
                context = context,
                canvas = canvas,
                preset = PhotoFramePreset.IMMERSIVE,
                watermark = it,
                maxWidth = photoRect.width() * 0.38f,
            ).apply {
                textSize *= 1.35f
                textAlign = Paint.Align.LEFT
            }
        }
        val separateWatermarkPaint = separateWatermark?.let {
            createWatermarkPaint(
                context = context,
                canvas = canvas,
                preset = PhotoFramePreset.IMMERSIVE,
                watermark = it,
                maxWidth = photoRect.width() * 0.86f,
            )
        }

        val divider = "|"
        val dividerPaint = if (cameraPaint != null && inlineWatermarkPaint != null) {
            Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
                color = Color.argb(205, 248, 250, 252)
                textSize = shortEdge * 0.025f
                typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)
            }
        } else {
            null
        }
        var componentGap = shortEdge * 0.014f
        fun firstRowWidth(): Float =
            (cameraPaint?.measureFrameIdentity(cameraName, metadata.useBrandLogo, PhotoFramePreset.IMMERSIVE.brandLogoScale()) ?: 0f) +
                (inlineWatermarkPaint?.measureText(inlineWatermarkText) ?: 0f) +
                (dividerPaint?.measureText(divider) ?: 0f) +
                if (dividerPaint != null) componentGap * 2f else 0f

        val maxLineWidth = photoRect.width() * 0.86f
        val originalFirstRowWidth = firstRowWidth()
        if (originalFirstRowWidth > maxLineWidth) {
            val scale = maxLineWidth / originalFirstRowWidth
            cameraPaint?.let { it.textSize *= scale }
            inlineWatermarkPaint?.let { it.textSize *= scale }
            dividerPaint?.let { it.textSize *= scale }
            componentGap *= scale
        }
        detailPaint?.let { paint ->
            val measured = detailLines.maxOfOrNull(paint::measureText) ?: 0f
            if (measured > maxLineWidth) paint.textSize *= maxLineWidth / measured
        }
        lensPaint?.let { paint ->
            val measured = paint.measureText(lens)
            if (measured > maxLineWidth) paint.textSize *= maxLineWidth / measured
        }

        fun firstRowBounds(): FrameTextVisualBounds? {
            val bounds = buildList {
                cameraPaint?.let { add(textVisualBounds(cameraName, it, metadata.useBrandLogo, PhotoFramePreset.IMMERSIVE.brandLogoScale())) }
                inlineWatermarkPaint?.let {
                    add(textVisualBounds(inlineWatermarkText, it))
                }
                dividerPaint?.let { add(textVisualBounds(divider, it)) }
            }
            return bounds.reduceOrNull(::mergeTextVisualBounds)
        }

        val titleBounds = firstRowBounds()
        val lensBounds = lensPaint?.let { textVisualBounds(lens, it) }
        val detailBounds = detailPaint?.let { paint ->
            detailLines.map { line -> textVisualBounds(line, paint) }
        }.orEmpty()
        val separateBounds = separateWatermarkPaint?.let {
            textVisualBounds(separateWatermarkText, it)
        }
        val rows = buildList {
            titleBounds?.let(::add)
            lensBounds?.let(::add)
            addAll(detailBounds)
            separateBounds?.let(::add)
        }

        if (rows.isNotEmpty()) {
            val preferredGap = shortEdge * 0.013f
            val textHeight = rows.sumOf { (it.bottom - it.top).toDouble() }.toFloat()
            val blockHeight = textHeight + preferredGap * (rows.size - 1)
            val safeBottom = maxOf(shortEdge * 0.045f, photoRect.height() * 0.025f)
            val blockBottom = photoRect.bottom - safeBottom
            val blockTop = blockBottom - blockHeight
            // Preserve the photograph: metadata overlays do not darken the image beneath them.
            drawPhotoWatermark(context, canvas, photoRect, PhotoFramePreset.IMMERSIVE, watermark)

            val baselines = centeredFrameTextBaselines(
                areaTop = blockTop,
                areaBottom = blockBottom,
                rows = rows,
                preferredGap = preferredGap,
            )
            var rowIndex = 0
            val titleBaseline = if (titleBounds != null) baselines[rowIndex++] else null
            val lensBaseline = if (lensBounds != null) baselines[rowIndex++] else null
            val detailBaselines = detailBounds.map {
                baselines[rowIndex++]
            }
            val separateBaseline = if (separateBounds != null) baselines[rowIndex] else null

            titleBaseline?.let { baseline ->
                var x = photoRect.centerX() - firstRowWidth() / 2f
                cameraPaint?.let { paint ->
                    canvas.drawFrameIdentity(cameraName, x, baseline, paint, metadata.useBrandLogo, PhotoFramePreset.IMMERSIVE.brandLogoScale())
                    x += paint.measureFrameIdentity(cameraName, metadata.useBrandLogo, PhotoFramePreset.IMMERSIVE.brandLogoScale())
                }
                dividerPaint?.let { paint ->
                    x += componentGap
                    canvas.drawText(divider, x, baseline, paint)
                    x += paint.measureText(divider) + componentGap
                }
                inlineWatermarkPaint?.let { paint ->
                    val renderedWatermark = checkNotNull(inlineWatermark)
                    drawWatermarkText(
                        canvas,
                        inlineWatermarkText,
                        x,
                        baseline,
                        paint,
                        renderedWatermark,
                    )
                }
            }
            if (lensPaint != null && lensBaseline != null) {
                canvas.drawText(lens, photoRect.centerX(), lensBaseline, lensPaint)
            }
            if (detailPaint != null) {
                detailLines.forEachIndexed { index, line ->
                    canvas.drawText(
                        line,
                        photoRect.centerX(),
                        detailBaselines[index],
                        detailPaint,
                    )
                }
            }
            if (separateWatermarkPaint != null && separateBaseline != null) {
                val renderedWatermark = checkNotNull(separateWatermark)
                val (x, align) = watermarkHorizontalPlacement(
                    photoRect,
                    PhotoFramePreset.IMMERSIVE,
                    renderedWatermark.position,
                )
                separateWatermarkPaint.textAlign = align
                drawWatermarkText(
                    canvas,
                    separateWatermarkText,
                    x,
                    separateBaseline,
                    separateWatermarkPaint,
                    renderedWatermark,
                )
            }
        } else {
            drawPhotoWatermark(context, canvas, photoRect, PhotoFramePreset.IMMERSIVE, watermark)
        }
    }

    private fun copyRenderedExif(
        resolver: ContentResolver,
        sourceUri: Uri,
        targetUri: Uri,
        width: Int,
        height: Int,
        cameraMetadata: PhotoFrameMetadata? = null,
    ) {
        // Some picker/DocumentsProvider descriptors are readable for pixels but do not expose a
        // seekable file descriptor to ExifInterface.  Try the descriptor first (fast path), then
        // fall back to a buffered stream so the generated frame keeps the original GPS/EXIF data.
        val attributes = runCatching {
            resolver.openFileDescriptor(sourceUri, "r")?.use { descriptor ->
                val source = ExifInterface(descriptor.fileDescriptor)
                COPIED_EXIF_TAGS.mapNotNull { tag ->
                    source.getAttribute(tag)?.let { value -> tag to value }
                }
            }
        }.getOrNull()?.takeIf { it.isNotEmpty() }
            ?: runCatching {
                resolver.openInputStream(sourceUri)?.use { input ->
                    BufferedInputStream(input).use { buffered ->
                        val source = ExifInterface(buffered)
                        COPIED_EXIF_TAGS.mapNotNull { tag ->
                            source.getAttribute(tag)?.let { value -> tag to value }
                        }
                    }
                }
            }.getOrNull()
        val cameraLocation = cameraMetadata?.takeIf { it.hasValidCoordinates() }
        val cameraAltitude = cameraMetadata?.altitudeMeters?.takeIf {
            it.isFinite() && it != 0.0
        }
        if (attributes.isNullOrEmpty() && cameraLocation == null && cameraAltitude == null) {
            PhotoGenerationProbe.note(
                category = "FRAME-EXPORT",
                message = "source EXIF empty; preserve step skipped",
            )
            return
        }

        runCatching {
            resolver.openFileDescriptor(targetUri, "rw")?.use { descriptor ->
                val target = ExifInterface(descriptor.fileDescriptor)
                attributes.orEmpty().forEach { (tag, value) -> target.setAttribute(tag, value) }
                if (cameraLocation != null) {
                    target.setLatLong(
                        checkNotNull(cameraLocation.latitude),
                        checkNotNull(cameraLocation.longitude),
                    )
                }
                cameraAltitude?.let(target::setAltitude)
                target.setAttribute(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL.toString(),
                )
                target.setAttribute(ExifInterface.TAG_IMAGE_WIDTH, width.toString())
                target.setAttribute(ExifInterface.TAG_IMAGE_LENGTH, height.toString())
                target.setAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION, width.toString())
                target.setAttribute(ExifInterface.TAG_PIXEL_Y_DIMENSION, height.toString())
                target.saveAttributes()
            } ?: error("Target provider does not expose a writable descriptor")
        }.onFailure { error ->
            // Some cloud/custom DocumentsProviders expose writable streams but not seekable rw
            // descriptors. The high-quality image is still valid; metadata copying is best effort.
            Log.w(
                PHOTO_FRAME_EXPORT_TAG,
                "Cannot preserve derived EXIF (${error.javaClass.simpleName}: ${error.message})",
            )
        }
    }

    /**
     * Memory-bounded original-quality frame path. The unfiltered preview is used only to generate
     * the decorative backdrop. Full-resolution regions are filtered independently and drawn into
     * the 1:1 photo rectangle; frame graphics and watermarks are always drawn afterwards.
     */
    private suspend fun renderOriginalFrameByRegions(
        context: Context,
        resolver: ContentResolver,
        sourceUri: Uri,
        metadata: PhotoFrameMetadata,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        filter: PhotoFilterSelection?,
        probeSessionId: Long,
        widthPercent: Int = 100,
        backdropSettings: PhotoFrameMetadataSettings = defaultPhotoFrameMetadataSettings(preset),
    ): Bitmap = withRegionDecoder(
        context = context,
        resolver = resolver,
        uri = sourceUri,
        probeSessionId = probeSessionId,
    ) { decoder ->
        val setupStartedAtMs = generationProbeClock()
        val orientation = readSourceOrientation(resolver, sourceUri)
        val orientedSize = orientedPhotoSize(decoder.width, decoder.height, orientation)
        val layout = if (preset != PhotoFramePreset.IMMERSIVE) {
            calculateMeasuredFrame(context, orientedSize.width, orientedSize.height, preset, widthPercent, metadata, watermark)
        } else calculateOriginalQualityFrameLayout(orientedSize.width, orientedSize.height, preset)
        val regionHeight = minOf(photoFrameRegionRows(decoder.width), decoder.height)
        val tileBytes = decoder.width.toLong() * regionHeight * 4L
        val scratchBytes = if (filter != null)
            PhotoFilterRenderer.scratchPixelCount(decoder.width, regionHeight).toLong() * 4L else 0L
        val backdropEdge = backdropPreviewLongEdge(preset, backdropSettings.backgroundBlurPercent)
        // A low-blur background needs a sharper proxy, including a temporary orientation copy.
        // Default effects retain their original allocation threshold.
        val extraBackdropBytes = if (backdropEdge > 192) backdropEdge.toLong() * backdropEdge * 8L else 0L
        ensurePhotoAllocation(context, layout.canvasWidth, layout.canvasHeight,
            extraBytes = tileBytes + scratchBytes + extraBackdropBytes +
                (if (filter != null) 8L * 1024 * 1024 else 0L),
            javaBytes = scratchBytes)
        val output = Bitmap.createBitmap(
            layout.canvasWidth,
            layout.canvasHeight,
            Bitmap.Config.ARGB_8888,
        )
        recordGenerationStage(
            probeSessionId,
            "frame_setup",
            generationProbeClock() - setupStartedAtMs,
        ) {
            "output=${layout.canvasWidth}x${layout.canvasHeight} orientation=$orientation"
        }
        try {
            val canvas = Canvas(output)
            val photoRect = RectF(
                layout.photoLeft,
                layout.photoTop,
                layout.photoRight,
                layout.photoBottom,
            )
            if (preset == PhotoFramePreset.PLAQUE) {
                canvas.drawColor(Color.WHITE)
                drawPhotoRegions(
                    decoder = decoder,
                    canvas = canvas,
                    photoRect = photoRect,
                    orientation = orientation,
                    filter = filter,
                    probeSessionId = probeSessionId,
                )
                // The complete plaque band and both watermark modes are composited after filtering.
                val decorationStartedAtMs = generationProbeClock()
                drawPlaqueDecoration(context, canvas, layout, watermark)
                recordGenerationStage(
                    probeSessionId,
                    "frame_decoration",
                    generationProbeClock() - decorationStartedAtMs,
                ) { "preset=${preset.name}" }
                return@withRegionDecoder output
            }
            if (preset.isBrandFrame()) {
                drawBrandFrameBase(canvas, layout)
                val radius = brandFrameCornerRadius(layout)
                val clip = Path().apply {
                    addRoundRect(photoRect, radius, radius, Path.Direction.CW)
                }
                canvas.save()
                canvas.clipPath(clip)
                drawPhotoRegions(
                    decoder = decoder,
                    canvas = canvas,
                    photoRect = photoRect,
                    orientation = orientation,
                    filter = filter,
                    probeSessionId = probeSessionId,
                )
                canvas.restore()
                val decorationStartedAtMs = generationProbeClock()
                drawBrandFrameDecoration(
                    context = context,
                    canvas = canvas,
                    layout = layout,
                    preset = preset,
                    watermark = watermark,
                )
                recordGenerationStage(
                    probeSessionId,
                    "frame_decoration",
                    generationProbeClock() - decorationStartedAtMs,
                ) { "preset=${preset.name}" }
                return@withRegionDecoder output
            }
            if (preset.isEditorialFrame()) {
                val basePreview = when (preset) {
                    PhotoFramePreset.FILM_GALLERY,
                    PhotoFramePreset.COLOR_ARCHIVE,
                    PhotoFramePreset.PARAMETER_POSTER -> decodeRegionPreview(decoder, orientation, backdropEdge)
                    else -> null
                }
                val preview = if (
                    preset == PhotoFramePreset.COLOR_ARCHIVE &&
                    basePreview != null &&
                    filter != null
                ) {
                    try {
                        PhotoFilterRenderer.render(basePreview, filter)
                    } finally {
                        basePreview.recycle()
                    }
                } else {
                    basePreview
                }
                try {
                    drawEditorialFrameBase(canvas, preview, layout, preset, backdropSettings)
                } finally {
                    preview?.recycle()
                }
                if (preset == PhotoFramePreset.COLOR_ARCHIVE || preset == PhotoFramePreset.PARAMETER_POSTER) {
                    val radius = if (preset == PhotoFramePreset.PARAMETER_POSTER) {
                        parameterPosterCornerRadius(layout)
                    } else colorArchiveCornerRadius(layout)
                    val clip = Path().apply {
                        addRoundRect(photoRect, radius, radius, Path.Direction.CW)
                    }
                    canvas.save()
                    canvas.clipPath(clip)
                    drawPhotoRegions(
                        decoder = decoder,
                        canvas = canvas,
                        photoRect = photoRect,
                        orientation = orientation,
                        filter = filter,
                        probeSessionId = probeSessionId,
                    )
                    canvas.restore()
                } else {
                    drawPhotoRegions(
                        decoder = decoder,
                        canvas = canvas,
                        photoRect = photoRect,
                        orientation = orientation,
                        filter = filter,
                        probeSessionId = probeSessionId,
                    )
                }
                val decorationStartedAtMs = generationProbeClock()
                drawEditorialFrameDecoration(
                    context = context,
                    canvas = canvas,
                    layout = layout,
                    preset = preset,
                    metadata = metadata,
                    watermark = watermark,
                )
                recordGenerationStage(
                    probeSessionId,
                    "frame_decoration",
                    generationProbeClock() - decorationStartedAtMs,
                ) { "preset=${preset.name}" }
                return@withRegionDecoder output
            }

            // Backdrop color/blur must describe the original photo, not the filtered photo layer.
            val previewStartedAtMs = generationProbeClock()
            val unfilteredPreview = decodeRegionPreview(decoder, orientation, backdropEdge)
            recordGenerationStage(
                probeSessionId,
                "backdrop_preview_decode",
                generationProbeClock() - previewStartedAtMs,
            ) { "preview=${unfilteredPreview.width}x${unfilteredPreview.height}" }
            try {
                val backdropStartedAtMs = generationProbeClock()
                drawBackdrop(canvas, unfilteredPreview, preset, backdropSettings)
                recordGenerationStage(
                    probeSessionId,
                    "backdrop_draw",
                    generationProbeClock() - backdropStartedAtMs,
                ) { "preset=${preset.name}" }
            } finally {
                unfilteredPreview.recycle()
            }
            val radius = photoFrameCornerRadius(layout)
            val elevationStartedAtMs = generationProbeClock()
            drawPhotoElevation(canvas, photoRect, radius, preset)
            recordGenerationStage(
                probeSessionId,
                "photo_elevation",
                generationProbeClock() - elevationStartedAtMs,
            )
            val clip = Path().apply {
                addRoundRect(photoRect, radius, radius, Path.Direction.CW)
            }
            canvas.save()
            canvas.clipPath(clip)
            drawPhotoRegions(
                decoder = decoder,
                canvas = canvas,
                photoRect = photoRect,
                orientation = orientation,
                filter = filter,
                probeSessionId = probeSessionId,
            )
            val decorationStartedAtMs = generationProbeClock()
            // Watermark is intentionally after the filtered photo tiles and is never filtered.
            drawPhotoWatermark(context, canvas, photoRect, preset, watermark, min(layout.designWidth, layout.designHeight))
            canvas.restore()
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = maxOf(1f, layout.designWidth * 0.0012f)
                color = if (preset != PhotoFramePreset.MINIMAL) {
                    Color.argb(70, 255, 255, 255)
                } else {
                    Color.argb(45, 20, 28, 35)
                }
                canvas.drawRoundRect(photoRect, radius, radius, this)
            }
            drawMetadata(canvas, layout, preset)
            recordGenerationStage(
                probeSessionId,
                "frame_decoration",
                generationProbeClock() - decorationStartedAtMs,
            ) { "preset=${preset.name}" }
            output
        } catch (error: Throwable) {
            output.recycle()
            throw error
        }
    }

    private fun readSourceOrientation(resolver: ContentResolver, uri: Uri): Int =
        runCatching {
            resolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                ExifInterface(descriptor.fileDescriptor).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL,
                )
            } ?: ExifInterface.ORIENTATION_NORMAL
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)

    @Suppress("DEPRECATION")
    private suspend fun <T> withRegionDecoder(
        context: Context,
        resolver: ContentResolver,
        uri: Uri,
        probeSessionId: Long,
        block: suspend (BitmapRegionDecoder) -> T,
    ): T {
        val openStartedAtMs = generationProbeClock()
        var descriptorFailure: Exception? = null
        val descriptor = try {
            resolver.openFileDescriptor(uri, "r")
        } catch (error: Exception) {
            descriptorFailure = error
            null
        }
        descriptor?.let {
            try {
                val decoder = try {
                    BitmapRegionDecoder.newInstance(it.fileDescriptor, false)
                } catch (error: Exception) {
                    descriptorFailure = error
                    null
                }
                if (decoder != null) {
                    recordGenerationStage(
                        probeSessionId,
                        "region_decoder_open",
                        generationProbeClock() - openStartedAtMs,
                    ) { "mode=file_descriptor source=${decoder.width}x${decoder.height}" }
                    try {
                        return block(decoder)
                    } finally {
                        decoder.recycle()
                    }
                }
            } finally {
                it.close()
            }
        }

        var streamFailure: Exception? = null
        val input = try {
            resolver.openInputStream(uri)
        } catch (error: Exception) {
            streamFailure = error
            null
        }
        input?.buffered()?.use { buffered ->
            val decoder = try {
                BitmapRegionDecoder.newInstance(buffered, false)
            } catch (error: Exception) {
                streamFailure = error
                null
            }
            if (decoder != null) {
                recordGenerationStage(
                    probeSessionId,
                    "region_decoder_open",
                    generationProbeClock() - openStartedAtMs,
                ) { "mode=buffered_stream source=${decoder.width}x${decoder.height}" }
                try {
                    return block(decoder)
                } finally {
                    decoder.recycle()
                }
            }
        }

        // Last compatibility path: materialize the provider stream in private cache, then region
        // decode that seekable file. This is slower but keeps the same bounded-memory behaviour.
        val temporary = File.createTempFile("frame_source_", ".img", context.cacheDir)
        try {
            val materializeStartedAtMs = generationProbeClock()
            try {
                resolver.openInputStream(uri)?.use { source ->
                    temporary.outputStream().buffered().use { target ->
                        source.copyTo(target, COPY_BUFFER_BYTES)
                    }
                } ?: error("Cannot reopen source photo")
            } catch (error: Exception) {
                descriptorFailure?.let(error::addSuppressed)
                streamFailure?.let(error::addSuppressed)
                throw RegionDecodeUnavailableException(error)
            }
            recordGenerationStage(
                probeSessionId,
                "source_materialize",
                generationProbeClock() - materializeStartedAtMs,
            ) { "bytes=${temporary.length()}" }
            val decoder = try {
                BitmapRegionDecoder.newInstance(temporary.absolutePath, false)
            } catch (error: Exception) {
                descriptorFailure?.let(error::addSuppressed)
                streamFailure?.let(error::addSuppressed)
                throw RegionDecodeUnavailableException(error)
            }
            recordGenerationStage(
                probeSessionId,
                "region_decoder_open",
                generationProbeClock() - openStartedAtMs,
            ) { "mode=private_cache source=${decoder.width}x${decoder.height}" }
            try {
                return block(decoder)
            } finally {
                decoder.recycle()
            }
        } finally {
            if (!temporary.delete()) {
                Log.w(PHOTO_FRAME_EXPORT_TAG, "Cannot remove temporary region source")
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun decodeRegionPreview(
        decoder: BitmapRegionDecoder,
        orientation: Int,
        longEdge: Int,
    ): Bitmap {
        var sample = 1
        while (maxOf(decoder.width / sample, decoder.height / sample) > longEdge) sample *= 2
        val preview = decoder.decodeRegion(
            Rect(0, 0, decoder.width, decoder.height),
            BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
                inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
            },
        ) ?: error("Cannot decode source preview")
        return applyExifOrientation(preview, orientation)
    }

    @Suppress("DEPRECATION")
    private suspend fun drawPhotoRegions(
        decoder: BitmapRegionDecoder,
        canvas: Canvas,
        photoRect: RectF,
        orientation: Int,
        filter: PhotoFilterSelection?,
        probeSessionId: Long,
    ) {
        val rowsPerRegion = photoFrameRegionRows(decoder.width)
        val paint = Paint(Paint.DITHER_FLAG)
        val filterScratch = filter?.let {
            IntArray(PhotoFilterRenderer.scratchPixelCount(decoder.width, minOf(rowsPerRegion, decoder.height)))
        }
        val renderContext = currentCoroutineContext()
        val isRenderCancelled = { !renderContext.isActive }
        val filterPreparationStartedAtMs = generationProbeClock()
        val preparedFilter = filter?.let {
            PhotoFilterRenderer.prepareOriginalFilter(it, isRenderCancelled)
        }
        preparedFilter?.let { prepared ->
            recordGenerationStage(
                probeSessionId,
                "filter_lookup_prepare",
                generationProbeClock() - filterPreparationStartedAtMs,
            ) { "mode=${prepared.mode.name} kernel=${prepared.cubeExecution.label} grid=${prepared.cubeMapper?.gridSize ?: 0}" }
        }
        val sourceTriangle = FloatArray(6)
        val destinationTriangle = FloatArray(6)
        val orientationMatrix = Matrix()
        val destinationRect = RectF()
        var regionCount = 0
        var decodeElapsedMs = 0L
        var filterElapsedMs = 0L
        var drawElapsedMs = 0L
        val decodeSamplesMs = if (PhotoGenerationProbe.enabled) arrayListOf<Long>() else null
        val filterSamplesMs = if (PhotoGenerationProbe.enabled && filter != null) {
            arrayListOf<Long>()
        } else {
            null
        }
        var rawTop = 0
        while (rawTop < decoder.height) {
            currentCoroutineContext().ensureActive()
            val rawBottom = minOf(decoder.height, rawTop + rowsPerRegion)
            val rawRegion = Rect(0, rawTop, decoder.width, rawBottom)
            val decodeStartedAtMs = generationProbeClock()
            var tile = decoder.decodeRegion(
                rawRegion,
                BitmapFactory.Options().apply {
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                    inMutable = filter != null
                    inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
                },
            ) ?: error("Cannot decode source photo region")
            val regionDecodeMs = generationProbeClock() - decodeStartedAtMs
            decodeElapsedMs += regionDecodeMs
            decodeSamplesMs?.add(regionDecodeMs)
            regionCount++
            try {
                if (preparedFilter != null) {
                    val filterStartedAtMs = generationProbeClock()
                    if (!tile.isMutable) {
                        val mutable = tile.copy(Bitmap.Config.ARGB_8888, true)
                            ?: error("Cannot create mutable photo region")
                        tile.recycle()
                        tile = mutable
                    }
                    // Only this source-photo region is filtered. No frame pixel exists yet here.
                    PhotoFilterRenderer.renderInPlace(
                        source = tile,
                        prepared = preparedFilter,
                        isCancelled = isRenderCancelled,
                        scratchPixels = filterScratch,
                    )
                    val regionFilterMs = generationProbeClock() - filterStartedAtMs
                    filterElapsedMs += regionFilterMs
                    filterSamplesMs?.add(regionFilterMs)
                }
                val drawStartedAtMs = generationProbeClock()
                val mapped = orientedRegionRect(
                    rawRegion = rawRegion,
                    rawWidth = decoder.width,
                    rawHeight = decoder.height,
                    orientation = orientation,
                )
                val orientedTileSize = orientedPhotoSize(tile.width, tile.height, orientation)
                check(
                    orientedTileSize.width == mapped.width() &&
                        orientedTileSize.height == mapped.height(),
                ) {
                    "Oriented photo region size mismatch"
                }
                destinationRect.set(
                    photoRect.left + mapped.left,
                    photoRect.top + mapped.top,
                    photoRect.left + mapped.right,
                    photoRect.top + mapped.bottom,
                )
                if (orientation == ExifInterface.ORIENTATION_NORMAL || orientation == 0) {
                    canvas.drawBitmap(tile, null, destinationRect, paint)
                } else {
                    sourceTriangle[0] = 0f
                    sourceTriangle[1] = 0f
                    sourceTriangle[2] = tile.width.toFloat()
                    sourceTriangle[3] = 0f
                    sourceTriangle[4] = 0f
                    sourceTriangle[5] = tile.height.toFloat()
                    fillOrientedTileDestinationTriangle(
                        left = destinationRect.left,
                        top = destinationRect.top,
                        right = destinationRect.right,
                        bottom = destinationRect.bottom,
                        orientation = orientation,
                        output = destinationTriangle,
                    )
                    check(
                        orientationMatrix.setPolyToPoly(
                            sourceTriangle,
                            0,
                            destinationTriangle,
                            0,
                            3,
                        ),
                    ) { "Cannot map oriented photo region" }
                    canvas.drawBitmap(tile, orientationMatrix, paint)
                }
                drawElapsedMs += generationProbeClock() - drawStartedAtMs
            } finally {
                if (!tile.isRecycled) tile.recycle()
            }
            rawTop = rawBottom
        }
        val pixelCount = decoder.width.toLong() * decoder.height
        recordGenerationStage(probeSessionId, "region_decode", decodeElapsedMs) {
            buildString {
                append("regions=$regionCount rows=$rowsPerRegion")
                append(" source=${decoder.width}x${decoder.height}")
                decodeSamplesMs?.let { append(" eachMs=${it.joinToString(",")}") }
            }
        }
        if (preparedFilter != null) {
            recordGenerationStage(probeSessionId, "filter_pixels", filterElapsedMs) {
                buildString {
                    append("pixels=$pixelCount regions=$regionCount")
                    filterSamplesMs?.let { append(" eachMs=${it.joinToString(",")}") }
                }
            }
        }
        recordGenerationStage(probeSessionId, "region_orient_draw", drawElapsedMs) {
            "regions=$regionCount orientation=$orientation mode=canvas_matrix"
        }
    }

    private fun drawEditorialFrame(
        context: Context,
        canvas: Canvas,
        source: Bitmap,
        backdropSource: Bitmap,
        layout: PhotoFrameLayout,
        preset: PhotoFramePreset,
        metadata: PhotoFrameMetadata,
        watermark: PhotoFrameWatermark,
        backdropSettings: PhotoFrameMetadataSettings,
    ) {
        drawEditorialFrameBase(
            canvas,
            if (preset == PhotoFramePreset.COLOR_ARCHIVE) source else backdropSource,
            layout,
            preset,
            backdropSettings,
        )
        val photo = layout.photoRect()
        val photoPaint = Paint(
            Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG or Paint.DITHER_FLAG
        )
        if (preset == PhotoFramePreset.COLOR_ARCHIVE || preset == PhotoFramePreset.PARAMETER_POSTER) {
            val radius = if (preset == PhotoFramePreset.PARAMETER_POSTER) {
                parameterPosterCornerRadius(layout)
            } else colorArchiveCornerRadius(layout)
            val clip = Path().apply {
                addRoundRect(photo, radius, radius, Path.Direction.CW)
            }
            canvas.save()
            canvas.clipPath(clip)
            canvas.drawBitmap(source, null, photo, photoPaint)
            canvas.restore()
        } else {
            canvas.drawBitmap(source, null, photo, photoPaint)
        }
        drawEditorialFrameDecoration(context, canvas, layout, preset, metadata, watermark)
    }

    /** Reference-inspired editorial frames share exact photo geometry in preview and export. */
    private fun drawEditorialFrameBase(
        canvas: Canvas,
        backdropSource: Bitmap?,
        layout: PhotoFrameLayout,
        preset: PhotoFramePreset,
        backdropSettings: PhotoFrameMetadataSettings,
    ) {
        require(preset.isEditorialFrame())
        val photo = layout.photoRect()
        when (preset) {
            PhotoFramePreset.CLASSIC_SIGNATURE -> canvas.drawColor(Color.rgb(253, 253, 252))
            PhotoFramePreset.GALLERY_MAT -> {
                canvas.drawColor(Color.rgb(254, 254, 253))
                val frameWidth = min(photo.width(), photo.height()) * 0.045f
                val outer = RectF(photo).apply { inset(-frameWidth, -frameWidth) }
                drawPhotoElevation(canvas, outer, 0f, PhotoFramePreset.MINIMAL)
                canvas.drawRect(outer, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = Color.rgb(7, 7, 8)
                })
            }
            PhotoFramePreset.COLOR_ARCHIVE -> {
                canvas.drawColor(Color.rgb(253, 253, 252))
                val radius = colorArchiveCornerRadius(layout)
                drawPhotoElevation(canvas, photo, radius, PhotoFramePreset.MINIMAL)
                drawColorArchivePalette(
                    canvas = canvas,
                    layout = layout,
                    source = requireNotNull(backdropSource) {
                        "Color archive needs a palette source"
                    },
                )
            }
            PhotoFramePreset.FILM_GALLERY -> {
                drawBackdrop(
                    canvas,
                    requireNotNull(backdropSource) { "Film gallery needs a backdrop source" },
                    preset,
                    backdropSettings,
                )
                canvas.drawRect(filmGalleryOuterRect(layout), Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = Color.rgb(13, 14, 16)
                })
            }
            PhotoFramePreset.PARAMETER_POSTER -> {
                drawBackdrop(canvas, requireNotNull(backdropSource), PhotoFramePreset.CINEMA, backdropSettings)
                drawPhotoElevation(canvas, photo, parameterPosterCornerRadius(layout), preset)
            }
            PhotoFramePreset.FILM_EDGE,
            PhotoFramePreset.FILM_NEGATIVE -> canvas.drawColor(Color.rgb(7, 7, 8))
            else -> error("Not an editorial frame")
        }
    }

    private fun drawEditorialFrameDecoration(
        context: Context,
        canvas: Canvas,
        layout: PhotoFrameLayout,
        preset: PhotoFramePreset,
        metadata: PhotoFrameMetadata,
        watermark: PhotoFrameWatermark,
    ) {
        require(preset.isEditorialFrame())
        val photo = layout.photoRect()
        drawPhotoWatermark(context, canvas, photo, preset, watermark.forEditorialPhoto(preset), min(layout.designWidth, layout.designHeight))
        when (preset) {
            PhotoFramePreset.FILM_GALLERY -> drawFilmStripDecoration(canvas, layout)
            PhotoFramePreset.FILM_EDGE -> drawFilmEdgeDecoration(canvas, layout, metadata)
            PhotoFramePreset.FILM_NEGATIVE -> drawFilmNegativeDecoration(canvas, layout, metadata)
            PhotoFramePreset.COLOR_ARCHIVE -> drawColorArchiveDecoration(canvas, layout)
            PhotoFramePreset.CLASSIC_SIGNATURE -> canvas.drawRect(photo, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE; strokeWidth = maxOf(1f, layout.designWidth * 0.0008f)
                color = Color.argb(35, 0, 0, 0)
            })
            else -> Unit
        }
        if (preset == PhotoFramePreset.PARAMETER_POSTER) drawParameterPosterMetadata(canvas, layout)
        else drawMeasuredFrameText(canvas, layout)
    }

    private fun drawFilmStripDecoration(
        canvas: Canvas,
        layout: PhotoFrameLayout,
    ) {
        val photo = layout.photoRect()
        val outer = filmGalleryOuterRect(layout)
        val unit = photo.width()
        val holeWidth = unit * 0.025f
        val holeHeight = unit * 0.040f
        val gap = unit * 0.025f
        val count = ((outer.width() - gap) / (holeWidth + gap)).toInt().coerceAtLeast(3)
        val occupied = count * holeWidth + (count - 1) * gap
        val startX = outer.centerX() - occupied / 2f
        val holePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(55, 55, 61) }
        repeat(count) { index ->
            val left = startX + index * (holeWidth + gap)
            canvas.drawRoundRect(
                RectF(
                    left,
                    photo.top - holeHeight - unit * 0.008f,
                    left + holeWidth,
                    photo.top - unit * 0.008f,
                ),
                holeWidth * 0.34f,
                holeWidth * 0.34f,
                holePaint,
            )
            canvas.drawRoundRect(
                RectF(
                    left,
                    photo.bottom + unit * 0.008f,
                    left + holeWidth,
                    photo.bottom + holeHeight + unit * 0.008f,
                ),
                holeWidth * 0.34f,
                holeWidth * 0.34f,
                holePaint,
            )
        }
        val filmTextColor = Color.rgb(184, 132, 99)
        val labelPaint = fittedEditorialPaint(
            text = "2",
            preferredSize = unit * 0.021f,
            maxWidth = unit * 0.04f,
            color = filmTextColor,
            typeface = Typeface.create("sans-serif", Typeface.BOLD),
        ).apply { textAlign = Paint.Align.LEFT }
        canvas.drawText("2", outer.left + unit * 0.018f, outer.top + unit * 0.028f, labelPaint)
        val triangleX = outer.right - unit * 0.14f
        val triangleY = outer.top + unit * 0.020f
        canvas.drawPath(Path().apply {
            moveTo(triangleX, triangleY - unit * 0.010f)
            lineTo(triangleX + unit * 0.022f, triangleY)
            lineTo(triangleX, triangleY + unit * 0.010f)
            close()
        }, labelPaint)
    }

    private fun drawFilmEdgeDecoration(
        canvas: Canvas,
        layout: PhotoFrameLayout,
        metadata: PhotoFrameMetadata,
    ) {
        val photo = layout.photoRect()
        val sidePaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
            color = Color.rgb(221, 166, 119)
            textSize = photo.width() * 0.028f
            typeface = Typeface.create("sans-serif", Typeface.BOLD)
            textAlign = Paint.Align.CENTER
        }
        // Center the glyph ink, not its baseline, in the narrowed side strip.
        val leftX = layout.photoLeft * 0.5f
        val sideBaselineOffset = -(sidePaint.ascent() + sidePaint.descent()) / 2f
        canvas.save()
        canvas.rotate(-90f, leftX, photo.centerY())
        canvas.drawText("PORTRA 400", leftX, photo.centerY() + sideBaselineOffset, sidePaint)
        canvas.restore()
        val rightX = photo.right + (layout.canvasWidth - photo.right) * 0.5f
        val rightY = photo.top + photo.height() * 0.22f
        canvas.save()
        canvas.rotate(90f, rightX, rightY)
        canvas.drawText(
            "▶  %03d".format(Locale.ROOT, filmFrameNumber(metadata)),
            rightX,
            rightY + sideBaselineOffset,
            sidePaint,
        )
        canvas.restore()

    }

    /** Warm contact-sheet marks on a restrained black negative border. */
    private fun drawFilmNegativeDecoration(
        canvas: Canvas,
        layout: PhotoFrameLayout,
        metadata: PhotoFrameMetadata,
    ) {
        val photo = layout.photoRect()
        val unit = photo.width()
        val ink = Color.rgb(238, 173, 117)
        val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(130, 238, 173, 117)
            style = Paint.Style.STROKE
            strokeWidth = unit * 0.0012f
        }
        canvas.drawLine(0f, photo.top - unit * 0.018f, layout.canvasWidth.toFloat(), photo.top - unit * 0.018f, linePaint)
        canvas.drawLine(0f, photo.bottom + unit * 0.018f, layout.canvasWidth.toFloat(), photo.bottom + unit * 0.018f, linePaint)

        val brand = normalizeCameraMake(metadata.make)
        val model = normalizeCameraModel(metadata.make, metadata.model)
        val identity = listOf(brand, model)
            .filter(String::isNotBlank)
            .joinToString(" · ")
        val labelPaint = fittedEditorialPaint(
            text = identity,
            preferredSize = unit * 0.021f,
            maxWidth = unit * 0.46f,
            color = ink,
            typeface = Typeface.create("monospace", Typeface.BOLD),
        )
        if (identity.isNotBlank()) {
            labelPaint.textAlign = Paint.Align.LEFT
            canvas.drawText(identity, unit * 0.028f, photo.top * 0.58f, labelPaint)
        }
        val frameNumber = filmFrameNumber(metadata)
        val frameLabel = "FRAME %03d".format(Locale.ROOT, frameNumber)
        val framePaint = fittedEditorialPaint(
            text = frameLabel,
            preferredSize = unit * 0.021f,
            maxWidth = unit * 0.26f,
            color = ink,
            typeface = Typeface.create("monospace", Typeface.BOLD),
        ).apply { textAlign = Paint.Align.RIGHT }
        canvas.drawText(frameLabel, layout.canvasWidth - unit * 0.028f, photo.top * 0.58f, framePaint)

        val markPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(224, 145, 91) }
        val markWidth = unit * 0.018f
        val markHeight = unit * 0.028f
        val markGap = unit * 0.014f
        val markTop = photo.bottom + unit * 0.035f
        val count = ((layout.canvasWidth - markGap) / (markWidth + markGap)).toInt().coerceAtLeast(6)
        val occupied = count * markWidth + (count - 1) * markGap
        val start = (layout.canvasWidth - occupied) / 2f
        repeat(count) { index ->
            val left = start + index * (markWidth + markGap)
        canvas.drawRoundRect(
                RectF(left, markTop, left + markWidth, markTop + markHeight),
                markWidth * 0.28f,
                markWidth * 0.28f,
                markPaint,
            )
        }
    }

    /** Stable per-photo decorative number shared by all film-style borders. */
    private fun filmFrameNumber(metadata: PhotoFrameMetadata): Int =
        (((listOfNotNull(metadata.dateTime, metadata.make, metadata.model,
            metadata.lensModel, metadata.focalLength, metadata.iso, metadata.shutter)
            .joinToString("\u0000").hashCode() and Int.MAX_VALUE) % 999) + 1)

    private fun fittedEditorialPaint(
        text: String,
        preferredSize: Float,
        maxWidth: Float,
        color: Int,
        typeface: Typeface,
    ): Paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
        this.color = color
        textSize = preferredSize
        textAlign = Paint.Align.CENTER
        this.typeface = typeface
        val measured = measureText(text)
        if (measured > maxWidth && measured > 0f) textSize *= maxWidth / measured
    }

    private fun classicSignatureDetailLine(metadata: PhotoFrameMetadata): String =
        listOfNotNull(
            metadata.focalLength?.let { value ->
                if (value.startsWith("FL", ignoreCase = true)) value else "FL $value"
            },
            metadata.aperture?.let { "Aperture $it" },
            metadata.shutter?.let { "Shutter ${it.removeSuffix("s")}" },
            metadata.iso?.let { value ->
                if (value.startsWith("ISO", ignoreCase = true)) value else "ISO $value"
            },
        ).joinToString("   ")

    private fun drawColorArchiveDecoration(
        canvas: Canvas,
        layout: PhotoFrameLayout,
    ) {
        val photo = layout.photoRect()
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(28, 20, 24, 28)
            style = Paint.Style.STROKE
            strokeWidth = maxOf(1f, photo.width() * 0.0008f)
            canvas.drawRoundRect(
                photo,
                colorArchiveCornerRadius(layout),
                colorArchiveCornerRadius(layout),
                this,
            )
        }
    }

    private fun colorArchiveDetailLine(metadata: PhotoFrameMetadata): String =
        listOfNotNull(
            metadata.focalLength,
            metadata.aperture?.let { value ->
                when {
                    value.startsWith("f/", ignoreCase = true) -> value.lowercase(Locale.ROOT)
                    value.startsWith("f", ignoreCase = true) ->
                        "f/${value.drop(1).trimStart('/', ' ')}"
                    else -> "f/$value"
                }
            },
            metadata.iso?.replace(" ", "")?.uppercase(Locale.ROOT),
            metadata.shutter?.let { value ->
                if (value.endsWith("s", ignoreCase = true)) value else "${value}s"
            },
        ).joinToString("  ")

    private fun drawColorArchivePalette(
        canvas: Canvas,
        layout: PhotoFrameLayout,
        source: Bitmap,
    ) {
        val area = colorArchivePaletteRect(layout)
        val colors = extractColorArchivePalette(source)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val swatchWidth = area.width() / colors.size
        colors.forEachIndexed { index, color ->
            paint.color = color
            canvas.drawRect(
                area.left + index * swatchWidth,
                area.top,
                if (index == colors.lastIndex) area.right else area.left + (index + 1) * swatchWidth,
                area.bottom,
                paint,
            )
        }
    }

    private fun extractColorArchivePalette(source: Bitmap): IntArray {
        val counts = IntArray(512)
        val redSums = IntArray(512)
        val greenSums = IntArray(512)
        val blueSums = IntArray(512)
        val columns = 24
        val rows = 16
        repeat(rows) { row ->
            val y = ((row + 0.5f) * source.height / rows)
                .toInt().coerceIn(0, source.height - 1)
            repeat(columns) columnLoop@ { column ->
                val x = ((column + 0.5f) * source.width / columns)
                    .toInt().coerceIn(0, source.width - 1)
                val pixel = runCatching { source.getPixel(x, y) }.getOrNull()
                    ?: return@columnLoop
                if ((pixel ushr 24) < 128) return@columnLoop
                val red = pixel ushr 16 and 0xff
                val green = pixel ushr 8 and 0xff
                val blue = pixel and 0xff
                val bucket = (red ushr 5 shl 6) or (green ushr 5 shl 3) or (blue ushr 5)
                counts[bucket] += 1
                redSums[bucket] += red
                greenSums[bucket] += green
                blueSums[bucket] += blue
            }
        }
        val candidates = counts.indices
            .filter { counts[it] > 0 }
            .sortedByDescending { counts[it] }
            .map { bucket ->
                val count = counts[bucket]
                Color.rgb(
                    redSums[bucket] / count,
                    greenSums[bucket] / count,
                    blueSums[bucket] / count,
                )
            }
        val selected = mutableListOf<Int>()
        candidates.forEach { candidate ->
            if (selected.size == 4) return@forEach
            if (selected.all { existing -> colorDistanceSquared(candidate, existing) >= 42 * 42 }) {
                selected += candidate
            }
        }
        candidates.forEach { candidate ->
            if (selected.size == 4) return@forEach
            if (candidate !in selected) selected += candidate
        }
        COLOR_ARCHIVE_FALLBACK_PALETTE.forEach { fallback ->
            if (selected.size < 4) selected += fallback
        }
        val sorted = selected.take(4).sortedBy(::colorArchiveLuminance)
        return intArrayOf(sorted[0], sorted[1], sorted[3], sorted[2])
    }

    private fun colorDistanceSquared(first: Int, second: Int): Int {
        val red = (first ushr 16 and 0xff) - (second ushr 16 and 0xff)
        val green = (first ushr 8 and 0xff) - (second ushr 8 and 0xff)
        val blue = (first and 0xff) - (second and 0xff)
        return red * red + green * green + blue * blue
    }

    private fun colorArchiveLuminance(color: Int): Int =
        (color ushr 16 and 0xff) * 299 +
            (color ushr 8 and 0xff) * 587 +
            (color and 0xff) * 114

    private fun colorArchivePaletteRect(layout: PhotoFrameLayout): RectF {
        val photo = layout.photoRect()
        val bandHeight = layout.canvasHeight - photo.bottom
        val right = photo.right - photo.width() * 0.018f
        val width = photo.width() * 0.23f
        val height = photo.width() * 0.038f
        val centerY = photo.bottom + bandHeight * 0.5f
        return RectF(right - width, centerY - height / 2f, right, centerY + height / 2f)
    }

    private fun colorArchiveCornerRadius(layout: PhotoFrameLayout): Float =
        layout.photoRect().width() * 0.012f

    private fun filmGalleryOuterRect(layout: PhotoFrameLayout): RectF {
        val photo = layout.photoRect()
        val horizontal = photo.width() * 0.018f
        val bar = photo.width() * FILM_GALLERY_BAR_TO_PHOTO_WIDTH
        return RectF(
            photo.left - horizontal,
            photo.top - bar,
            photo.right + horizontal,
            photo.bottom + bar,
        )
    }

    private fun drawBrandFrame(
        context: Context,
        canvas: Canvas,
        source: Bitmap,
        layout: PhotoFrameLayout,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
    ) {
        drawBrandFrameBase(canvas, layout)
        val photoRect = layout.photoRect()
        val radius = brandFrameCornerRadius(layout)
        val clip = Path().apply {
            addRoundRect(photoRect, radius, radius, Path.Direction.CW)
        }
        canvas.save()
        canvas.clipPath(clip)
        canvas.drawBitmap(
            source,
            null,
            photoRect,
            Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG or Paint.DITHER_FLAG),
        )
        canvas.restore()
        drawBrandFrameDecoration(context, canvas, layout, preset, watermark)
    }

    private fun drawBrandFrameBase(canvas: Canvas, layout: PhotoFrameLayout) {
        canvas.drawColor(Color.rgb(253, 253, 252))
        drawPhotoElevation(
            canvas = canvas,
            photoRect = layout.photoRect(),
            radius = brandFrameCornerRadius(layout),
            preset = PhotoFramePreset.MINIMAL,
        )
    }

    /** Frame graphics are composited after the photo, so filters never alter typography. */
    private fun drawBrandFrameDecoration(
        context: Context,
        canvas: Canvas,
        layout: PhotoFrameLayout,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
    ) {
        require(preset.isBrandFrame())
        val photoRect = layout.photoRect()
        val radius = brandFrameCornerRadius(layout)
        val photoWatermark = watermark.forBrandPhoto(preset)
        val photoWatermarkLayout = layoutPhotoWatermark(
            context = context,
            canvas = canvas,
            photoRect = photoRect,
            preset = preset,
            watermark = photoWatermark,
            referenceShortEdge = min(layout.designWidth, layout.designHeight),
        )
        canvas.save()
        canvas.clipPath(Path().apply {
            addRoundRect(photoRect, radius, radius, Path.Direction.CW)
        })
        val save = canvas.save()
        canvas.translate(photoRect.left, photoRect.top)
        drawMeasuredText(canvas, checkNotNull(layout.photoTextLayout), photoRect.width() / 1000f) {
            error("Photo information cannot contain a band watermark")
        }
        canvas.restoreToCount(save)
        photoWatermarkLayout?.let { drawPhotoWatermarkLayout(canvas, it) }
        canvas.restore()

        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = maxOf(1f, layout.designWidth * 0.001f)
            color = Color.argb(46, 15, 20, 24)
            canvas.drawRoundRect(photoRect, radius, radius, this)
        }
        if (preset == PhotoFramePreset.BRAND_GALLERY) {
            drawMeasuredFrameText(canvas, layout)
        }
    }

    private fun fittedBrandPaint(
        text: String,
        preferredSize: Float,
        maxWidth: Float,
        color: Int,
    ): Paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
        this.color = color
        textSize = preferredSize
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create("sans-serif-black", Typeface.BOLD)
        val measured = measureText(text)
        if (measured > maxWidth && measured > 0f) textSize *= maxWidth / measured
    }

    private fun fittedBrandDetailPaint(
        text: String,
        preferredSize: Float,
        maxWidth: Float,
    ): Paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
        color = Color.rgb(249, 250, 251)
        textSize = preferredSize
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create("sans-serif-condensed", Typeface.BOLD_ITALIC)
        setShadowLayer(textSize * 0.12f, 0f, textSize * 0.06f, Color.argb(195, 0, 0, 0))
        val measured = measureText(text)
        if (measured > maxWidth && measured > 0f) textSize *= maxWidth / measured
    }

    /**
     * “铭牌”预设严格沿用参考图的结构：照片无裁切铺满宽度，底部接一整条白色信息带。
     * 横图查看时出现的上下黑区属于图库查看器，不写进导出文件。
     */
    private fun drawPlaqueFrame(
        context: Context,
        canvas: Canvas,
        source: Bitmap,
        layout: PhotoFrameLayout,
        watermark: PhotoFrameWatermark,
    ) {
        canvas.drawColor(Color.WHITE)
        val photoRect = RectF(
            layout.photoLeft,
            layout.photoTop,
            layout.photoRight,
            layout.photoBottom,
        )
        canvas.drawBitmap(
            source,
            null,
            photoRect,
            Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG or Paint.DITHER_FLAG),
        )
        drawPlaqueDecoration(context, canvas, layout, watermark)
    }

    /** Drawn after the photo layer, so neither the plaque band nor its text/watermark is filtered. */
    private fun drawPlaqueDecoration(
        context: Context,
        canvas: Canvas,
        layout: PhotoFrameLayout,
        watermark: PhotoFrameWatermark,
    ) {
        val photoRect = RectF(
            layout.photoLeft,
            layout.photoTop,
            layout.photoRight,
            layout.photoBottom,
        )
        drawPhotoWatermark(context, canvas, photoRect, PhotoFramePreset.PLAQUE, watermark, min(layout.designWidth, layout.designHeight))

        val width = layout.canvasWidth.toFloat()
        val bandTop = layout.metadataTop
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(253, 253, 252)
            canvas.drawRect(0f, bandTop, width, layout.canvasHeight.toFloat(), this)
            color = Color.rgb(232, 233, 231)
            canvas.drawRect(
                0f,
                bandTop,
                width,
                bandTop + maxOf(1f, width * 0.0008f),
                this,
            )
        }

        if (layout.textLayout != null) {
            val scale = layout.textLayoutScale
            val items = layout.textLayout.items
            val leftItems = items.filter { it.x < 575f }
            val rightItems = items.filter { it.x >= 575f && it.run.watermark == null }
            if (leftItems.isNotEmpty() && rightItems.isNotEmpty()) {
                val info = leftItems + rightItems
                val infoTop = info.minOf { it.baseline + it.run.bounds.top } * scale
                val infoBottom = info.maxOf { it.baseline + it.run.bounds.bottom } * scale
                canvas.drawLine(575f * scale, infoTop, 575f * scale, infoBottom,
                    Paint(Paint.ANTI_ALIAS_FLAG).apply {
                        color = Color.rgb(222, 224, 222)
                        strokeWidth = maxOf(1f, width * 0.001f)
                    })
            }
            drawMeasuredFrameText(canvas, layout)
            return
        }

        error("Plaque requires its measured layout")
    }

    private suspend fun saveRenderedToMediaStore(
        resolver: ContentResolver,
        source: PhotoFrameMediaStoreSource,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        borderEnabled: Boolean,
        metadataSettings: PhotoFrameMetadataSettings,
        filter: PhotoFilterSelection?,
        bitmap: Bitmap,
    ): PhotoFrameExportResult {
        val preferred = photoFrameOutputName(
            source.displayName,
            preset,
            watermark,
            borderEnabled = borderEnabled,
            metadataSettings = metadataSettings,
            filter = filter,
        )
        val name = uniqueName(preferred, source.occupiedNames)
        val originalPath = source.relativePath
        val canTryOriginal = originalPath != null && canCreateDerivedImageInOriginalPath(
            relativePath = originalPath,
            hasRelatedMediaUri = source.relatedMediaUri != null,
            sdkInt = Build.VERSION.SDK_INT,
        )
        var originalFailure: Exception? = null
        if (canTryOriginal) {
            try {
                return writeRenderedToMediaStore(
                    resolver = resolver,
                    // Keep the picker-granted URI for EXIF copying.  The related MediaStore URI
                    // is useful for placement, but may expose a redacted descriptor.
                    sourceUri = source.sourceUri,
                    collectionUri = source.collectionUri,
                    relativePath = checkNotNull(originalPath),
                    relatedMediaUri = source.relatedMediaUri,
                    name = name,
                    bitmap = bitmap,
                    occupiedNames = source.occupiedNames,
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                originalFailure = error
                Log.w(
                    PHOTO_FRAME_EXPORT_TAG,
                    "Cannot save beside source; falling back to $LOCAL_PHOTO_FALLBACK_RELATIVE_PATH " +
                        "(path=$originalPath, volume=${source.collectionUri}, " +
                        "error=${error.javaClass.simpleName}: ${error.message})",
                )
            }
        } else if (originalPath != null) {
            Log.w(
                PHOTO_FRAME_EXPORT_TAG,
                "Source album is not directly writable; using " +
                    "$LOCAL_PHOTO_FALLBACK_RELATIVE_PATH (path=$originalPath)",
            )
        }
        if (
            originalPath.equals(LOCAL_PHOTO_FALLBACK_RELATIVE_PATH, ignoreCase = true) &&
            source.collectionUri == source.fallbackCollectionUri
        ) {
            throw originalFailure ?: IllegalStateException("Cannot write to the fallback album")
        }
        return try {
            writeRenderedToMediaStore(
                resolver = resolver,
                sourceUri = source.sourceUri,
                collectionUri = source.fallbackCollectionUri,
                relativePath = LOCAL_PHOTO_FALLBACK_RELATIVE_PATH,
                relatedMediaUri = null,
                name = name,
                bitmap = bitmap,
                occupiedNames = source.occupiedNames,
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (fallbackFailure: Exception) {
            originalFailure?.let(fallbackFailure::addSuppressed)
            throw fallbackFailure
        }
    }

    private suspend fun writeRenderedToMediaStore(
        resolver: ContentResolver,
        sourceUri: Uri,
        collectionUri: Uri,
        relativePath: String,
        relatedMediaUri: Uri?,
        name: String,
        bitmap: Bitmap,
        occupiedNames: MutableSet<String>,
    ): PhotoFrameExportResult {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val target = if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && relatedMediaUri != null &&
            !isStandardImageRelativePath(relativePath)
        ) {
            resolver.insert(
                collectionUri,
                values,
                Bundle().apply {
                    putParcelable(MediaStore.QUERY_ARG_RELATED_URI, relatedMediaUri)
                },
            )
        } else {
            resolver.insert(collectionUri, values)
        }
            ?: error("Cannot create derived photo")
        var keepTarget = false
        try {
            val written = resolver.openOutputStream(target, "w")?.let { raw ->
                BufferedOutputStream(raw, COPY_BUFFER_BYTES).use { output ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, PHOTO_FRAME_JPEG_QUALITY, output)
                }
            } == true
            if (!written) error("Cannot write derived photo")
            copyRenderedExif(
                resolver = resolver,
                sourceUri = sourceUri,
                targetUri = target,
                width = bitmap.width,
                height = bitmap.height,
            )
            currentCoroutineContext().ensureActive()
            val published = resolver.update(
                target,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null,
                null,
            )
            if (published <= 0) error("Cannot publish derived photo")
            keepTarget = true
            val publishedName = displayNameOf(resolver, target) ?: name
            occupiedNames.add(publishedName)
            return PhotoFrameExportResult(
                displayName = publishedName,
                relativePath = relativePath,
            )
        } finally {
            if (!keepTarget) runCatching { resolver.delete(target, null, null) }
        }
    }

    private suspend fun saveRendered(
        resolver: ContentResolver,
        destination: PhotoFrameDestination,
        sourceUri: Uri,
        sourceName: String,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        borderEnabled: Boolean,
        metadataSettings: PhotoFrameMetadataSettings,
        filter: PhotoFilterSelection?,
        bitmap: Bitmap,
        probeSessionId: Long,
        cameraMetadata: PhotoFrameMetadata? = null,
    ): PhotoFrameExportResult {
        val parentUri = destination.directoryUri
        val preferred = photoFrameOutputName(
            sourceName,
            preset,
            watermark,
            borderEnabled = borderEnabled,
            metadataSettings = metadataSettings,
            filter = filter,
        )
        // Reserve before touching the provider so concurrent exporters never select the same name.
        val name = reservePhotoFrameName(preferred, destination.occupiedNames)
        val tempName = photoFrameTempName(System.nanoTime())
        val createStartedAtMs = generationProbeClock()
        val temp = try {
            DocumentsContract.createDocument(
                resolver,
                parentUri,
                "image/jpeg",
                tempName,
            ) ?: error("Cannot create derived photo")
        } catch (error: Throwable) {
            destination.occupiedNames.remove(name)
            throw error
        }
        recordGenerationStage(
            probeSessionId,
            "output_create",
            generationProbeClock() - createStartedAtMs,
        )
        var tempStillExists = true
        var keepReservedName = false
        try {
            val jpegStartedAtMs = generationProbeClock()
            val written = resolver.openOutputStream(temp, "w")?.let { raw ->
                BufferedOutputStream(raw, COPY_BUFFER_BYTES).use { output ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, PHOTO_FRAME_JPEG_QUALITY, output)
                }
            } == true
            if (!written) error("Cannot write derived photo")
            recordGenerationStage(
                probeSessionId,
                "jpeg_encode_write",
                generationProbeClock() - jpegStartedAtMs,
            ) { "${bitmap.width}x${bitmap.height} q=$PHOTO_FRAME_JPEG_QUALITY" }
            val exifStartedAtMs = generationProbeClock()
            copyRenderedExif(
                resolver = resolver,
                sourceUri = sourceUri,
                targetUri = temp,
                width = bitmap.width,
                height = bitmap.height,
                cameraMetadata = cameraMetadata,
            )
            recordGenerationStage(
                probeSessionId,
                "exif_rewrite",
                generationProbeClock() - exifStartedAtMs,
            )
            // 压缩是不可中断的阻塞调用；若界面已销毁，在正式改名前响应取消，仅清理隐藏临时文件。
            currentCoroutineContext().ensureActive()

            // 正常 DocumentsProvider 走原子改名：系统杀进程时最多遗留隐藏临时文件，
            // 不会让图库出现半张损坏 JPG。改名损坏的定制系统再走完整文件复制回退。
            val finalizeStartedAtMs = generationProbeClock()
            val renamed = try {
                DocumentsContract.renameDocument(resolver, temp, name)
            } catch (_: Exception) {
                null
            }
            if (renamed != null) {
                recordGenerationStage(
                    probeSessionId,
                    "output_finalize",
                    generationProbeClock() - finalizeStartedAtMs,
                ) { "mode=rename" }
                tempStillExists = false
                val result = PhotoFrameExportResult(
                    displayName = displayNameOf(resolver, renamed) ?: name,
                )
                destination.occupiedNames.add(result.displayName)
                keepReservedName = true
                return result
            }

            val copied = copyCompletedFrame(
                resolver = resolver,
                parentUri = parentUri,
                sourceUri = temp,
                requestedName = name,
            )
            recordGenerationStage(
                probeSessionId,
                "output_finalize",
                generationProbeClock() - finalizeStartedAtMs,
            ) { "mode=full_copy" }
            val result = PhotoFrameExportResult(
                displayName = displayNameOf(resolver, copied) ?: name,
            )
            destination.occupiedNames.add(result.displayName)
            keepReservedName = true
            return result
        } finally {
            if (tempStillExists) {
                runCatching { DocumentsContract.deleteDocument(resolver, temp) }
            }
            if (!keepReservedName) destination.occupiedNames.remove(name)
        }
    }

    /**
     * 少数 DocumentsProvider 不实现 renameDocument。临时文件已经完整封口后才创建
     * 正式文件并复制，且核对字节数；异常会删除正式副本，原片和完整临时文件均不受影响。
     */
    private suspend fun copyCompletedFrame(
        resolver: ContentResolver,
        parentUri: Uri,
        sourceUri: Uri,
        requestedName: String,
    ): Uri {
        var target: Uri? = null
        try {
            val expectedBytes = documentSizeOf(resolver, sourceUri)
            target = DocumentsContract.createDocument(
                resolver,
                parentUri,
                "image/jpeg",
                requestedName,
            ) ?: error("Cannot create derived photo")
            val input = resolver.openInputStream(sourceUri)
                ?: error("Cannot reopen completed frame")
            val copiedBytes = input.use { rawInput ->
                val output = resolver.openOutputStream(target, "w")
                    ?: error("Cannot write derived photo")
                output.use { rawOutput ->
                    BufferedInputStream(rawInput, COPY_BUFFER_BYTES).use { bufferedInput ->
                        BufferedOutputStream(rawOutput, COPY_BUFFER_BYTES).use { bufferedOutput ->
                            val buffer = ByteArray(COPY_BUFFER_BYTES)
                            var total = 0L
                            while (true) {
                                val read = bufferedInput.read(buffer)
                                if (read < 0) break
                                bufferedOutput.write(buffer, 0, read)
                                total += read
                                currentCoroutineContext().ensureActive()
                            }
                            total
                        }
                    }
                }
            }
            // 某些 Provider 在刚关闭输出流时会短暂报告 0；只把正数当作可信尺寸。
            if (expectedBytes > 0L && copiedBytes != expectedBytes) {
                error("Incomplete derived photo copy")
            }
            return target
        } catch (error: Throwable) {
            target?.let { runCatching { DocumentsContract.deleteDocument(resolver, it) } }
            throw error
        }
    }

    private fun documentSizeOf(resolver: ContentResolver, uri: Uri): Long =
        runCatching {
            resolver.query(
                uri,
                arrayOf(DocumentsContract.Document.COLUMN_SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                val column = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                if (column >= 0 && cursor.moveToFirst() && !cursor.isNull(column)) {
                    cursor.getLong(column)
                } else {
                    -1L
                }
            } ?: -1L
        }.getOrDefault(-1L)

    private fun displayNameOf(resolver: ContentResolver, uri: Uri): String? =
        runCatching {
            resolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameColumn >= 0 && cursor.moveToFirst()) cursor.getString(nameColumn) else null
            }
        }.getOrNull()
}

internal fun calculatePhotoFrameLayout(
    sourceWidth: Int,
    sourceHeight: Int,
    longEdge: Int = 3200,
): PhotoFrameLayout {
    require(sourceWidth > 0 && sourceHeight > 0)
    val sourceAspect = sourceWidth.toFloat() / sourceHeight
    // 常规照片沿用参考图的 4:3/3:4 成片，2:3 竖图保留匹配画布；
    // 方图与超宽/超长图单独适配，
    // 避免为了固定模板产生夸张空边，同时仍然完整保留原片、不裁切。
    val (canvasWidth, canvasHeight) = when {
        sourceAspect > 1.9f -> longEdge to longEdge * 9 / 16
        sourceAspect > 1.1f -> longEdge to longEdge * 3 / 4
        sourceAspect >= 0.9f -> longEdge to longEdge
        sourceAspect >= 0.72f -> longEdge * 3 / 4 to longEdge
        sourceAspect >= 0.56f -> longEdge * 2 / 3 to longEdge
        else -> longEdge * 9 / 16 to longEdge
    }
    val portrait = canvasHeight > canvasWidth
    val square = canvasHeight == canvasWidth
    val side = canvasWidth * 0.052f
    val top = canvasHeight * when {
        portrait -> 0.030f
        square -> 0.040f
        else -> 0.050f
    }
    val metadataTop = canvasHeight * when {
        portrait -> 0.900f
        square -> 0.870f
        else -> 0.830f
    }
    val availableWidth = canvasWidth - side * 2f
    val availableHeight = metadataTop - top - canvasHeight * 0.012f
    val scale = min(availableWidth / sourceWidth, availableHeight / sourceHeight)
    val photoWidth = sourceWidth * scale
    val photoHeight = sourceHeight * scale
    val left = (canvasWidth - photoWidth) / 2f
    val photoAreaCenterY = top + availableHeight / 2f
    val photoTop = photoAreaCenterY - photoHeight / 2f
    return PhotoFrameLayout(
        canvasWidth = canvasWidth,
        canvasHeight = canvasHeight,
        photoLeft = left,
        photoTop = photoTop,
        photoRight = left + photoWidth,
        photoBottom = photoTop + photoHeight,
        metadataTop = metadataTop,
    )
}

/**
 * Builds the decorative canvas around a 1:1 source-photo rectangle. The canvas grows until the
 * existing preset margins and metadata band can contain every original source pixel; it never
 * shrinks the photo to a fixed sharing resolution.
 */
internal fun calculateOriginalQualityPhotoFrameLayout(
    sourceWidth: Int,
    sourceHeight: Int,
): PhotoFrameLayout {
    require(sourceWidth > 0 && sourceHeight > 0)

    fun fits(longEdge: Int): Boolean {
        val layout = calculatePhotoFrameLayout(sourceWidth, sourceHeight, longEdge)
        return layout.photoRight - layout.photoLeft >= sourceWidth.toFloat() &&
            layout.photoBottom - layout.photoTop >= sourceHeight.toFloat()
    }

    var low = maxOf(sourceWidth, sourceHeight)
    var high = low
    while (!fits(high)) {
        check(high <= Int.MAX_VALUE / 2) { "Original photo is too large to frame" }
        high *= 2
    }
    while (low < high) {
        val middle = low + (high - low) / 2
        if (fits(middle)) high = middle else low = middle + 1
    }

    val base = calculatePhotoFrameLayout(sourceWidth, sourceHeight, low)
    val left = ((base.canvasWidth - sourceWidth) / 2f)
        .roundToInt()
        .coerceIn(0, base.canvasWidth - sourceWidth)
        .toFloat()
    val desiredTop = (
        (base.photoTop + base.photoBottom) / 2f - sourceHeight / 2f
        ).roundToInt()
    val maxTop = minOf(
        base.canvasHeight - sourceHeight,
        (base.metadataTop - sourceHeight).toInt(),
    ).coerceAtLeast(0)
    val top = desiredTop.coerceIn(0, maxTop).toFloat()
    return base.copy(
        photoLeft = left,
        photoTop = top,
        photoRight = left + sourceWidth,
        photoBottom = top + sourceHeight,
    )
}

/** The plaque adds its information band outside the original 1:1 photo rectangle. */
internal fun calculateOriginalQualityPlaqueLayout(
    sourceWidth: Int,
    sourceHeight: Int,
): PhotoFrameLayout {
    require(sourceWidth > 0 && sourceHeight > 0)
    val bandHeight = (sourceWidth * PLAQUE_BAND_TO_WIDTH).roundToInt().coerceAtLeast(1)
    check(sourceHeight <= Int.MAX_VALUE - bandHeight) { "Original photo is too large to frame" }
    return PhotoFrameLayout(
        canvasWidth = sourceWidth,
        canvasHeight = sourceHeight + bandHeight,
        photoLeft = 0f,
        photoTop = 0f,
        photoRight = sourceWidth.toFloat(),
        photoBottom = sourceHeight.toFloat(),
        metadataTop = sourceHeight.toFloat(),
    )
}

/**
 * “铭牌”不建立固定比例的装饰画布，只在原片下方增加宽度约 12% 的信息带。
 * 预览成片的长边限制在 [longEdge] 内；原品质导出使用独立的 1:1 布局函数。
 */
internal fun calculatePlaqueFrameLayout(
    sourceWidth: Int,
    sourceHeight: Int,
    longEdge: Int = 3200,
): PhotoFrameLayout {
    require(sourceWidth > 0 && sourceHeight > 0)
    require(longEdge > 0)
    val compositeHeight = sourceHeight + sourceWidth * PLAQUE_BAND_TO_WIDTH
    val scale = min(
        longEdge.toFloat() / sourceWidth,
        longEdge.toFloat() / compositeHeight,
    )
    val canvasWidth = (sourceWidth * scale).roundToInt().coerceAtLeast(1)
    val preferredBandHeight =
        (canvasWidth * PLAQUE_BAND_TO_WIDTH).roundToInt().coerceAtLeast(1)
    val photoHeight = (sourceHeight * scale).roundToInt()
        .coerceIn(1, maxOf(1, longEdge - preferredBandHeight))
    val canvasHeight = photoHeight + preferredBandHeight
    return PhotoFrameLayout(
        canvasWidth = canvasWidth,
        canvasHeight = canvasHeight,
        photoLeft = 0f,
        photoTop = 0f,
        photoRight = canvasWidth.toFloat(),
        photoBottom = photoHeight.toFloat(),
        metadataTop = photoHeight.toFloat(),
    )
}

/** Full-bleed output keeps the source aspect ratio and only caps its longest edge. */
internal fun calculateImmersiveFrameLayout(
    sourceWidth: Int,
    sourceHeight: Int,
    longEdge: Int = 3200,
): PhotoFrameLayout {
    require(sourceWidth > 0 && sourceHeight > 0)
    require(longEdge > 0)
    val scale = min(1f, longEdge.toFloat() / maxOf(sourceWidth, sourceHeight))
    val canvasWidth = (sourceWidth * scale).roundToInt().coerceAtLeast(1)
    val canvasHeight = (sourceHeight * scale).roundToInt().coerceAtLeast(1)
    return PhotoFrameLayout(
        canvasWidth = canvasWidth,
        canvasHeight = canvasHeight,
        photoLeft = 0f,
        photoTop = 0f,
        photoRight = canvasWidth.toFloat(),
        photoBottom = canvasHeight.toFloat(),
        metadataTop = canvasHeight.toFloat(),
    )
}

internal fun calculateBrandFrameLayout(
    sourceWidth: Int,
    sourceHeight: Int,
    preset: PhotoFramePreset,
    longEdge: Int = 3200,
): PhotoFrameLayout {
    require(sourceWidth > 0 && sourceHeight > 0)
    require(longEdge > 0)
    require(preset.isBrandFrame())
    val bottomRatio = when (preset) {
        PhotoFramePreset.BRAND_INSET -> BRAND_INSET_BOTTOM_TO_PHOTO_WIDTH
        PhotoFramePreset.BRAND_GALLERY -> BRAND_GALLERY_BOTTOM_TO_PHOTO_WIDTH
        else -> error("Not a brand frame")
    }
    val compositeWidth = sourceWidth * (1f + BRAND_FRAME_SIDE_TO_PHOTO_WIDTH * 2f)
    val compositeHeight = sourceHeight + sourceWidth *
        (BRAND_FRAME_SIDE_TO_PHOTO_WIDTH + bottomRatio)
    val scale = min(longEdge / compositeWidth, longEdge / compositeHeight)
    val photoWidth = (sourceWidth * scale).roundToInt().coerceAtLeast(1)
    val photoHeight = (sourceHeight * scale).roundToInt().coerceAtLeast(1)
    val side = (photoWidth * BRAND_FRAME_SIDE_TO_PHOTO_WIDTH).roundToInt().coerceAtLeast(1)
    val top = side
    val bottom = (photoWidth * bottomRatio).roundToInt().coerceAtLeast(1)
    val canvasWidth = photoWidth + side * 2
    val canvasHeight = photoHeight + top + bottom
    return PhotoFrameLayout(
        canvasWidth = canvasWidth,
        canvasHeight = canvasHeight,
        photoLeft = side.toFloat(),
        photoTop = top.toFloat(),
        photoRight = (side + photoWidth).toFloat(),
        photoBottom = (top + photoHeight).toFloat(),
        metadataTop = (top + photoHeight).toFloat(),
    )
}

internal fun calculateOriginalQualityBrandFrameLayout(
    sourceWidth: Int,
    sourceHeight: Int,
    preset: PhotoFramePreset,
): PhotoFrameLayout {
    require(sourceWidth > 0 && sourceHeight > 0)
    require(preset.isBrandFrame())
    val bottomRatio = when (preset) {
        PhotoFramePreset.BRAND_INSET -> BRAND_INSET_BOTTOM_TO_PHOTO_WIDTH
        PhotoFramePreset.BRAND_GALLERY -> BRAND_GALLERY_BOTTOM_TO_PHOTO_WIDTH
        else -> error("Not a brand frame")
    }
    val side = (sourceWidth * BRAND_FRAME_SIDE_TO_PHOTO_WIDTH)
        .roundToInt()
        .coerceAtLeast(1)
    val bottom = (sourceWidth * bottomRatio).roundToInt().coerceAtLeast(1)
    check(sourceWidth <= Int.MAX_VALUE - side * 2) { "Original photo is too large to frame" }
    check(sourceHeight <= Int.MAX_VALUE - side - bottom) {
        "Original photo is too large to frame"
    }
    return PhotoFrameLayout(
        canvasWidth = sourceWidth + side * 2,
        canvasHeight = sourceHeight + side + bottom,
        photoLeft = side.toFloat(),
        photoTop = side.toFloat(),
        photoRight = (side + sourceWidth).toFloat(),
        photoBottom = (side + sourceHeight).toFloat(),
        metadataTop = (side + sourceHeight).toFloat(),
    )
}

internal fun calculateEditorialFrameLayout(
    sourceWidth: Int,
    sourceHeight: Int,
    preset: PhotoFramePreset,
    longEdge: Int = 3200,
): PhotoFrameLayout {
    require(longEdge > 0)
    val original = calculateOriginalQualityEditorialFrameLayout(sourceWidth, sourceHeight, preset)
    val scale = longEdge.toFloat() / maxOf(original.canvasWidth, original.canvasHeight)
    fun scaled(value: Float): Float = value * scale
    val canvasWidth = (original.canvasWidth * scale).roundToInt().coerceAtLeast(1)
    val canvasHeight = (original.canvasHeight * scale).roundToInt().coerceAtLeast(1)
    return PhotoFrameLayout(
        canvasWidth = canvasWidth,
        canvasHeight = canvasHeight,
        photoLeft = scaled(original.photoLeft),
        photoTop = scaled(original.photoTop),
        photoRight = scaled(original.photoRight),
        photoBottom = scaled(original.photoBottom),
        metadataTop = scaled(original.metadataTop),
    )
}

/** Every editorial preset keeps the source rectangle at exactly 1:1 in original-quality export. */
internal fun calculateOriginalQualityEditorialFrameLayout(
    sourceWidth: Int,
    sourceHeight: Int,
    preset: PhotoFramePreset,
): PhotoFrameLayout {
    require(sourceWidth > 0 && sourceHeight > 0)
    require(preset.isEditorialFrame())
    fun px(ratio: Float): Int = (sourceWidth * ratio).roundToInt().coerceAtLeast(1)
    return when (preset) {
        PhotoFramePreset.PARAMETER_POSTER -> calculateOriginalParameterPosterLayout(sourceWidth, sourceHeight)
        PhotoFramePreset.CLASSIC_SIGNATURE -> {
            val side = px(CLASSIC_SIGNATURE_SIDE_TO_PHOTO_WIDTH)
            val top = px(CLASSIC_SIGNATURE_TOP_TO_PHOTO_WIDTH)
            val bottom = px(CLASSIC_SIGNATURE_BOTTOM_TO_PHOTO_WIDTH)
            PhotoFrameLayout(
                canvasWidth = sourceWidth + side * 2,
                canvasHeight = sourceHeight + top + bottom,
                photoLeft = side.toFloat(),
                photoTop = top.toFloat(),
                photoRight = (side + sourceWidth).toFloat(),
                photoBottom = (top + sourceHeight).toFloat(),
                metadataTop = (top + sourceHeight).toFloat(),
            )
        }
        PhotoFramePreset.GALLERY_MAT -> {
            val aspect = sourceWidth.toFloat() / sourceHeight
            val (widthFraction, heightFraction) = when {
                aspect > 1.08f -> 0.80f to 0.56f
                aspect < 0.92f -> 0.56f to 0.80f
                else -> 0.68f to 0.68f
            }
            val side = maxOf(
                sourceWidth / widthFraction,
                sourceHeight / heightFraction,
            ).roundToInt().coerceAtLeast(maxOf(sourceWidth, sourceHeight))
            val left = (side - sourceWidth) / 2f
            val top = (side - sourceHeight) * 0.45f
            PhotoFrameLayout(
                canvasWidth = side,
                canvasHeight = side,
                photoLeft = left,
                photoTop = top,
                photoRight = left + sourceWidth,
                photoBottom = top + sourceHeight,
                metadataTop = top + sourceHeight,
            )
        }
        PhotoFramePreset.COLOR_ARCHIVE -> {
            val side = px(COLOR_ARCHIVE_SIDE_TO_PHOTO_WIDTH)
            val top = px(COLOR_ARCHIVE_TOP_TO_PHOTO_WIDTH)
            val bottom = px(COLOR_ARCHIVE_BOTTOM_TO_PHOTO_WIDTH)
            PhotoFrameLayout(
                canvasWidth = sourceWidth + side * 2,
                canvasHeight = sourceHeight + top + bottom,
                photoLeft = side.toFloat(),
                photoTop = top.toFloat(),
                photoRight = (side + sourceWidth).toFloat(),
                photoBottom = (top + sourceHeight).toFloat(),
                metadataTop = (top + sourceHeight).toFloat(),
            )
        }
        PhotoFramePreset.FILM_GALLERY -> {
            val side = px(FILM_GALLERY_SIDE_TO_PHOTO_WIDTH)
            val top = px(FILM_GALLERY_TOP_TO_PHOTO_WIDTH)
            val bar = px(FILM_GALLERY_BAR_TO_PHOTO_WIDTH)
            val bottom = px(FILM_GALLERY_BOTTOM_TO_PHOTO_WIDTH)
            val photoTop = top + bar
            PhotoFrameLayout(
                canvasWidth = sourceWidth + side * 2,
                canvasHeight = sourceHeight + top + bar * 2 + bottom,
                photoLeft = side.toFloat(),
                photoTop = photoTop.toFloat(),
                photoRight = (side + sourceWidth).toFloat(),
                photoBottom = (photoTop + sourceHeight).toFloat(),
                metadataTop = (photoTop + sourceHeight + bar).toFloat(),
            )
        }
        PhotoFramePreset.FILM_EDGE -> {
            val side = px(FILM_EDGE_SIDE_TO_PHOTO_WIDTH)
            val top = px(FILM_EDGE_TOP_TO_PHOTO_WIDTH)
            val bottom = px(FILM_EDGE_BOTTOM_TO_PHOTO_WIDTH)
            PhotoFrameLayout(
                canvasWidth = sourceWidth + side * 2,
                canvasHeight = sourceHeight + top + bottom,
                photoLeft = side.toFloat(),
                photoTop = top.toFloat(),
                photoRight = (side + sourceWidth).toFloat(),
                photoBottom = (top + sourceHeight).toFloat(),
                metadataTop = (top + sourceHeight).toFloat(),
            )
        }
        PhotoFramePreset.FILM_NEGATIVE -> {
            val side = px(FILM_NEGATIVE_SIDE_TO_PHOTO_WIDTH)
            val top = px(FILM_NEGATIVE_TOP_TO_PHOTO_WIDTH)
            val bottom = px(FILM_NEGATIVE_BOTTOM_TO_PHOTO_WIDTH)
            PhotoFrameLayout(
                canvasWidth = sourceWidth + side * 2,
                canvasHeight = sourceHeight + top + bottom,
                photoLeft = side.toFloat(),
                photoTop = top.toFloat(),
                photoRight = (side + sourceWidth).toFloat(),
                photoBottom = (top + sourceHeight).toFloat(),
                metadataTop = (top + sourceHeight).toFloat(),
            )
        }
        else -> error("Not an editorial frame")
    }
}

internal fun PhotoFramePreset.isBrandFrame(): Boolean =
    this == PhotoFramePreset.BRAND_INSET || this == PhotoFramePreset.BRAND_GALLERY

internal fun PhotoFramePreset.isEditorialFrame(): Boolean = when (this) {
    PhotoFramePreset.CLASSIC_SIGNATURE,
    PhotoFramePreset.GALLERY_MAT,
    PhotoFramePreset.COLOR_ARCHIVE,
    PhotoFramePreset.FILM_GALLERY,
    PhotoFramePreset.FILM_EDGE,
    PhotoFramePreset.FILM_NEGATIVE,
    PhotoFramePreset.PARAMETER_POSTER -> true
    else -> false
}

/**
 * Places the brand/EXIF block at its intended lower-center position, moving it just above the
 * real rendered watermark bounds only when the two rectangles intersect. Watermarks placed in a
 * corner therefore do not cause unrelated metadata to jump, while large bottom/center watermarks
 * always receive an explicit safety gap.
 */
internal fun placeBrandMetadataBlock(
    photo: BrandFrameBounds,
    preferredBottom: Float,
    blockHeight: Float,
    blockWidth: Float,
    occupied: BrandFrameBounds?,
    gap: Float,
): BrandFrameBounds {
    require(photo.width > 0f && photo.height > 0f)
    require(blockHeight in 0f..photo.height)
    require(blockWidth > 0f)
    require(gap >= 0f)

    val width = blockWidth.coerceAtMost(photo.width)
    val left = photo.left + (photo.width - width) / 2f
    fun blockEndingAt(bottom: Float): BrandFrameBounds {
        val clampedBottom = bottom.coerceIn(photo.top + blockHeight, photo.bottom)
        return BrandFrameBounds(left, clampedBottom - blockHeight, left + width, clampedBottom)
    }

    val preferred = blockEndingAt(preferredBottom)
    if (occupied == null || !preferred.intersects(occupied)) return preferred

    val above = blockEndingAt(occupied.top - gap)
    if (above.top >= photo.top && !above.intersects(occupied)) return above

    val belowTop = occupied.bottom + gap
    if (belowTop + blockHeight <= photo.bottom) {
        val below = BrandFrameBounds(left, belowTop, left + width, belowTop + blockHeight)
        if (!below.intersects(occupied)) return below
    }

    // Current watermark size limits always leave a vertical lane. Keep this deterministic fallback
    // for corrupted legacy values: prefer the edge with the larger free span.
    val roomAbove = (occupied.top - gap - photo.top).coerceAtLeast(0f)
    val roomBelow = (photo.bottom - occupied.bottom - gap).coerceAtLeast(0f)
    return if (roomAbove >= roomBelow) {
        blockEndingAt((occupied.top - gap).coerceAtLeast(photo.top + blockHeight))
    } else {
        val top = (occupied.bottom + gap).coerceAtMost(photo.bottom - blockHeight)
        BrandFrameBounds(left, top, left + width, top + blockHeight)
    }
}

private fun PhotoFrameLayout.photoRect(): RectF = RectF(
    photoLeft,
    photoTop,
    photoRight,
    photoBottom,
)

private fun RectF.toBrandFrameBounds(): BrandFrameBounds = BrandFrameBounds(
    left = left,
    top = top,
    right = right,
    bottom = bottom,
)

private fun PhotoFrameWatermark.forBrandPhoto(
    preset: PhotoFramePreset,
): PhotoFrameWatermark = when (preset) {
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

private fun PhotoFrameWatermark.forEditorialPhoto(
    preset: PhotoFramePreset,
): PhotoFrameWatermark {
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
        PhotoFramePreset.FILM_GALLERY,
        PhotoFramePreset.FILM_NEGATIVE -> content == PhotoFrameWatermarkContent.IMAGE
        PhotoFramePreset.FILM_EDGE,
        PhotoFramePreset.PARAMETER_POSTER -> true
        else -> false
    }
    return if (shouldUsePhoto) copy(position = mappedPosition) else copy(enabled = false)
}

private fun PhotoFrameWatermark.bandWatermarkFor(
    preset: PhotoFramePreset,
): PhotoFrameWatermark? {
    if (!enabled || content != PhotoFrameWatermarkContent.TEXT || position.isPhotoPlacement()) {
        return null
    }
    val supported = when (preset) {
        PhotoFramePreset.CLASSIC_SIGNATURE -> position != PhotoFrameWatermarkPosition.AUTO
        PhotoFramePreset.GALLERY_MAT,
        PhotoFramePreset.FILM_GALLERY,
        PhotoFramePreset.FILM_NEGATIVE -> true
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

private fun brandFrameCornerRadius(layout: PhotoFrameLayout): Float =
    (layout.photoRight - layout.photoLeft) * 0.014f

/** 照片与毛玻璃参数卡共用基础圆角；额外留白不会放大圆角。 */
internal fun photoFrameCornerRadius(layout: PhotoFrameLayout): Float =
    (layout.designHeight - layout.designMetadataTop) * 0.26f

internal fun PhotoFrameWatermarkPosition.isPhotoPlacement(): Boolean = when (this) {
    PhotoFrameWatermarkPosition.PHOTO_TOP_LEFT,
    PhotoFrameWatermarkPosition.PHOTO_TOP_CENTER,
    PhotoFrameWatermarkPosition.PHOTO_TOP_RIGHT,
    PhotoFrameWatermarkPosition.PHOTO_CENTER,
    PhotoFrameWatermarkPosition.PHOTO_BOTTOM_LEFT,
    PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER,
    PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT -> true
    PhotoFrameWatermarkPosition.AUTO,
    PhotoFrameWatermarkPosition.LEFT,
    PhotoFrameWatermarkPosition.CENTER,
    PhotoFrameWatermarkPosition.RIGHT -> false
}

/** 无边框模式只接受照片内位置，并彻底消除隐藏边框样式对渲染身份的影响。 */
private fun PhotoFrameWatermark.forBorderMode(
    borderEnabled: Boolean,
): PhotoFrameWatermark =
    if (!borderEnabled && !position.isPhotoPlacement()) {
        copy(position = PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER)
    } else {
        this
    }

private fun PhotoFrameWatermark.withoutPhotoPlacement(): PhotoFrameWatermark =
    if (position.isPhotoPlacement() || content == PhotoFrameWatermarkContent.IMAGE) {
        copy(enabled = false)
    } else {
        this
    }

/**
 * Calculates the text origin from its actual glyph bounds. The 4% inset is based on the
 * photo's short edge, so landscape and portrait photos keep the same visual breathing room.
 */
internal fun calculatePhotoWatermarkPlacement(
    photoLeft: Float,
    photoTop: Float,
    photoRight: Float,
    photoBottom: Float,
    textBounds: PhotoWatermarkTextBounds,
    position: PhotoFrameWatermarkPosition,
): PhotoWatermarkPlacement {
    require(photoRight > photoLeft)
    require(photoBottom > photoTop)
    require(textBounds.right >= textBounds.left)
    require(textBounds.bottom >= textBounds.top)
    require(position.isPhotoPlacement())

    val safeInset = min(photoRight - photoLeft, photoBottom - photoTop) * 0.04f
    val minOriginX = photoLeft + safeInset - textBounds.left
    val maxOriginX = photoRight - safeInset - textBounds.right
    val minBaseline = photoTop + safeInset - textBounds.top
    val maxBaseline = photoBottom - safeInset - textBounds.bottom
    val centeredOriginX = (photoLeft + photoRight - textBounds.left - textBounds.right) / 2f
    val centeredBaseline = (photoTop + photoBottom - textBounds.top - textBounds.bottom) / 2f

    val requestedX = when (position) {
        PhotoFrameWatermarkPosition.PHOTO_TOP_LEFT,
        PhotoFrameWatermarkPosition.PHOTO_BOTTOM_LEFT -> minOriginX
        PhotoFrameWatermarkPosition.PHOTO_TOP_CENTER,
        PhotoFrameWatermarkPosition.PHOTO_CENTER,
        PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER -> centeredOriginX
        PhotoFrameWatermarkPosition.PHOTO_TOP_RIGHT,
        PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT -> maxOriginX
        else -> error("A metadata placement cannot be positioned inside the photo")
    }
    val requestedBaseline = when (position) {
        PhotoFrameWatermarkPosition.PHOTO_TOP_LEFT,
        PhotoFrameWatermarkPosition.PHOTO_TOP_CENTER,
        PhotoFrameWatermarkPosition.PHOTO_TOP_RIGHT -> minBaseline
        PhotoFrameWatermarkPosition.PHOTO_CENTER -> centeredBaseline
        PhotoFrameWatermarkPosition.PHOTO_BOTTOM_LEFT,
        PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER,
        PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT -> maxBaseline
        else -> error("A metadata placement cannot be positioned inside the photo")
    }
    return PhotoWatermarkPlacement(
        originX = if (minOriginX <= maxOriginX) {
            requestedX.coerceIn(minOriginX, maxOriginX)
        } else {
            centeredOriginX
        },
        baseline = if (minBaseline <= maxBaseline) {
            requestedBaseline.coerceIn(minBaseline, maxBaseline)
        } else {
            centeredBaseline
        },
    )
}

/** 用户看到的透明度档位就是最终 Alpha，不再受颜色预设原始透明度二次影响。 */
internal fun watermarkAlpha(opacityPercent: Int): Int =
    (normalizePhotoFrameWatermarkOpacityPercent(opacityPercent) * 255f / 100f).roundToInt()

private fun resolvedWatermarkEffect(
    watermark: PhotoFrameWatermark,
): PhotoFrameWatermarkEffect = when (watermark.effect) {
    PhotoFrameWatermarkEffect.AUTO -> if (watermark.position.isPhotoPlacement()) {
        PhotoFrameWatermarkEffect.SHADOW
    } else {
        PhotoFrameWatermarkEffect.NONE
    }
    else -> watermark.effect
}

private fun contrastingWatermarkColor(color: Int, alpha: Int): Int {
    val perceivedBrightness =
        (Color.red(color) * 299 + Color.green(color) * 587 + Color.blue(color) * 114) / 1000
    return if (perceivedBrightness >= 150) {
        Color.argb(alpha.coerceIn(0, 255), 12, 15, 18)
    } else {
        Color.argb(alpha.coerceIn(0, 255), 248, 249, 250)
    }
}

/**
 * 返回让所有文字墨迹高度都能放进信息区的统一缩放比例。绘制端先整体缩小字号，再计算
 * 基线，因此任意水印字号、字体和相机元数据组合都不会互相覆盖。
 */
internal fun frameTextScaleToFit(
    areaHeight: Float,
    rows: List<FrameTextVisualBounds>,
): Float {
    require(areaHeight >= 0f)
    rows.forEach { require(it.bottom >= it.top) }
    val textHeight = rows.sumOf { (it.bottom - it.top).toDouble() }.toFloat()
    if (textHeight <= 0f || textHeight <= areaHeight) return 1f
    // 留 2% 抗锯齿余量，避免不同 Android 字体栅格化实现恰好贴边时出现一像素相交。
    return (areaHeight / textHeight * 0.98f).coerceIn(0f, 1f)
}

/** 前四种边框共用的信息区，上下各保留 6% 的文字安全留白。 */
internal fun frameMetadataVerticalPadding(areaHeight: Float): Float {
    require(areaHeight >= 0f)
    return areaHeight * 0.06f
}

/**
 * 按每行文字的真实可见边界计算基线，使整组文字在指定区域内视觉上下居中。
 *
 * [FrameTextVisualBounds] 来自 Paint.getTextBounds，而不是字体抽象行高，因此大写品牌、
 * 数字参数和自定义字体混排时仍以实际墨迹边界为准。调用方先通过
 * [frameTextScaleToFit] 保证总墨迹高度可容纳；本函数再压缩行间距而不改变顺序。
 */
internal fun centeredFrameTextBaselines(
    areaTop: Float,
    areaBottom: Float,
    rows: List<FrameTextVisualBounds>,
    preferredGap: Float,
): List<Float> {
    require(areaBottom >= areaTop)
    require(preferredGap >= 0f)
    if (rows.isEmpty()) return emptyList()
    rows.forEach { require(it.bottom >= it.top) }

    val areaHeight = areaBottom - areaTop
    val textHeight = rows.sumOf { (it.bottom - it.top).toDouble() }.toFloat()
    val gapCount = rows.size - 1
    val gap = if (gapCount > 0) {
        min(preferredGap, ((areaHeight - textHeight) / gapCount).coerceAtLeast(0f))
    } else {
        0f
    }
    val groupHeight = textHeight + gap * gapCount
    var cursor = areaTop + (areaHeight - groupHeight).coerceAtLeast(0f) / 2f
    return rows.map { row ->
        val baseline = cursor - row.top
        cursor += row.bottom - row.top + gap
        baseline
    }
}

internal fun normalizeCameraMake(make: String?): String {
    val value = make?.trim().orEmpty()
    return when {
        value.contains("nikon", ignoreCase = true) -> "Nikon"
        value.contains("canon", ignoreCase = true) -> "Canon"
        value.contains("sony", ignoreCase = true) -> "SONY"
        value.contains("fujifilm", ignoreCase = true) -> "FUJIFILM"
        value.contains("hasselblad", ignoreCase = true) -> "Hasselblad"
        value.contains("leica", ignoreCase = true) -> "Leica"
        value.contains("panasonic", ignoreCase = true) -> "Panasonic"
        value.contains("olympus", ignoreCase = true) ||
            value.contains("om digital", ignoreCase = true) -> "OM SYSTEM"
        value.contains("pentax", ignoreCase = true) -> "PENTAX"
        value.contains("ricoh", ignoreCase = true) -> "RICOH"
        value.contains("apple", ignoreCase = true) -> "Apple"
        value.contains("samsung", ignoreCase = true) -> "SAMSUNG"
        value.contains("google", ignoreCase = true) -> "Google"
        value.contains("xiaomi", ignoreCase = true) ||
            value.contains("redmi", ignoreCase = true) -> "XIAOMI"
        value.contains("huawei", ignoreCase = true) -> "HUAWEI"
        value.contains("honor", ignoreCase = true) -> "HONOR"
        value.contains("oneplus", ignoreCase = true) -> "ONEPLUS"
        value.contains("oppo", ignoreCase = true) -> "OPPO"
        value.contains("vivo", ignoreCase = true) -> "VIVO"
        value.contains("realme", ignoreCase = true) -> "REALME"
        value.contains("motorola", ignoreCase = true) -> "MOTOROLA"
        value.equals("nokia", ignoreCase = true) ||
            value.startsWith("Nokia ", ignoreCase = true) -> "NOKIA"
        value.equals("dji", ignoreCase = true) ||
            value.startsWith("DJI ", ignoreCase = true) -> "DJI"
        value.isNotEmpty() -> value
        else -> ""
    }
}

/** Uppercase typographic brand used by the two brand-frame presets; no trademark artwork. */
internal fun cameraBrandLabel(make: String?, model: String?): String {
    val normalizedMake = normalizeCameraMake(make).trim()
    if (normalizedMake.isNotEmpty()) {
        return normalizedMake.uppercase(Locale.ROOT).take(32)
    }
    val modelValue = model?.trim().orEmpty()
    val inferred = when {
        modelValue.contains("nikon", ignoreCase = true) -> "NIKON"
        modelValue.contains("canon", ignoreCase = true) -> "CANON"
        modelValue.contains("sony", ignoreCase = true) -> "SONY"
        modelValue.contains("fujifilm", ignoreCase = true) -> "FUJIFILM"
        modelValue.contains("hasselblad", ignoreCase = true) -> "HASSELBLAD"
        modelValue.contains("leica", ignoreCase = true) -> "LEICA"
        modelValue.contains("panasonic", ignoreCase = true) -> "PANASONIC"
        modelValue.contains("olympus", ignoreCase = true) ||
            modelValue.contains("om system", ignoreCase = true) -> "OM SYSTEM"
        modelValue.contains("pentax", ignoreCase = true) -> "PENTAX"
        modelValue.contains("ricoh", ignoreCase = true) -> "RICOH"
        modelValue.contains("iphone", ignoreCase = true) -> "APPLE"
        modelValue.contains("pixel", ignoreCase = true) -> "GOOGLE"
        modelValue.contains("galaxy", ignoreCase = true) -> "SAMSUNG"
        modelValue.startsWith("SM-", ignoreCase = true) -> "SAMSUNG"
        modelValue.contains("xiaomi", ignoreCase = true) ||
            modelValue.contains("redmi", ignoreCase = true) -> "XIAOMI"
        modelValue.contains("huawei", ignoreCase = true) -> "HUAWEI"
        modelValue.contains("honor", ignoreCase = true) -> "HONOR"
        modelValue.contains("oneplus", ignoreCase = true) -> "ONEPLUS"
        modelValue.contains("oppo", ignoreCase = true) -> "OPPO"
        modelValue.contains("vivo", ignoreCase = true) -> "VIVO"
        modelValue.contains("realme", ignoreCase = true) -> "REALME"
        else -> null
    }
    return inferred.orEmpty()
}

/**
 * 很多相机会把厂商名同时写进 Make 和 Model（如 NIKON CORPORATION + NIKON Z 5）。
 * 品牌已经单独排版时，从机型开头移除重复厂商，避免出现“Nikon NIKON Z 5”。
 */
internal fun normalizeCameraModel(make: String?, model: String?): String {
    val value = model?.trim().orEmpty()
    if (value.isEmpty()) return ""
    val brand = normalizeCameraMake(make)
    val prefixes = buildList {
        make?.trim()?.takeIf { it.isNotEmpty() }?.let(::add)
        if (brand.isNotEmpty()) add(brand)
    }.distinctBy { it.lowercase(Locale.ROOT) }
        .sortedByDescending(String::length)
    val prefix = prefixes.firstOrNull { value.startsWith(it, ignoreCase = true) }
        ?: return value
    return value.substring(prefix.length)
        .trimStart(' ', '-', '_')
}

internal fun frameDetailLine(metadata: PhotoFrameMetadata): String =
    listOfNotNull(
        metadata.focalLength,
        metadata.aperture?.replace("f/", "F", ignoreCase = true),
        metadata.shutter?.let { if (it.endsWith("s", ignoreCase = true)) it else "${it}s" },
        metadata.iso,
    ).joinToString("   ")

/**
 * Location metadata is deliberately compact: camera-style degrees and decimal minutes
 * and altitude share one row. City and district share a separate row above them. Display precision is
 * limited to three decimals in the minutes; the original EXIF and lookup coordinates are unchanged.
 */
internal fun frameLocationRows(metadata: PhotoFrameMetadata): List<String> = buildList {
    // One short place row follows the camera/date rows in every preset. Coordinates keep their
    // own row, so the three-row plaque and narrow film band never gain a fourth detail row.
    listOfNotNull(metadata.city, metadata.region)
        .map(String::trim).filter(String::isNotEmpty).distinct()
        .joinToString(" · ").takeIf(String::isNotEmpty)?.let(::add)
    val coordinates = if (
        validFrameCoordinates(metadata.latitude, metadata.longitude)
    ) {
        formatDegreesMinutesCoordinates(
            latitude = checkNotNull(metadata.latitude),
            longitude = checkNotNull(metadata.longitude),
        )
    } else {
        null
    }
    val altitude = metadata.altitudeMeters
        ?.takeIf { it.isFinite() && it != 0.0 }
        ?.let { String.format(Locale.US, "%.0fm", it) }
    listOfNotNull(coordinates, altitude)
        .joinToString("  ")
        .takeIf(String::isNotBlank)
        ?.let(::add)
}

/** Compact two-space rhythm used by the full-bleed signature preset. */
internal fun immersiveFrameDetailLine(metadata: PhotoFrameMetadata): String =
    listOfNotNull(
        metadata.focalLength,
        metadata.aperture?.let {
            if (it.startsWith("f/", ignoreCase = true)) it.lowercase(Locale.ROOT) else "f/$it"
        },
        metadata.shutter?.let { if (it.endsWith("s", ignoreCase = true)) it else "${it}s" },
        metadata.iso,
    ).joinToString("  ")

internal fun normalizeCaptureDateTime(value: String?): String? {
    val trimmed = value?.trim()?.takeIf(String::isNotEmpty) ?: return null
    val isExifDate =
        trimmed.length >= 10 &&
            trimmed[4] == ':' &&
            trimmed[7] == ':' &&
            trimmed.substring(0, 4).all(Char::isDigit) &&
            trimmed.substring(5, 7).all(Char::isDigit) &&
            trimmed.substring(8, 10).all(Char::isDigit)
    return if (isExifDate) {
        buildString(trimmed.length) {
            append(trimmed, 0, 4)
            append('-')
            append(trimmed, 5, 7)
            append('-')
            append(trimmed.substring(8))
        }
    } else {
        trimmed
    }
}

internal fun normalizeIso(value: String?): String? {
    val firstValue = value?.substringBefore(',')?.trim().orEmpty()
    if (firstValue.isEmpty()) return null
    val withoutPrefix = if (firstValue.startsWith("ISO", ignoreCase = true)) {
        firstValue.substring(3).trimStart(' ', ':')
    } else {
        firstValue
    }
    return withoutPrefix.takeIf { it.isNotEmpty() }?.let { "ISO$it" }
}

internal fun photoFrameTempName(nonce: Long): String =
    "$PHOTO_FRAME_SESSION_PREFIX${nonce.toString(36)}.jpg"

internal fun isCurrentPhotoFrameTempName(name: String): Boolean =
    name.startsWith(PHOTO_FRAME_SESSION_PREFIX)

private val PHOTO_FRAME_OUTPUT_PATTERN = Regex(
    pattern = "(?:_frame_(${PhotoFramePreset.entries.joinToString("|") { preset ->
        Regex.escape(preset.fileSuffix)
    }})|_watermark|_filter)(?:_w[0-9a-f]{12})?(?:_f[0-9a-f]{8}i\\d{1,3})?" +
        "(?: \\(\\d+\\)|_\\d+)?\\.jpe?g$",
    option = RegexOption.IGNORE_CASE,
)

private const val PHOTO_FRAME_WATERMARK_RENDER_VERSION = 2
// GPS rows were added after the original frame renderer. Include a dedicated version token so
// an already-generated frame without those rows is never treated as the current export.
// Version 2 uses camera-style degrees/minutes instead of decimal degrees.
private const val PHOTO_FRAME_LOCATION_RENDER_VERSION = 2
private const val BRAND_FRAME_RENDER_VERSION = 4
private const val EDITORIAL_FRAME_RENDER_VERSION = 2
// Film-gallery typography evolves independently. Transfer-side deduplication uses this token,
// while the editor preview always redraws and therefore cannot reveal a stale-output hit.
private const val FILM_GALLERY_RENDER_VERSION = 1
private const val FILM_NEGATIVE_RENDER_VERSION = 1
private const val PHOTO_FILTER_RENDER_VERSION = 3

internal fun isPhotoFrameOutputName(name: String): Boolean =
    PHOTO_FRAME_OUTPUT_PATTERN.containsMatchIn(name)

/** 同一张本地原片、同一预设及同一水印配置对应的首选输出名。 */
internal fun photoFrameOutputName(
    sourceName: String,
    preset: PhotoFramePreset,
    watermark: PhotoFrameWatermark = PhotoFrameWatermark(),
    borderEnabled: Boolean = true,
    metadataSettings: PhotoFrameMetadataSettings = defaultPhotoFrameMetadataSettings(preset),
    filter: PhotoFilterSelection? = null,
): String {
    // v2 调整了默认字体与透明度语义，所有成片都带配置摘要，避免误命中升级前旧图。
    val renderedWatermark = watermark.forBorderMode(borderEnabled)
    val renderedMetadataSettings = if (borderEnabled) {
        metadataSettings
    } else {
        defaultPhotoFrameMetadataSettings(preset)
    }
    val decorationEnabled = borderEnabled || renderedWatermark.enabled
    val watermarkSuffix = if (decorationEnabled) {
        "_w${photoFrameWatermarkFingerprint(renderedWatermark, preset, renderedMetadataSettings)}"
    } else {
        ""
    }
    val filterSuffix = filter?.let {
        "_f${photoFilterRenderFingerprint(it)}i${it.normalizedIntensityPercent}"
    }.orEmpty()
    val styleSuffix = when {
        borderEnabled -> "frame_${preset.fileSuffix}"
        renderedWatermark.enabled -> "watermark"
        filter != null -> "filter"
        else -> "watermark"
    }
    return "${File(sourceName).nameWithoutExtension}_${styleSuffix}" +
        "$watermarkSuffix$filterSuffix.jpg"
}

/** Changes whenever filter pixels change, so an older derived image cannot mask a new render. */
internal fun photoFilterRenderFingerprint(filter: PhotoFilterSelection): String =
    MessageDigest.getInstance("SHA-256")
        .digest(
            ("v=$PHOTO_FILTER_RENDER_VERSION\u0000${filter.preset.id}" +
                "\u0000i=${filter.normalizedIntensityPercent}" +
                "\u0000c=${filter.lutAdjustments.contrast}" +
                "\u0000s=${filter.lutAdjustments.saturation}" +
                "\u0000h=${filter.lutAdjustments.highlights}" +
                "\u0000sh=${filter.lutAdjustments.shadows}")
                .toByteArray(Charsets.UTF_8),
        )
        .take(4)
        .joinToString("") { byte -> "%02x".format(Locale.ROOT, byte.toInt() and 0xff) }

/** 摘要只用于稳定区分成片配置，绝不把用户水印原文写入文件名。 */
internal fun photoFrameWatermarkFingerprint(
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
            if (preset == PhotoFramePreset.COLOR_ARCHIVE) add("archive-layout-v=2")
            if (preset == PhotoFramePreset.FILM_GALLERY) {
                add("film-gallery-v=$FILM_GALLERY_RENDER_VERSION")
            }
            if (preset == PhotoFramePreset.FILM_NEGATIVE) {
                add("film-negative-v=$FILM_NEGATIVE_RENDER_VERSION")
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
            if (preset == PhotoFramePreset.COLOR_ARCHIVE) add("archive-layout-v=2")
            if (preset == PhotoFramePreset.FILM_GALLERY) {
                add("film-gallery-v=$FILM_GALLERY_RENDER_VERSION")
            }
            if (preset == PhotoFramePreset.FILM_NEGATIVE) {
                add("film-negative-v=$FILM_NEGATIVE_RENDER_VERSION")
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
    val versionedIdentity = if (
        effectiveMetadataSettings.showCity || effectiveMetadataSettings.showRegion ||
        effectiveMetadataSettings.showCoordinates ||
        effectiveMetadataSettings.showAltitude
    ) {
        "$identity\u0000location-v=$PHOTO_FRAME_LOCATION_RENDER_VERSION"
    } else {
        identity
    }
    val layoutVersion = if (preset == PhotoFramePreset.IMMERSIVE) "" else
        "\u0000measured-layout-v=6" + (if (preset == PhotoFramePreset.FROSTED) "\u0000glass-panel-v=2" else "")
    return MessageDigest.getInstance("SHA-256")
        .digest((versionedIdentity + layoutVersion + if (effectiveMetadataSettings.brandStyle == PhotoFrameBrandStyle.LOGO) "\u0000brand-logo-v=3" else "").toByteArray(Charsets.UTF_8))
        .take(6)
        .joinToString("") { byte -> "%02x".format(Locale.ROOT, byte.toInt() and 0xff) }
}

/** 旧三档值继续沿用原摘要令牌，升级后不会把像素完全相同的旧成片误判为新配置。 */
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

private fun resolvedWatermarkPosition(
    preset: PhotoFramePreset,
    requested: PhotoFrameWatermarkPosition,
): PhotoFrameWatermarkPosition = when (requested) {
    PhotoFrameWatermarkPosition.AUTO -> {
        when (preset) {
            PhotoFramePreset.PLAQUE -> PhotoFrameWatermarkPosition.LEFT
            // AUTO is an inline signature in this preset, while CENTER is a separate row.
            PhotoFramePreset.IMMERSIVE -> PhotoFrameWatermarkPosition.AUTO
            PhotoFramePreset.BRAND_INSET,
            PhotoFramePreset.BRAND_GALLERY -> PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT
            PhotoFramePreset.CLASSIC_SIGNATURE,
            PhotoFramePreset.COLOR_ARCHIVE,
            PhotoFramePreset.FILM_EDGE,
            PhotoFramePreset.FILM_NEGATIVE -> PhotoFrameWatermarkPosition.CENTER
            PhotoFramePreset.GALLERY_MAT,
            PhotoFramePreset.FILM_GALLERY -> PhotoFrameWatermarkPosition.CENTER
            else -> PhotoFrameWatermarkPosition.CENTER
        }
    }
    else -> requested
}

/**
 * 判断目标目录中是否已经有该原片按指定预设与水印配置生成的成片。
 *
 * 除首选名外也识别导出器为重名冲突生成的 " (n)" / 时间戳副本，避免用户重新点击
 * 已传照片时继续制造同款副本。原片名和扩展名均按 DocumentsProvider 的常见行为
 * 做大小写不敏感比较。
 */
internal fun PhotoFrameDestination.hasFrameFor(
    sourceName: String,
    preset: PhotoFramePreset,
    watermark: PhotoFrameWatermark = PhotoFrameWatermark(),
    borderEnabled: Boolean = true,
    metadataSettings: PhotoFrameMetadataSettings = defaultPhotoFrameMetadataSettings(preset),
    filter: PhotoFilterSelection? = null,
): Boolean {
    // A filename only records selected fields, not whether an earlier geocoder succeeded.
    // Explicit re-export must be allowed to fill in a place missing from an offline export.
    if (borderEnabled && (metadataSettings.showCity || metadataSettings.showRegion)) return false
    val pattern = photoFrameOutputPattern(
        sourceName,
        preset,
        watermark,
        borderEnabled,
        metadataSettings,
        filter,
    )
    return occupiedNames.any(pattern::matches)
}

internal fun isPhotoFrameOutputFor(
    name: String,
    sourceName: String,
    preset: PhotoFramePreset,
    watermark: PhotoFrameWatermark = PhotoFrameWatermark(),
    borderEnabled: Boolean = true,
    metadataSettings: PhotoFrameMetadataSettings = defaultPhotoFrameMetadataSettings(preset),
    filter: PhotoFilterSelection? = null,
): Boolean = photoFrameOutputPattern(
    sourceName,
    preset,
    watermark,
    borderEnabled,
    metadataSettings,
    filter,
).matches(name)

private fun photoFrameOutputPattern(
    sourceName: String,
    preset: PhotoFramePreset,
    watermark: PhotoFrameWatermark,
    borderEnabled: Boolean,
    metadataSettings: PhotoFrameMetadataSettings,
    filter: PhotoFilterSelection?,
): Regex {
    val preferred = photoFrameOutputName(
        sourceName,
        preset,
        watermark,
        borderEnabled,
        metadataSettings,
        filter,
    )
    val dot = preferred.lastIndexOf('.')
    val stem = if (dot >= 0) preferred.substring(0, dot) else preferred
    val extension = if (dot >= 0) preferred.substring(dot) else ""
    return Regex(
        "^${Regex.escape(stem)}(?: \\(\\d+\\)|_\\d+)?${Regex.escape(extension)}$",
        RegexOption.IGNORE_CASE,
    )
}

internal fun uniqueName(preferred: String, occupied: Set<String>): String {
    val normalizedOccupied = occupied.asSequence()
        .mapTo(HashSet(occupied.size)) { it.lowercase(Locale.ROOT) }
    if (preferred.lowercase(Locale.ROOT) !in normalizedOccupied) return preferred
    val dot = preferred.lastIndexOf('.')
    val stem = if (dot >= 0) preferred.substring(0, dot) else preferred
    val ext = if (dot >= 0) preferred.substring(dot) else ""
    for (index in 1..999) {
        val candidate = "$stem ($index)$ext"
        if (candidate.lowercase(Locale.ROOT) !in normalizedOccupied) return candidate
    }
    return "${stem}_${System.currentTimeMillis()}$ext"
}

private fun formatAperture(value: Double): String =
    if (value % 1.0 < 0.05) {
        String.format(Locale.US, "f/%.0f", value)
    } else {
        String.format(Locale.US, "f/%.1f", value)
    }

internal fun formatShutter(seconds: Double): String = when {
    seconds >= 1.0 -> if (seconds % 1.0 < 0.05) {
        String.format(Locale.US, "%.0fs", seconds)
    } else {
        String.format(Locale.US, "%.1fs", seconds)
    }
    seconds >= 0.4 -> String.format(Locale.US, "%.1fs", seconds)
    seconds > 0.0 -> String.format(Locale.US, "1/%.0f", 1.0 / seconds)
    else -> ""
}

internal class LocalPhotoExportException(val stage: String, cause: Throwable) : Exception(cause)
