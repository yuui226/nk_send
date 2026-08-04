package com.ztransfer.frame

import android.content.ContentResolver
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
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
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.exifinterface.media.ExifInterface
import androidx.core.content.res.ResourcesCompat
import com.ztransfer.R
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** 未完成的边框派生文件；仅在完整写入后改成正式名称，App 下次启动会清理遗留项。 */
internal const val PHOTO_FRAME_PART_PREFIX = ".nkframe_"
internal const val PHOTO_FRAME_OUTPUT_DIRECTORY = "ZTFrames"
private val PHOTO_FRAME_SESSION_PREFIX =
    "$PHOTO_FRAME_PART_PREFIX${UUID.randomUUID().toString().take(8)}_"
private const val PLAQUE_BAND_TO_WIDTH = 0.12f

/** 设置页可选的成片样式。名称是持久化键，不要随意改名。 */
enum class PhotoFramePreset(internal val fileSuffix: String) {
    MIST("mist"),
    CINEMA("dark"),
    MINIMAL("clean"),
    FROSTED("glass"),
    PLAQUE("plaque"),
}

/** 自定义水印选项。枚举名称会直接持久化，新增档位可以，已有名称不要修改。 */
enum class PhotoFrameWatermarkFont { SIGNATURE, ELEGANT, CALLIGRAPHY, SIMPLE, BOLD }

enum class PhotoFrameWatermarkContent { TEXT, IMAGE }

enum class PhotoFrameWatermarkSize { SMALL, MEDIUM, LARGE }

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

enum class PhotoFrameWatermarkOpacity { SUBTLE, STANDARD, STRONG }

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
    val font: PhotoFrameWatermarkFont = PhotoFrameWatermarkFont.ELEGANT,
    val size: PhotoFrameWatermarkSize = PhotoFrameWatermarkSize.MEDIUM,
    val position: PhotoFrameWatermarkPosition = PhotoFrameWatermarkPosition.AUTO,
    val color: PhotoFrameWatermarkColor = PhotoFrameWatermarkColor.ADAPTIVE,
    val opacity: PhotoFrameWatermarkOpacity = PhotoFrameWatermarkOpacity.STANDARD,
    val effect: PhotoFrameWatermarkEffect = PhotoFrameWatermarkEffect.AUTO,
) {
    val displayText: String
        get() = limitPhotoFrameWatermarkText(text.trim())
            .ifEmpty { DEFAULT_PHOTO_FRAME_WATERMARK_TEXT }
}

internal const val DEFAULT_PHOTO_FRAME_WATERMARK_TEXT = "ZTransfer"
internal const val MAX_PHOTO_FRAME_WATERMARK_LENGTH = 24
internal const val PHOTO_FRAME_WATERMARK_IMAGE_DIRECTORY = "photo-frame-watermarks"
private val PHOTO_FRAME_WATERMARK_IMAGE_HASH = Regex("[0-9a-f]{64}")
private val PHOTO_FRAME_WATERMARK_LINE_BREAKS = Regex("[\\r\\n\\t]+")

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
)

internal data class PhotoFrameDestination(
    val directoryUri: Uri,
    val occupiedNames: MutableSet<String>,
)

internal data class PhotoFrameLayout(
    val canvasWidth: Int,
    val canvasHeight: Int,
    val photoLeft: Float,
    val photoTop: Float,
    val photoRight: Float,
    val photoBottom: Float,
    val metadataTop: Float,
)

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

/**
 * 边框导出器：读取已传输原片，在原片外创建新画布并另存 JPG。
 *
 * 首版只接收 JPG/JPEG。Android 原生无法可靠解码各代 NEF，强行支持会在不同手机上产生
 * 黑图或方向错误；RAW+JPEG 拍摄时应选择 JPG 成员生成分享图。
 */
object PhotoFrameExporter {
    // 分享图保留 3200px 长边（常规 4:3 约 7.7MP），手机端观看和二次发布已有
    // 充足余量；相比 4096px 可把“解码原片 + 输出画布”的峰值内存降低约 39%，
    // 对 128/192MB heap 的旧机和定制系统更可靠。原片本身始终无损保留。
    private const val MAX_SOURCE_EDGE = 3200
    private const val JPEG_QUALITY = 95
    private const val COPY_BUFFER_BYTES = 256 * 1024
    private val EMPTY_METADATA =
        PhotoFrameMetadata(null, null, null, null, null, null)
    private val bundledTypefaceCache = mutableMapOf<PhotoFrameWatermarkFont, Typeface>()
    private val watermarkImageCache = linkedMapOf<String, Bitmap>()

    internal suspend fun export(
        context: Context,
        resolver: ContentResolver,
        destination: PhotoFrameDestination,
        sourceUri: Uri,
        sourceName: String,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
    ): Result<PhotoFrameExportResult> {
        return try {
            currentCoroutineContext().ensureActive()
            require(
                sourceName.substringAfterLast('.', "").lowercase(Locale.ROOT) in
                    setOf("jpg", "jpeg"),
            ) {
                "Only JPG/JPEG can be framed"
            }
            val metadata = readMetadata(resolver, sourceUri)
            val bitmap = decodeForFraming(resolver, sourceUri)
                ?: error("Cannot decode transferred original")
            val rendered = try {
                renderFrame(context, bitmap, metadata, preset, watermark)
            } finally {
                bitmap.recycle()
            }
            val saved = try {
                currentCoroutineContext().ensureActive()
                saveRendered(
                    resolver = resolver,
                    destination = destination,
                    sourceName = sourceName,
                    preset = preset,
                    watermark = watermark,
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
     * 在用户选择的保存目录下复用或创建固定成片目录，并只在首次准备时扫描一次已有名称。
     * 调用方按根目录缓存结果；边框线程单并发，后续名称由 [saveRendered] 增量登记。
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
            occupiedNames = listChildNames(resolver, treeUri, directoryUri).toMutableSet(),
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

    private fun decodeForFraming(resolver: ContentResolver, uri: Uri): Bitmap? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                return ImageDecoder.decodeBitmap(
                    ImageDecoder.createSource(resolver, uri),
                ) { decoder, info, _ ->
                    val width = info.size.width
                    val height = info.size.height
                    val scale = min(1f, MAX_SOURCE_EDGE.toFloat() / maxOf(width, height))
                    decoder.setTargetSize(
                        (width * scale).roundToInt().coerceAtLeast(1),
                        (height * scale).roundToInt().coerceAtLeast(1),
                    )
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
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
        while (maxOf(bounds.outWidth / sample, bounds.outHeight / sample) > MAX_SOURCE_EDGE) {
            sample *= 2
        }
        val decoded = resolver.openFileDescriptor(uri, "r")?.use {
            BitmapFactory.decodeFileDescriptor(
                it.fileDescriptor,
                null,
                BitmapFactory.Options().apply {
                    inSampleSize = sample
                    inPreferredConfig = Bitmap.Config.ARGB_8888
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
        return try {
            applyOrientation(decoded, orientation)
        } catch (error: Throwable) {
            decoded.recycle()
            throw error
        }
    }

    private fun applyOrientation(source: Bitmap, orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.setRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.setRotate(-90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
            else -> return source
        }
        val oriented = Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true)
        if (oriented !== source) source.recycle()
        return oriented
    }

    internal fun renderPreview(
        context: Context,
        source: Bitmap,
        metadata: PhotoFrameMetadata,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        longEdge: Int = 720,
    ): Bitmap = renderFrame(context, source, metadata, preset, watermark, longEdge)

    private fun renderFrame(
        context: Context,
        source: Bitmap,
        metadata: PhotoFrameMetadata,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        longEdge: Int = 3200,
    ): Bitmap {
        require(longEdge > 0)
        val layout = if (preset == PhotoFramePreset.PLAQUE) {
            calculatePlaqueFrameLayout(source.width, source.height, longEdge)
        } else {
            calculatePhotoFrameLayout(source.width, source.height, longEdge)
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
            drawBackdrop(canvas, source, preset)

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
        }
        // ShadowLayer 在 3200px 画布上直接做两次软件模糊代价很高。阴影本身没有
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
                }
            }
            PhotoFramePreset.PLAQUE -> canvas.drawColor(Color.WHITE)
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
                }
            }
            alpha = watermarkAlpha(watermark.opacity)
            textSize = shortEdge * when (watermark.size) {
                PhotoFrameWatermarkSize.SMALL -> 0.0105f
                PhotoFrameWatermarkSize.MEDIUM -> 0.0135f
                PhotoFrameWatermarkSize.LARGE -> 0.018f
            }
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
     * 资源异常时仍回退到系统字体，不能让一张分享图因为字体加载失败而中断导出。
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
        if (!watermark.enabled || !watermark.position.isPhotoPlacement()) return
        val safeInset = min(photoRect.width(), photoRect.height()) * 0.04f
        if (watermark.content == PhotoFrameWatermarkContent.IMAGE) {
            drawPhotoImageWatermark(
                context = context,
                canvas = canvas,
                photoRect = photoRect,
                safeInset = safeInset,
                watermark = watermark,
            )
            return
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
        drawWatermarkText(canvas, text, placement.originX, placement.baseline, paint, watermark)
    }

    private fun drawPhotoImageWatermark(
        context: Context,
        canvas: Canvas,
        photoRect: RectF,
        safeInset: Float,
        watermark: PhotoFrameWatermark,
    ) {
        val imageHash = requireNotNull(validPhotoFrameWatermarkImageHash(watermark.imageHash)) {
            "Image watermark has no valid private copy"
        }
        val bitmap = loadWatermarkImage(context, imageHash)
        val shortEdge = min(photoRect.width(), photoRect.height())
        var targetHeight = shortEdge * when (watermark.size) {
            PhotoFrameWatermarkSize.SMALL -> 0.035f
            PhotoFrameWatermarkSize.MEDIUM -> 0.052f
            PhotoFrameWatermarkSize.LARGE -> 0.075f
        }
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
        canvas.drawBitmap(
            bitmap,
            null,
            destination,
            Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG or Paint.DITHER_FLAG).apply {
                alpha = watermarkAlpha(watermark.opacity)
            },
        )
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
        val metadataWatermark = watermark.withoutPhotoPlacement()
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

    private suspend fun saveRendered(
        resolver: ContentResolver,
        destination: PhotoFrameDestination,
        sourceName: String,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        bitmap: Bitmap,
    ): PhotoFrameExportResult {
        val parentUri = destination.directoryUri
        val preferred = photoFrameOutputName(sourceName, preset, watermark)
        val name = uniqueName(preferred, destination.occupiedNames)
        val tempName = photoFrameTempName(System.nanoTime())
        val temp = DocumentsContract.createDocument(
            resolver,
            parentUri,
            "image/jpeg",
            tempName,
        ) ?: error("Cannot create framed photo")
        var tempStillExists = true
        try {
            val written = resolver.openOutputStream(temp, "w")?.let { raw ->
                BufferedOutputStream(raw, COPY_BUFFER_BYTES).use { output ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, output)
                }
            } == true
            if (!written) error("Cannot write framed photo")
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
                return PhotoFrameExportResult(
                    displayName = displayNameOf(resolver, renamed) ?: name,
                ).also { destination.occupiedNames.add(it.displayName) }
            }

            val copied = copyCompletedFrame(
                resolver = resolver,
                parentUri = parentUri,
                sourceUri = temp,
                requestedName = name,
            )
            return PhotoFrameExportResult(
                displayName = displayNameOf(resolver, copied) ?: name,
            ).also { destination.occupiedNames.add(it.displayName) }
        } finally {
            if (tempStillExists) {
                runCatching { DocumentsContract.deleteDocument(resolver, temp) }
            }
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
            ) ?: error("Cannot create framed photo")
            val input = resolver.openInputStream(sourceUri)
                ?: error("Cannot reopen completed frame")
            val copiedBytes = input.use { rawInput ->
                val output = resolver.openOutputStream(target, "w")
                    ?: error("Cannot write framed photo")
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
                error("Incomplete framed photo copy")
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
 * “铭牌”不建立固定比例的装饰画布，只在原片下方增加宽度约 12% 的信息带。
 * 最终长边仍限制在 [longEdge] 内，竖图会连同信息带一起缩放，避免输出意外超过 3200px。
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
internal fun watermarkAlpha(opacity: PhotoFrameWatermarkOpacity): Int = when (opacity) {
    PhotoFrameWatermarkOpacity.SUBTLE -> 102   // 40%
    PhotoFrameWatermarkOpacity.STANDARD -> 184 // 72%
    PhotoFrameWatermarkOpacity.STRONG -> 255   // 100%
}

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
        value.isNotEmpty() -> value
        else -> ""
    }
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
    pattern = "_frame_(${PhotoFramePreset.entries.joinToString("|") { preset ->
        Regex.escape(preset.fileSuffix)
    }})(?:_w[0-9a-f]{12})?(?: \\(\\d+\\)|_\\d+)?\\.jpe?g$",
    option = RegexOption.IGNORE_CASE,
)

private const val PHOTO_FRAME_WATERMARK_RENDER_VERSION = 2

internal fun isPhotoFrameOutputName(name: String): Boolean =
    PHOTO_FRAME_OUTPUT_PATTERN.containsMatchIn(name)

/** 同一张本地原片、同一预设及同一水印配置对应的首选输出名。 */
internal fun photoFrameOutputName(
    sourceName: String,
    preset: PhotoFramePreset,
    watermark: PhotoFrameWatermark = PhotoFrameWatermark(),
): String {
    // v2 调整了默认字体与透明度语义，所有成片都带配置摘要，避免误命中升级前旧图。
    val watermarkSuffix = "_w${photoFrameWatermarkFingerprint(watermark, preset)}"
    return "${File(sourceName).nameWithoutExtension}_frame_${preset.fileSuffix}$watermarkSuffix.jpg"
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
            add("on")
            add(watermark.content.name)
            add(watermark.size.name)
            add(renderedPosition.name)
            add("opacity=${watermark.opacity.name}")
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
    } else {
        "off"
    }
    return MessageDigest.getInstance("SHA-256")
        .digest(identity.toByteArray(Charsets.UTF_8))
        .take(6)
        .joinToString("") { byte -> "%02x".format(Locale.ROOT, byte.toInt() and 0xff) }
}

private fun resolvedWatermarkPosition(
    preset: PhotoFramePreset,
    requested: PhotoFrameWatermarkPosition,
): PhotoFrameWatermarkPosition = when (requested) {
    PhotoFrameWatermarkPosition.AUTO -> {
        if (preset == PhotoFramePreset.PLAQUE) {
            PhotoFrameWatermarkPosition.LEFT
        } else {
            PhotoFrameWatermarkPosition.CENTER
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
): Boolean {
    val pattern = photoFrameOutputPattern(sourceName, preset, watermark)
    return occupiedNames.any(pattern::matches)
}

internal fun isPhotoFrameOutputFor(
    name: String,
    sourceName: String,
    preset: PhotoFramePreset,
    watermark: PhotoFrameWatermark = PhotoFrameWatermark(),
): Boolean = photoFrameOutputPattern(sourceName, preset, watermark).matches(name)

private fun photoFrameOutputPattern(
    sourceName: String,
    preset: PhotoFramePreset,
    watermark: PhotoFrameWatermark,
): Regex {
    val preferred = photoFrameOutputName(sourceName, preset, watermark)
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
