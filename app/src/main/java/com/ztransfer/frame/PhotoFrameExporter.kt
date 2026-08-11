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
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import androidx.core.content.res.ResourcesCompat
import com.ztransfer.R
import com.ztransfer.filter.PhotoFilterRenderer
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.util.applyExifOrientation
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

/** 未完成的边框派生文件；仅在完整写入后改成正式名称，App 下次启动会清理遗留项。 */
internal const val PHOTO_FRAME_PART_PREFIX = ".nkframe_"
internal const val PHOTO_FRAME_OUTPUT_DIRECTORY = "ZTFrames"
internal const val PHOTO_FRAME_JPEG_QUALITY = 100
internal const val PHOTO_FRAME_REGION_TARGET_PIXELS = 1024 * 1024
private val PHOTO_FRAME_SESSION_PREFIX =
    "$PHOTO_FRAME_PART_PREFIX${UUID.randomUUID().toString().take(8)}_"
private const val PLAQUE_BAND_TO_WIDTH = 0.12f
private const val BRAND_FRAME_SIDE_TO_PHOTO_WIDTH = 0.032f
private const val BRAND_INSET_BOTTOM_TO_PHOTO_WIDTH = 0.032f
private const val BRAND_GALLERY_BOTTOM_TO_PHOTO_WIDTH = 0.16f

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

internal data class PhotoFrameMetadata(
    val make: String?,
    val model: String?,
    val aperture: String?,
    val shutter: String?,
    val iso: String?,
    val focalLength: String?,
    val dateTime: String? = null,
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
    // Preserve photographic/capture metadata but intentionally do not copy GPS location or the
    // source orientation (the pixels have already been normalized during decode).
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
        filter: PhotoFilterSelection? = null,
    ): Result<PhotoFrameExportResult> {
        return try {
            currentCoroutineContext().ensureActive()
            require(
                isSupportedPhotoFrameSourceExtension(sourceName.substringAfterLast('.', "")),
            ) {
                "Only JPG/JPEG/PNG supports borders or watermarks"
            }
            val renderedWatermark = watermark.forBorderMode(borderEnabled)
            val rendered = renderSource(
                context = context,
                resolver = resolver,
                sourceUri = sourceUri,
                preset = preset,
                watermark = renderedWatermark,
                borderEnabled = borderEnabled,
                filter = filter,
            )
            val saved = try {
                currentCoroutineContext().ensureActive()
                saveRendered(
                    resolver = resolver,
                    destination = destination,
                    sourceUri = sourceUri,
                    sourceName = sourceName,
                    preset = preset,
                    watermark = renderedWatermark,
                    borderEnabled = borderEnabled,
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
        filter: PhotoFilterSelection? = null,
    ): Result<PhotoFrameExportResult> {
        return try {
            currentCoroutineContext().ensureActive()
            val renderedWatermark = watermark.forBorderMode(borderEnabled)
            val rendered = renderSource(
                context = context,
                resolver = resolver,
                sourceUri = source.sourceUri,
                preset = preset,
                watermark = renderedWatermark,
                borderEnabled = borderEnabled,
                filter = filter,
            )
            val saved = try {
                currentCoroutineContext().ensureActive()
                saveRenderedToMediaStore(
                    resolver = resolver,
                    source = source,
                    preset = preset,
                    watermark = renderedWatermark,
                    borderEnabled = borderEnabled,
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
            Result.failure(outOfMemory)
        } catch (error: Exception) {
            Log.e(
                PHOTO_FRAME_EXPORT_TAG,
                "Local photo export failed (authority=${source.sourceUri.authority})",
                error,
            )
            Result.failure(error)
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
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        borderEnabled: Boolean,
        filter: PhotoFilterSelection?,
    ): Bitmap {
        val metadata = if (borderEnabled) readMetadata(resolver, sourceUri) else EMPTY_METADATA
        if (borderEnabled && preset != PhotoFramePreset.IMMERSIVE) {
            return renderOriginalFrameByRegions(
                context = context,
                resolver = resolver,
                sourceUri = sourceUri,
                metadata = metadata,
                preset = preset,
                watermark = watermark,
                filter = filter,
            )
        }
        val decoded = decodeOriginal(resolver, sourceUri)
            ?: error("Cannot decode source photo")
        return try {
            if (filter != null) {
                PhotoFilterRenderer.renderInPlace(decoded, filter)
            }
            val rendered = renderFrame(
                context,
                decoded,
                metadata,
                preset,
                watermark,
                borderEnabled,
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
    ): PhotoFrameDestination {
        val treeId = DocumentsContract.getTreeDocumentId(treeUri)
        val rootUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, treeId)
        val directoryUri = findFrameDirectory(resolver, treeUri, treeId)
            ?: DocumentsContract.createDocument(
                resolver,
                rootUri,
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

    private fun readMetadata(resolver: ContentResolver, uri: Uri): PhotoFrameMetadata {
        val descriptorResult = runCatching {
            resolver.openFileDescriptor(uri, "r")?.use { pfd ->
                metadataFrom(ExifInterface(pfd.fileDescriptor))
            }
        }.getOrNull()
        if (descriptorResult != null) return descriptorResult

        // 少数 DocumentsProvider 返回不可 seek 的文件描述符，但输入流仍可正常读取。
        return runCatching {
            resolver.openInputStream(uri)?.use { input ->
                BufferedInputStream(input).use { metadataFrom(ExifInterface(it)) }
            }
        }.getOrNull() ?: EMPTY_METADATA
    }

    private fun metadataFrom(exif: ExifInterface): PhotoFrameMetadata {
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
            dateTime = sequenceOf(
                ExifInterface.TAG_DATETIME_ORIGINAL,
                ExifInterface.TAG_DATETIME_DIGITIZED,
                ExifInterface.TAG_DATETIME,
            ).mapNotNull(exif::getAttribute)
                .mapNotNull(::normalizeCaptureDateTime)
                .firstOrNull(),
        )
    }

    private fun decodeBounded(
        resolver: ContentResolver,
        uri: Uri,
        maxEdge: Int,
    ): Bitmap? = decodeBitmap(resolver, uri, maxEdge = maxEdge, mutable = false)

    private fun decodeOriginal(
        resolver: ContentResolver,
        uri: Uri,
    ): Bitmap? = decodeBitmap(resolver, uri, maxEdge = null, mutable = true)

    private fun decodeBitmap(
        resolver: ContentResolver,
        uri: Uri,
        maxEdge: Int?,
        mutable: Boolean,
    ): Bitmap? {
        require(maxEdge == null || maxEdge > 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                return ImageDecoder.decodeBitmap(
                    ImageDecoder.createSource(resolver, uri),
                ) { decoder, info, _ ->
                    val width = info.size.width
                    val height = info.size.height
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
        val orientation = runCatching {
            resolver.openFileDescriptor(uri, "r")?.use {
                ExifInterface(it.fileDescriptor).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL,
                )
            } ?: ExifInterface.ORIENTATION_NORMAL
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
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
        longEdge: Int,
        filter: PhotoFilterSelection? = null,
    ): Bitmap {
        val input = filter?.let { PhotoFilterRenderer.render(source, it) } ?: source
        return try {
            renderFrame(
                context = context,
                source = input,
                metadata = metadata,
                preset = preset,
                watermark = watermark.forBorderMode(borderEnabled),
                borderEnabled = borderEnabled,
                // Preview must match export: filter only the photo, never the frame backdrop.
                backdropSource = source,
                longEdge = longEdge,
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
    ): Bitmap {
        require(longEdge == null || longEdge > 0)
        if (!borderEnabled) {
            return renderWatermarkOnly(
                context,
                source,
                watermark,
                longEdge ?: maxOf(source.width, source.height),
            )
        }
        val layout = if (longEdge != null) {
            when (preset) {
                PhotoFramePreset.PLAQUE ->
                    calculatePlaqueFrameLayout(source.width, source.height, longEdge)
                PhotoFramePreset.IMMERSIVE ->
                    calculateImmersiveFrameLayout(source.width, source.height, longEdge)
                PhotoFramePreset.BRAND_INSET,
                PhotoFramePreset.BRAND_GALLERY ->
                    calculateBrandFrameLayout(source.width, source.height, preset, longEdge)
                else -> calculatePhotoFrameLayout(source.width, source.height, longEdge)
            }
        } else {
            when (preset) {
                PhotoFramePreset.PLAQUE ->
                    calculateOriginalQualityPlaqueLayout(source.width, source.height)
                PhotoFramePreset.IMMERSIVE ->
                    calculateImmersiveFrameLayout(
                        source.width,
                        source.height,
                        maxOf(source.width, source.height),
                    )
                PhotoFramePreset.BRAND_INSET,
                PhotoFramePreset.BRAND_GALLERY ->
                    calculateOriginalQualityBrandFrameLayout(
                        source.width,
                        source.height,
                        preset,
                    )
                else -> calculateOriginalQualityPhotoFrameLayout(source.width, source.height)
            }
        }
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
        val output = Bitmap.createBitmap(
            layout.canvasWidth,
            layout.canvasHeight,
            Bitmap.Config.ARGB_8888,
        )
        try {
            val canvas = Canvas(output)
            if (preset == PhotoFramePreset.PLAQUE) {
                drawPlaqueFrame(context, canvas, source, layout, metadata, watermark)
                return output
            }
            if (preset == PhotoFramePreset.IMMERSIVE) {
                drawImmersiveFrame(context, canvas, source, layout, metadata, watermark)
                return output
            }
            if (preset.isBrandFrame()) {
                drawBrandFrame(context, canvas, source, layout, metadata, preset, watermark)
                return output
            }
            drawBackdrop(canvas, backdropSource, preset)

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
            drawPhotoWatermark(context, canvas, photoRect, preset, watermark)
            canvas.restore()
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = maxOf(1f, layout.canvasWidth * 0.0012f)
                color = if (preset != PhotoFramePreset.MINIMAL) {
                    Color.argb(70, 255, 255, 255)
                } else {
                    Color.argb(45, 20, 28, 35)
                }
                canvas.drawRoundRect(photoRect, radius, radius, this)
            }

            drawMetadata(
                context,
                canvas,
                layout,
                metadata,
                preset,
                watermark.withoutPhotoPlacement(),
            )
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

    private fun drawBackdrop(canvas: Canvas, source: Bitmap, preset: PhotoFramePreset) {
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
            PhotoFramePreset.FROSTED -> {
                // 先缩图，再做两轮可控盒式模糊，最后双线性放大。相比单纯把 72px 图硬拉大，
                // 渐变更连续、没有色块，同时不依赖仅 API 31 可用的 RenderEffect。
                val blurLongEdge = 192
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
                val tiny = Bitmap.createBitmap(blurWidth, blurHeight, Bitmap.Config.ARGB_8888)
                try {
                    Canvas(tiny).drawCenterCrop(
                        source,
                        RectF(0f, 0f, blurWidth.toFloat(), blurHeight.toFloat()),
                    )
                    blurBitmapInPlace(tiny, radius = 8, passes = 2)
                    canvas.drawBitmap(
                        tiny,
                        null,
                        RectF(0f, 0f, canvas.width.toFloat(), canvas.height.toFloat()),
                        Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG),
                    )
                } finally {
                    tiny.recycle()
                }

                when (preset) {
                    PhotoFramePreset.MIST -> {
                        // 只轻提亮，不抹掉照片本身的主色；底部连续暗化，为白色品牌/参数提供
                        // 稳定对比度。雪景会得到银灰质感，蓝天则保留克制的蓝色氛围。
                        canvas.drawColor(Color.argb(62, 238, 244, 248))
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
                    PhotoFramePreset.CINEMA -> {
                        canvas.drawColor(Color.argb(150, 3, 9, 15))
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
                    PhotoFramePreset.FROSTED -> {
                        // 保留照片主色的同时覆盖一层冷白雾面，让整块外框像透过磨砂玻璃；
                        // 参数区还会叠一层独立玻璃胶囊，形成清晰的材质层级。
                        Paint(Paint.ANTI_ALIAS_FLAG).apply {
                            shader = LinearGradient(
                                0f,
                                0f,
                                0f,
                                canvas.height.toFloat(),
                                Color.argb(92, 250, 253, 255),
                                Color.argb(132, 231, 239, 245),
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
                }
            }
            PhotoFramePreset.PLAQUE -> canvas.drawColor(Color.WHITE)
            PhotoFramePreset.IMMERSIVE -> Unit
            PhotoFramePreset.BRAND_INSET,
            PhotoFramePreset.BRAND_GALLERY -> canvas.drawColor(Color.WHITE)
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

    private fun drawMetadata(
        context: Context,
        canvas: Canvas,
        layout: PhotoFrameLayout,
        metadata: PhotoFrameMetadata,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
    ) {
        // 图内水印已在照片裁剪区域中绘制，不能再作为边框信息区的一行参与排版。
        val metadataWatermark = watermark.withoutPhotoPlacement()
        val lightText =
            preset == PhotoFramePreset.MIST || preset == PhotoFramePreset.CINEMA
        val textColor =
            if (lightText) Color.rgb(248, 250, 252) else Color.rgb(25, 31, 38)
        val mutedColor =
            if (lightText) Color.rgb(220, 227, 233) else Color.rgb(70, 79, 88)
        val brand = normalizeCameraMake(metadata.make)
        val model = normalizeCameraModel(metadata.make, metadata.model)
        val details = frameDetailLine(metadata)
        val hasTitle = brand.isNotEmpty() || model.isNotEmpty()
        val hasDetails = details.isNotBlank()
        val centerX = layout.canvasWidth / 2f
        val contentArea = if (preset == PhotoFramePreset.FROSTED) {
            frostedMetadataPanelBounds(layout)
        } else {
            // 真正可见的下边框从照片底边开始；metadataTop 只是排版预留线，在部分长宽比
            // 下会比照片底边更低，用它居中正是旧版文字看起来整体偏下的根源。
            RectF(
                0f,
                layout.photoBottom,
                layout.canvasWidth.toFloat(),
                layout.canvasHeight.toFloat(),
            )
        }

        val brandPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = textColor
            textSize = layout.canvasWidth * 0.032f
            typeface = Typeface.create("sans-serif", Typeface.BOLD_ITALIC)
        }
        val modelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = textColor
            textSize = layout.canvasWidth * 0.024f
            typeface = Typeface.create("sans-serif", Typeface.NORMAL)
        }
        var gap = if (brand.isNotEmpty() && model.isNotEmpty()) {
            layout.canvasWidth * 0.016f
        } else {
            0f
        }
        val initialWidth = brandPaint.measureText(brand) + gap + modelPaint.measureText(model)
        val maxTitleWidth = layout.canvasWidth *
            if (preset == PhotoFramePreset.FROSTED) 0.78f else 0.86f
        if (initialWidth > maxTitleWidth) {
            val scale = maxTitleWidth / initialWidth
            brandPaint.textSize *= scale
            modelPaint.textSize *= scale
            gap *= scale
        }

        val detailPaint = if (hasDetails) {
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = mutedColor
                textSize = layout.canvasWidth * 0.020f
                typeface = Typeface.create("sans-serif", Typeface.NORMAL)
                textAlign = Paint.Align.CENTER
            }
            val maxDetailWidth = layout.canvasWidth *
                if (preset == PhotoFramePreset.FROSTED) 0.76f else 0.82f
            val detailWidth = paint.measureText(details)
            if (detailWidth > maxDetailWidth) {
                paint.textSize *= maxDetailWidth / detailWidth
            }
            paint
        } else {
            null
        }
        val watermarkText = metadataWatermark.displayText
        val watermarkPaint = if (metadataWatermark.enabled) {
            createWatermarkPaint(
                context = context,
                canvas = canvas,
                preset = preset,
                watermark = metadataWatermark,
                maxWidth = contentArea.width() * 0.86f,
            )
        } else {
            null
        }
        fun currentRows(): Triple<FrameTextVisualBounds?, FrameTextVisualBounds?, FrameTextVisualBounds?> {
            val title = if (hasTitle) {
                listOfNotNull(
                    brand.takeIf(String::isNotEmpty)?.let { textVisualBounds(it, brandPaint) },
                    model.takeIf(String::isNotEmpty)?.let { textVisualBounds(it, modelPaint) },
                ).reduce(::mergeTextVisualBounds)
            } else {
                null
            }
            return Triple(
                title,
                detailPaint?.let { textVisualBounds(details, it) },
                watermarkPaint?.let { textVisualBounds(watermarkText, it) },
            )
        }
        var (titleBounds, detailBounds, watermarkBounds) = currentRows()
        val initialRows = listOfNotNull(titleBounds, detailBounds, watermarkBounds)
        if (initialRows.isEmpty()) return
        if (preset == PhotoFramePreset.FROSTED) {
            drawFrostedMetadataPanel(canvas, layout, contentArea)
        }
        val rowScale = frameTextScaleToFit(contentArea.height(), initialRows)
        if (rowScale < 1f) {
            brandPaint.textSize *= rowScale
            modelPaint.textSize *= rowScale
            detailPaint?.let { it.textSize *= rowScale }
            watermarkPaint?.let { it.textSize *= rowScale }
            currentRows().let { fitted ->
                titleBounds = fitted.first
                detailBounds = fitted.second
                watermarkBounds = fitted.third
            }
        }
        val rowBounds = listOfNotNull(titleBounds, detailBounds, watermarkBounds)
        val preferredGap = min(
            layout.canvasWidth * 0.0125f,
            contentArea.height() * 0.09f,
        )
        val baselines = centeredFrameTextBaselines(
            areaTop = contentArea.top,
            areaBottom = contentArea.bottom,
            rows = rowBounds,
            preferredGap = preferredGap,
        )
        var rowIndex = 0
        val titleBaseline = if (titleBounds != null) baselines[rowIndex++] else null
        val detailBaseline = if (detailBounds != null) baselines[rowIndex++] else null
        val watermarkBaseline = if (watermarkBounds != null) baselines[rowIndex] else null

        titleBaseline?.let { baseline ->
            val totalWidth =
                brandPaint.measureText(brand) + gap + modelPaint.measureText(model)
            var x = centerX - totalWidth / 2f
            if (brand.isNotEmpty()) {
                canvas.drawText(brand, x, baseline, brandPaint)
                x += brandPaint.measureText(brand) + gap
            }
            if (model.isNotEmpty()) {
                canvas.drawText(model, x, baseline, modelPaint)
            }
        }
        if (detailPaint != null && detailBaseline != null) {
            canvas.drawText(details, centerX, detailBaseline, detailPaint)
        }
        if (watermarkPaint != null && watermarkBaseline != null) {
            val (x, align) = watermarkHorizontalPlacement(
                contentArea,
                preset,
                metadataWatermark.position,
            )
            watermarkPaint.textAlign = align
            drawWatermarkText(
                canvas,
                watermarkText,
                x,
                watermarkBaseline,
                watermarkPaint,
                metadataWatermark,
            )
        }
    }

    /** 不创建外框画布，只按原照片比例缩放并在画面安全区内叠加水印。 */
    private fun renderWatermarkOnly(
        context: Context,
        source: Bitmap,
        watermark: PhotoFrameWatermark,
        longEdge: Int,
    ): Bitmap {
        val scale = min(1f, longEdge.toFloat() / maxOf(source.width, source.height))
        val width = (source.width * scale).roundToInt().coerceAtLeast(1)
        val height = (source.height * scale).roundToInt().coerceAtLeast(1)
        if (width == source.width && height == source.height && source.isMutable) {
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
                layout.canvasWidth * 0.009f,
                0f,
                layout.canvasHeight * 0.004f,
                Color.argb(52, 20, 35, 46),
            )
            canvas.drawRoundRect(panel, radius, radius, this)
            clearShadowLayer()
        }
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = maxOf(1f, layout.canvasWidth * 0.0011f)
            color = Color.argb(178, 255, 255, 255)
            canvas.drawRoundRect(panel, radius, radius, this)
        }
    }

    private fun frostedMetadataPanelBounds(layout: PhotoFrameLayout): RectF {
        val bandHeight = layout.canvasHeight - layout.photoBottom
        val horizontalInset = layout.canvasWidth * 0.072f
        val verticalInset = bandHeight * 0.08f
        return RectF(
            horizontalInset,
            layout.photoBottom + verticalInset,
            layout.canvasWidth - horizontalInset,
            layout.canvasHeight - verticalInset,
        )
    }

    private fun createWatermarkPaint(
        context: Context,
        canvas: Canvas,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        maxWidth: Float,
    ): Paint {
        val shortEdge = min(canvas.width, canvas.height).toFloat()
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
    ) {
        val layout = layoutPhotoWatermark(context, canvas, photoRect, preset, watermark) ?: return
        drawPhotoWatermarkLayout(canvas, layout)
    }

    private fun layoutPhotoWatermark(
        context: Context,
        canvas: Canvas,
        photoRect: RectF,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
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

    private fun textVisualBounds(text: String, paint: Paint): FrameTextVisualBounds {
        val bounds = Rect()
        paint.getTextBounds(text, 0, text.length, bounds)
        return FrameTextVisualBounds(bounds.top.toFloat(), bounds.bottom.toFloat())
    }

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
        val details = immersiveFrameDetailLine(metadata)
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
        val detailPaint = details.takeIf(String::isNotEmpty)?.let {
            Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
                color = Color.rgb(247, 249, 251)
                textSize = shortEdge * 0.0235f
                textAlign = Paint.Align.CENTER
                typeface = Typeface.create("sans-serif", Typeface.NORMAL)
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
            (cameraPaint?.measureText(cameraName) ?: 0f) +
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
            val measured = paint.measureText(details)
            if (measured > maxLineWidth) paint.textSize *= maxLineWidth / measured
        }

        fun firstRowBounds(): FrameTextVisualBounds? {
            val bounds = buildList {
                cameraPaint?.let { add(textVisualBounds(cameraName, it)) }
                inlineWatermarkPaint?.let {
                    add(textVisualBounds(inlineWatermarkText, it))
                }
                dividerPaint?.let { add(textVisualBounds(divider, it)) }
            }
            return bounds.reduceOrNull(::mergeTextVisualBounds)
        }

        val titleBounds = firstRowBounds()
        val detailBounds = detailPaint?.let { textVisualBounds(details, it) }
        val separateBounds = separateWatermarkPaint?.let {
            textVisualBounds(separateWatermarkText, it)
        }
        val rows = listOfNotNull(titleBounds, detailBounds, separateBounds)

        if (rows.isNotEmpty()) {
            val preferredGap = shortEdge * 0.013f
            val textHeight = rows.sumOf { (it.bottom - it.top).toDouble() }.toFloat()
            val blockHeight = textHeight + preferredGap * (rows.size - 1)
            val safeBottom = maxOf(shortEdge * 0.045f, photoRect.height() * 0.025f)
            val blockBottom = photoRect.bottom - safeBottom
            val blockTop = blockBottom - blockHeight
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = LinearGradient(
                    0f,
                    (blockTop - shortEdge * 0.10f).coerceAtLeast(photoRect.height() * 0.58f),
                    0f,
                    photoRect.bottom,
                    Color.TRANSPARENT,
                    Color.argb(118, 0, 0, 0),
                    Shader.TileMode.CLAMP,
                )
                canvas.drawRect(0f, photoRect.height() * 0.52f, photoRect.right, photoRect.bottom, this)
            }

            // Explicit in-photo placement remains above the contrast veil and below metadata.
            drawPhotoWatermark(context, canvas, photoRect, PhotoFramePreset.IMMERSIVE, watermark)

            val baselines = centeredFrameTextBaselines(
                areaTop = blockTop,
                areaBottom = blockBottom,
                rows = rows,
                preferredGap = preferredGap,
            )
            var rowIndex = 0
            val titleBaseline = if (titleBounds != null) baselines[rowIndex++] else null
            val detailBaseline = if (detailBounds != null) baselines[rowIndex++] else null
            val separateBaseline = if (separateBounds != null) baselines[rowIndex] else null

            titleBaseline?.let { baseline ->
                var x = photoRect.centerX() - firstRowWidth() / 2f
                cameraPaint?.let { paint ->
                    canvas.drawText(cameraName, x, baseline, paint)
                    x += paint.measureText(cameraName)
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
            if (detailPaint != null && detailBaseline != null) {
                canvas.drawText(details, photoRect.centerX(), detailBaseline, detailPaint)
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
    ) {
        val attributes = runCatching {
            resolver.openFileDescriptor(sourceUri, "r")?.use { descriptor ->
                val source = ExifInterface(descriptor.fileDescriptor)
                COPIED_EXIF_TAGS.mapNotNull { tag ->
                    source.getAttribute(tag)?.let { value -> tag to value }
                }
            }
        }.getOrNull() ?: return

        runCatching {
            resolver.openFileDescriptor(targetUri, "rw")?.use { descriptor ->
                val target = ExifInterface(descriptor.fileDescriptor)
                attributes.forEach { (tag, value) -> target.setAttribute(tag, value) }
                target.setAttribute(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL.toString(),
                )
                target.setAttribute(ExifInterface.TAG_IMAGE_WIDTH, width.toString())
                target.setAttribute(ExifInterface.TAG_IMAGE_LENGTH, height.toString())
                target.setAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION, width.toString())
                target.setAttribute(ExifInterface.TAG_PIXEL_Y_DIMENSION, height.toString())
                target.saveAttributes()
            }
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
    ): Bitmap = withRegionDecoder(context, resolver, sourceUri) { decoder ->
        val orientation = readSourceOrientation(resolver, sourceUri)
        val orientedSize = orientedPhotoSize(decoder.width, decoder.height, orientation)
        val layout = when (preset) {
            PhotoFramePreset.PLAQUE ->
                calculateOriginalQualityPlaqueLayout(orientedSize.width, orientedSize.height)
            PhotoFramePreset.BRAND_INSET,
            PhotoFramePreset.BRAND_GALLERY ->
                calculateOriginalQualityBrandFrameLayout(
                    orientedSize.width,
                    orientedSize.height,
                    preset,
                )
            else -> calculateOriginalQualityPhotoFrameLayout(orientedSize.width, orientedSize.height)
        }
        val output = Bitmap.createBitmap(
            layout.canvasWidth,
            layout.canvasHeight,
            Bitmap.Config.ARGB_8888,
        )
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
                )
                // The complete plaque band and both watermark modes are composited after filtering.
                drawPlaqueDecoration(context, canvas, layout, metadata, watermark)
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
                )
                canvas.restore()
                drawBrandFrameDecoration(
                    context = context,
                    canvas = canvas,
                    layout = layout,
                    metadata = metadata,
                    preset = preset,
                    watermark = watermark,
                )
                return@withRegionDecoder output
            }

            // Backdrop color/blur must describe the original photo, not the filtered photo layer.
            val unfilteredPreview = decodeRegionPreview(decoder, orientation)
            try {
                drawBackdrop(canvas, unfilteredPreview, preset)
            } finally {
                unfilteredPreview.recycle()
            }
            val radius = photoFrameCornerRadius(layout)
            drawPhotoElevation(canvas, photoRect, radius, preset)
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
            )
            // Watermark is intentionally after the filtered photo tiles and is never filtered.
            drawPhotoWatermark(context, canvas, photoRect, preset, watermark)
            canvas.restore()
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = maxOf(1f, layout.canvasWidth * 0.0012f)
                color = if (preset != PhotoFramePreset.MINIMAL) {
                    Color.argb(70, 255, 255, 255)
                } else {
                    Color.argb(45, 20, 28, 35)
                }
                canvas.drawRoundRect(photoRect, radius, radius, this)
            }
            drawMetadata(
                context,
                canvas,
                layout,
                metadata,
                preset,
                watermark.withoutPhotoPlacement(),
            )
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
        block: suspend (BitmapRegionDecoder) -> T,
    ): T {
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
            val decoder = try {
                BitmapRegionDecoder.newInstance(temporary.absolutePath, false)
            } catch (error: Exception) {
                descriptorFailure?.let(error::addSuppressed)
                streamFailure?.let(error::addSuppressed)
                throw RegionDecodeUnavailableException(error)
            }
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
    ): Bitmap {
        var sample = 1
        while (maxOf(decoder.width / sample, decoder.height / sample) > 192) sample *= 2
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
    ) {
        val rowsPerRegion = photoFrameRegionRows(decoder.width)
        val paint = Paint(Paint.DITHER_FLAG)
        val filterScratch = filter?.let {
            IntArray(maxOf(PHOTO_FRAME_REGION_TARGET_PIXELS, decoder.width))
        }
        var rawTop = 0
        while (rawTop < decoder.height) {
            currentCoroutineContext().ensureActive()
            val rawBottom = minOf(decoder.height, rawTop + rowsPerRegion)
            val rawRegion = Rect(0, rawTop, decoder.width, rawBottom)
            var tile = decoder.decodeRegion(
                rawRegion,
                BitmapFactory.Options().apply {
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                    inMutable = filter != null
                    inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
                },
            ) ?: error("Cannot decode source photo region")
            try {
                if (filter != null) {
                    if (!tile.isMutable) {
                        val mutable = tile.copy(Bitmap.Config.ARGB_8888, true)
                            ?: error("Cannot create mutable photo region")
                        tile.recycle()
                        tile = mutable
                    }
                    // Only this source-photo region is filtered. No frame pixel exists yet here.
                    PhotoFilterRenderer.renderInPlace(
                        source = tile,
                        selection = filter,
                        scratchPixels = filterScratch,
                    )
                }
                tile = applyExifOrientation(tile, orientation)
                val mapped = orientedRegionRect(
                    rawRegion = rawRegion,
                    rawWidth = decoder.width,
                    rawHeight = decoder.height,
                    orientation = orientation,
                )
                check(tile.width == mapped.width() && tile.height == mapped.height()) {
                    "Oriented photo region size mismatch"
                }
                canvas.drawBitmap(
                    tile,
                    null,
                    RectF(
                        photoRect.left + mapped.left,
                        photoRect.top + mapped.top,
                        photoRect.left + mapped.right,
                        photoRect.top + mapped.bottom,
                    ),
                    paint,
                )
            } finally {
                if (!tile.isRecycled) tile.recycle()
            }
            rawTop = rawBottom
        }
    }

    private fun drawBrandFrame(
        context: Context,
        canvas: Canvas,
        source: Bitmap,
        layout: PhotoFrameLayout,
        metadata: PhotoFrameMetadata,
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
        drawBrandFrameDecoration(context, canvas, layout, metadata, preset, watermark)
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
        metadata: PhotoFrameMetadata,
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
        )
        val occupiedWatermarkBounds = photoWatermarkLayout?.bounds?.toBrandFrameBounds()
        val brand = cameraBrandLabel(metadata.make, metadata.model)
        val details = frameDetailLine(metadata)

        canvas.save()
        canvas.clipPath(Path().apply {
            addRoundRect(photoRect, radius, radius, Path.Direction.CW)
        })
        when (preset) {
            PhotoFramePreset.BRAND_INSET -> drawBrandInsetMetadata(
                canvas = canvas,
                photoRect = photoRect,
                brand = brand,
                details = details,
                occupiedWatermarkBounds = occupiedWatermarkBounds,
            )
            PhotoFramePreset.BRAND_GALLERY -> drawBrandGalleryDetails(
                canvas = canvas,
                photoRect = photoRect,
                details = details,
                occupiedWatermarkBounds = occupiedWatermarkBounds,
            )
            else -> error("Not a brand frame")
        }
        photoWatermarkLayout?.let { drawPhotoWatermarkLayout(canvas, it) }
        canvas.restore()

        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = maxOf(1f, layout.canvasWidth * 0.001f)
            color = Color.argb(46, 15, 20, 24)
            canvas.drawRoundRect(photoRect, radius, radius, this)
        }
        if (preset == PhotoFramePreset.BRAND_GALLERY) {
            drawBrandGalleryBand(context, canvas, layout, brand, watermark)
        }
    }

    private fun drawBrandInsetMetadata(
        canvas: Canvas,
        photoRect: RectF,
        brand: String,
        details: String,
        occupiedWatermarkBounds: BrandFrameBounds?,
    ) {
        val shortEdge = min(photoRect.width(), photoRect.height())
        val brandPaint = brand.takeIf(String::isNotEmpty)?.let { text ->
            fittedBrandPaint(
                text = text,
                preferredSize = photoRect.width() * 0.043f,
                maxWidth = photoRect.width() * 0.72f,
                color = Color.WHITE,
            ).apply {
                setShadowLayer(
                    textSize * 0.13f,
                    0f,
                    textSize * 0.07f,
                    Color.argb(190, 0, 0, 0),
                )
            }
        }
        val detailPaint = details.takeIf(String::isNotEmpty)?.let { text ->
            fittedBrandDetailPaint(
                text = text,
                preferredSize = photoRect.width() * 0.021f,
                maxWidth = photoRect.width() * 0.78f,
            )
        }
        val rows = listOfNotNull(
            brandPaint?.let { textVisualBounds(brand, it) },
            detailPaint?.let { textVisualBounds(details, it) },
        )
        if (rows.isEmpty()) return
        val preferredAreaBottom = photoRect.bottom - shortEdge * 0.030f
        val blockHeight = rows.sumOf { (it.bottom - it.top).toDouble() }.toFloat() +
            shortEdge * 0.020f * (rows.size - 1).coerceAtLeast(0)
        val blockWidth = maxOf(
            brandPaint?.measureText(brand) ?: 0f,
            detailPaint?.measureText(details) ?: 0f,
        ).coerceAtLeast(1f)
        val area = placeBrandMetadataBlock(
            photo = photoRect.toBrandFrameBounds(),
            preferredBottom = preferredAreaBottom,
            blockHeight = blockHeight,
            blockWidth = blockWidth,
            occupied = occupiedWatermarkBounds,
            gap = shortEdge * 0.040f,
        )
        val baselines = centeredFrameTextBaselines(
            areaTop = area.top,
            areaBottom = area.bottom,
            rows = rows,
            preferredGap = shortEdge * 0.020f,
        )
        var row = 0
        if (brandPaint != null) {
            canvas.drawText(brand, photoRect.centerX(), baselines[row++], brandPaint)
        }
        if (detailPaint != null) {
            canvas.drawText(details, photoRect.centerX(), baselines[row], detailPaint)
        }
    }

    private fun drawBrandGalleryDetails(
        canvas: Canvas,
        photoRect: RectF,
        details: String,
        occupiedWatermarkBounds: BrandFrameBounds?,
    ) {
        if (details.isEmpty()) return
        val shortEdge = min(photoRect.width(), photoRect.height())
        val paint = fittedBrandDetailPaint(
            text = details,
            preferredSize = photoRect.width() * 0.021f,
            maxWidth = photoRect.width() * 0.78f,
        )
        val bounds = textVisualBounds(details, paint)
        val area = placeBrandMetadataBlock(
            photo = photoRect.toBrandFrameBounds(),
            preferredBottom = photoRect.bottom - shortEdge * 0.035f,
            blockHeight = bounds.bottom - bounds.top,
            blockWidth = paint.measureText(details).coerceAtLeast(1f),
            occupied = occupiedWatermarkBounds,
            gap = shortEdge * 0.040f,
        )
        val baseline = area.top - bounds.top
        canvas.drawText(details, photoRect.centerX(), baseline, paint)
    }

    private fun drawBrandGalleryBand(
        context: Context,
        canvas: Canvas,
        layout: PhotoFrameLayout,
        brand: String,
        watermark: PhotoFrameWatermark,
    ) {
        val band = RectF(
            0f,
            layout.photoBottom,
            layout.canvasWidth.toFloat(),
            layout.canvasHeight.toFloat(),
        )
        val bandWatermark = watermark.takeIf {
            it.enabled && it.content == PhotoFrameWatermarkContent.TEXT &&
                !it.position.isPhotoPlacement() &&
                it.position != PhotoFrameWatermarkPosition.AUTO
        }
        val brandPaint = brand.takeIf(String::isNotEmpty)?.let { text ->
            fittedBrandPaint(
                text = text,
                preferredSize = layout.canvasWidth * 0.052f,
                maxWidth = layout.canvasWidth * 0.72f,
                color = Color.rgb(15, 17, 19),
            )
        }
        var watermarkPaint = bandWatermark?.let { bandStyle ->
            createWatermarkPaint(
                context = context,
                canvas = canvas,
                preset = PhotoFramePreset.BRAND_GALLERY,
                watermark = if (bandStyle.color == PhotoFrameWatermarkColor.ADAPTIVE) {
                    bandStyle.copy(color = PhotoFrameWatermarkColor.BLACK)
                } else {
                    bandStyle
                },
                maxWidth = band.width() * 0.34f,
            )
        }
        val preferredGap = band.height() * 0.12f
        val availableTop = band.top + band.height() * 0.08f
        val availableBottom = band.bottom - band.height() * 0.10f
        val initialRows = listOfNotNull(
            watermarkPaint?.let {
                textVisualBounds(checkNotNull(bandWatermark).displayText, it)
            },
            brandPaint?.let { textVisualBounds(brand, it) },
        )
        if (initialRows.isEmpty()) return
        val gapAllowance = if (initialRows.size > 1) preferredGap else 0f
        val scale = frameTextScaleToFit(
            areaHeight = (availableBottom - availableTop - gapAllowance).coerceAtLeast(0f),
            rows = initialRows,
        )
        if (scale < 1f) {
            brandPaint?.let { it.textSize *= scale }
            watermarkPaint = watermarkPaint?.apply { textSize *= scale }
        }
        val rows = listOfNotNull(
            watermarkPaint?.let {
                textVisualBounds(checkNotNull(bandWatermark).displayText, it)
            },
            brandPaint?.let { textVisualBounds(brand, it) },
        )
        val baselines = centeredFrameTextBaselines(
            areaTop = availableTop,
            areaBottom = availableBottom,
            rows = rows,
            preferredGap = preferredGap,
        )
        var row = 0
        if (watermarkPaint != null && bandWatermark != null) {
            val (x, align) = watermarkHorizontalPlacement(
                band,
                PhotoFramePreset.BRAND_GALLERY,
                bandWatermark.position,
            )
            watermarkPaint.textAlign = align
            drawWatermarkText(
                canvas,
                bandWatermark.displayText,
                x,
                baselines[row++],
                watermarkPaint,
                bandWatermark,
            )
        }
        if (brandPaint != null) {
            canvas.drawText(brand, band.centerX(), baselines[row], brandPaint)
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
        metadata: PhotoFrameMetadata,
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
        drawPlaqueDecoration(context, canvas, layout, metadata, watermark)
    }

    /** Drawn after the photo layer, so neither the plaque band nor its text/watermark is filtered. */
    private fun drawPlaqueDecoration(
        context: Context,
        canvas: Canvas,
        layout: PhotoFrameLayout,
        metadata: PhotoFrameMetadata,
        watermark: PhotoFrameWatermark,
    ) {
        val metadataWatermark = watermark.withoutPhotoPlacement()
        val photoRect = RectF(
            layout.photoLeft,
            layout.photoTop,
            layout.photoRight,
            layout.photoBottom,
        )
        drawPhotoWatermark(context, canvas, photoRect, PhotoFramePreset.PLAQUE, watermark)

        val width = layout.canvasWidth.toFloat()
        val bandTop = layout.metadataTop
        val bandHeight = layout.canvasHeight - bandTop
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

        val make = metadata.make?.trim()
            ?.takeIf(String::isNotEmpty)
            ?.uppercase(Locale.ROOT)
        val model = metadata.model?.trim()?.takeIf(String::isNotEmpty)
        val details = frameDetailLine(metadata).takeIf(String::isNotEmpty)
        val date = metadata.dateTime?.takeIf(String::isNotEmpty)
        val leftPrimary = make ?: model
        val leftSecondary = model?.takeIf { make != null && !it.equals(make, ignoreCase = true) }
        val rightPrimary = details ?: date
        val rightSecondary = date?.takeIf { details != null }
        val hasLeft = leftPrimary != null
        val hasRight = rightPrimary != null
        val hasLeftBlock = hasLeft

        val leftX = width * 0.058f
        val leftMaxWidth = width * if (hasRight) 0.46f else 0.884f
        val rightX = width * if (hasLeftBlock) 0.60f else 0.058f
        val rightMaxWidth = width * if (hasLeftBlock) 0.35f else 0.884f
        val leftPrimaryPaint = leftPrimary?.let {
            createPlaqueTextPaint(
                text = it,
                preferredSize = width * 0.027f,
                maxWidth = leftMaxWidth,
                color = Color.rgb(18, 20, 21),
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL),
            )
        }
        val leftSecondaryPaint = leftSecondary?.let {
            createPlaqueTextPaint(
                text = it,
                preferredSize = width * 0.0165f,
                maxWidth = leftMaxWidth,
                color = Color.rgb(103, 106, 106),
                typeface = Typeface.create("sans-serif", Typeface.NORMAL),
            )
        }
        val rightPrimaryPaint = rightPrimary?.let {
            createPlaqueTextPaint(
                text = it,
                preferredSize = width * 0.0245f,
                maxWidth = rightMaxWidth,
                color = Color.rgb(18, 20, 21),
                typeface = Typeface.create("sans-serif", Typeface.NORMAL),
            )
        }
        val rightSecondaryPaint = rightSecondary?.let {
            createPlaqueTextPaint(
                text = it,
                preferredSize = width * 0.018f,
                maxWidth = rightMaxWidth,
                color = Color.rgb(103, 106, 106),
                typeface = Typeface.create("sans-serif", Typeface.NORMAL),
            )
        }
        val watermarkText = metadataWatermark.displayText
        val watermarkPaint = if (metadataWatermark.enabled) {
            createWatermarkPaint(
                context = context,
                canvas = canvas,
                preset = PhotoFramePreset.PLAQUE,
                watermark = metadataWatermark,
                maxWidth = width * 0.884f,
            )
        } else {
            null
        }
        var leftPrimaryBounds =
            if (leftPrimary != null && leftPrimaryPaint != null) {
                textVisualBounds(leftPrimary, leftPrimaryPaint)
            } else {
                null
            }
        var leftSecondaryBounds =
            if (leftSecondary != null && leftSecondaryPaint != null) {
                textVisualBounds(leftSecondary, leftSecondaryPaint)
            } else {
                null
            }
        var rightPrimaryBounds =
            if (rightPrimary != null && rightPrimaryPaint != null) {
                textVisualBounds(rightPrimary, rightPrimaryPaint)
            } else {
                null
            }
        var rightSecondaryBounds =
            if (rightSecondary != null && rightSecondaryPaint != null) {
                textVisualBounds(rightSecondary, rightSecondaryPaint)
            } else {
                null
            }
        var watermarkBounds = watermarkPaint?.let { textVisualBounds(watermarkText, it) }
        fun mergedRow(
            left: FrameTextVisualBounds?,
            right: FrameTextVisualBounds?,
        ): FrameTextVisualBounds? = when {
            left == null -> right
            right == null -> left
            else -> mergeTextVisualBounds(left, right)
        }
        var primaryRow = mergedRow(leftPrimaryBounds, rightPrimaryBounds)
        var secondaryRow = mergedRow(leftSecondaryBounds, rightSecondaryBounds)
        var rows = listOfNotNull(primaryRow, secondaryRow, watermarkBounds)
        if (rows.isEmpty()) return
        val rowScale = frameTextScaleToFit(bandHeight, rows)
        if (rowScale < 1f) {
            listOfNotNull(
                leftPrimaryPaint,
                leftSecondaryPaint,
                rightPrimaryPaint,
                rightSecondaryPaint,
                watermarkPaint,
            ).forEach { paint -> paint.textSize *= rowScale }
            leftPrimaryBounds = leftPrimary?.let { text ->
                leftPrimaryPaint?.let { textVisualBounds(text, it) }
            }
            leftSecondaryBounds = leftSecondary?.let { text ->
                leftSecondaryPaint?.let { textVisualBounds(text, it) }
            }
            rightPrimaryBounds = rightPrimary?.let { text ->
                rightPrimaryPaint?.let { textVisualBounds(text, it) }
            }
            rightSecondaryBounds = rightSecondary?.let { text ->
                rightSecondaryPaint?.let { textVisualBounds(text, it) }
            }
            watermarkBounds = watermarkPaint?.let { textVisualBounds(watermarkText, it) }
            primaryRow = mergedRow(leftPrimaryBounds, rightPrimaryBounds)
            secondaryRow = mergedRow(leftSecondaryBounds, rightSecondaryBounds)
            rows = listOfNotNull(primaryRow, secondaryRow, watermarkBounds)
        }
        val preferredGap = min(width * 0.0115f, bandHeight * 0.095f)
        val baselines = centeredFrameTextBaselines(
            areaTop = bandTop,
            areaBottom = layout.canvasHeight.toFloat(),
            rows = rows,
            preferredGap = preferredGap,
        )
        var rowIndex = 0
        val primaryBaseline = if (primaryRow != null) baselines[rowIndex++] else null
        val secondaryBaseline = if (secondaryRow != null) baselines[rowIndex++] else null
        val watermarkBaseline = if (watermarkBounds != null) baselines[rowIndex] else null

        if (hasLeftBlock && hasRight) {
            val metadataRows = listOfNotNull(primaryRow, secondaryRow)
            val metadataBaselines = listOfNotNull(primaryBaseline, secondaryBaseline)
            val (infoTop, infoBottom) = plaqueVisualExtent(metadataRows, metadataBaselines)
                ?: (bandTop to layout.canvasHeight.toFloat())
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.rgb(222, 224, 222)
                strokeWidth = maxOf(1f, width * 0.001f)
                val dividerPadding = bandHeight * 0.075f
                canvas.drawLine(
                    width * 0.575f,
                    (infoTop - dividerPadding).coerceAtLeast(bandTop + dividerPadding),
                    width * 0.575f,
                    (infoBottom + dividerPadding)
                        .coerceAtMost(layout.canvasHeight - dividerPadding),
                    this,
                )
            }
        }
        if (leftPrimary != null && leftPrimaryPaint != null && primaryBaseline != null) {
            canvas.drawText(leftPrimary, leftX, primaryBaseline, leftPrimaryPaint)
        }
        if (leftSecondary != null && leftSecondaryPaint != null && secondaryBaseline != null) {
            canvas.drawText(leftSecondary, leftX, secondaryBaseline, leftSecondaryPaint)
        }
        if (watermarkPaint != null && watermarkBaseline != null) {
            val band = RectF(0f, bandTop, width, layout.canvasHeight.toFloat())
            val (watermarkX, align) = watermarkHorizontalPlacement(
                band,
                PhotoFramePreset.PLAQUE,
                metadataWatermark.position,
            )
            watermarkPaint.textAlign = align
            drawWatermarkText(
                canvas,
                watermarkText,
                watermarkX,
                watermarkBaseline,
                watermarkPaint,
                metadataWatermark,
            )
        }
        if (rightPrimary != null && rightPrimaryPaint != null && primaryBaseline != null) {
            canvas.drawText(rightPrimary, rightX, primaryBaseline, rightPrimaryPaint)
        }
        if (
            rightSecondary != null &&
            rightSecondaryPaint != null &&
            secondaryBaseline != null
        ) {
            canvas.drawText(rightSecondary, rightX, secondaryBaseline, rightSecondaryPaint)
        }
    }

    private fun plaqueVisualExtent(
        rows: List<FrameTextVisualBounds>,
        baselines: List<Float>,
    ): Pair<Float, Float>? {
        if (rows.isEmpty()) return null
        require(rows.size == baselines.size)
        return rows.indices.minOf { baselines[it] + rows[it].top } to
            rows.indices.maxOf { baselines[it] + rows[it].bottom }
    }

    private fun createPlaqueTextPaint(
        text: String,
        preferredSize: Float,
        maxWidth: Float,
        color: Int,
        typeface: Typeface,
    ): Paint =
        Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
            this.color = color
            textSize = preferredSize
            this.typeface = typeface
            val measured = measureText(text)
            if (measured > maxWidth) textSize *= maxWidth / measured
        }

    private suspend fun saveRenderedToMediaStore(
        resolver: ContentResolver,
        source: PhotoFrameMediaStoreSource,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        borderEnabled: Boolean,
        filter: PhotoFilterSelection?,
        bitmap: Bitmap,
    ): PhotoFrameExportResult {
        val preferred = photoFrameOutputName(
            source.displayName,
            preset,
            watermark,
            borderEnabled = borderEnabled,
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
        filter: PhotoFilterSelection?,
        bitmap: Bitmap,
    ): PhotoFrameExportResult {
        val parentUri = destination.directoryUri
        val preferred = photoFrameOutputName(
            sourceName,
            preset,
            watermark,
            borderEnabled = borderEnabled,
            filter = filter,
        )
        // Reserve before touching the provider so concurrent exporters never select the same name.
        val name = reservePhotoFrameName(preferred, destination.occupiedNames)
        val tempName = photoFrameTempName(System.nanoTime())
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
        var tempStillExists = true
        var keepReservedName = false
        try {
            val written = resolver.openOutputStream(temp, "w")?.let { raw ->
                BufferedOutputStream(raw, COPY_BUFFER_BYTES).use { output ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, PHOTO_FRAME_JPEG_QUALITY, output)
                }
            } == true
            if (!written) error("Cannot write derived photo")
            copyRenderedExif(
                resolver = resolver,
                sourceUri = sourceUri,
                targetUri = temp,
                width = bitmap.width,
                height = bitmap.height,
            )
            // 压缩是不可中断的阻塞调用；若界面已销毁，在正式改名前响应取消，仅清理隐藏临时文件。
            currentCoroutineContext().ensureActive()

            // 正常 DocumentsProvider 走原子改名：系统杀进程时最多遗留隐藏临时文件，
            // 不会让图库出现半张损坏 JPG。改名损坏的定制系统再走完整文件复制回退。
            val renamed = try {
                DocumentsContract.renameDocument(resolver, temp, name)
            } catch (_: Exception) {
                null
            }
            if (renamed != null) {
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

internal fun PhotoFramePreset.isBrandFrame(): Boolean =
    this == PhotoFramePreset.BRAND_INSET || this == PhotoFramePreset.BRAND_GALLERY

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

private fun brandFrameCornerRadius(layout: PhotoFrameLayout): Float =
    (layout.photoRight - layout.photoLeft) * 0.014f

/** 照片与毛玻璃参数卡共用的圆角，随底部信息区高度等比缩放。 */
internal fun photoFrameCornerRadius(layout: PhotoFrameLayout): Float =
    (layout.canvasHeight - layout.metadataTop) * 0.26f

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
private const val BRAND_FRAME_RENDER_VERSION = 4

internal fun isPhotoFrameOutputName(name: String): Boolean =
    PHOTO_FRAME_OUTPUT_PATTERN.containsMatchIn(name)

/** 同一张本地原片、同一预设及同一水印配置对应的首选输出名。 */
internal fun photoFrameOutputName(
    sourceName: String,
    preset: PhotoFramePreset,
    watermark: PhotoFrameWatermark = PhotoFrameWatermark(),
    borderEnabled: Boolean = true,
    filter: PhotoFilterSelection? = null,
): String {
    // v2 调整了默认字体与透明度语义，所有成片都带配置摘要，避免误命中升级前旧图。
    val renderedWatermark = watermark.forBorderMode(borderEnabled)
    val decorationEnabled = borderEnabled || renderedWatermark.enabled
    val watermarkSuffix = if (decorationEnabled) {
        "_w${photoFrameWatermarkFingerprint(renderedWatermark, preset)}"
    } else {
        ""
    }
    val filterSuffix = filter?.let {
        "_f${it.preset.id.take(8)}i${it.normalizedIntensityPercent}"
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

/** 摘要只用于稳定区分成片配置，绝不把用户水印原文写入文件名。 */
internal fun photoFrameWatermarkFingerprint(
    watermark: PhotoFrameWatermark,
    preset: PhotoFramePreset,
): String {
    val identity = if (watermark.enabled) {
        val renderedPosition = resolvedWatermarkPosition(preset, watermark.position)
        buildList {
            add("v=$PHOTO_FRAME_WATERMARK_RENDER_VERSION")
            if (preset.isBrandFrame()) add("brand-v=$BRAND_FRAME_RENDER_VERSION")
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
    } else {
        "off"
    }
    return MessageDigest.getInstance("SHA-256")
        .digest(identity.toByteArray(Charsets.UTF_8))
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
    filter: PhotoFilterSelection? = null,
): Boolean {
    val pattern = photoFrameOutputPattern(sourceName, preset, watermark, borderEnabled, filter)
    return occupiedNames.any(pattern::matches)
}

internal fun isPhotoFrameOutputFor(
    name: String,
    sourceName: String,
    preset: PhotoFramePreset,
    watermark: PhotoFrameWatermark = PhotoFrameWatermark(),
    borderEnabled: Boolean = true,
    filter: PhotoFilterSelection? = null,
): Boolean = photoFrameOutputPattern(
    sourceName,
    preset,
    watermark,
    borderEnabled,
    filter,
).matches(name)

private fun photoFrameOutputPattern(
    sourceName: String,
    preset: PhotoFramePreset,
    watermark: PhotoFrameWatermark,
    borderEnabled: Boolean,
    filter: PhotoFilterSelection?,
): Regex {
    val preferred = photoFrameOutputName(sourceName, preset, watermark, borderEnabled, filter)
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
