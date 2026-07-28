package com.ztransfer.frame

import android.content.ContentResolver
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
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.exifinterface.media.ExifInterface
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
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

/** 设置页可选的成片样式。名称是持久化键，不要随意改名。 */
enum class PhotoFramePreset(internal val fileSuffix: String) {
    MIST("mist"),
    CINEMA("dark"),
    MINIMAL("clean"),
    FROSTED("glass"),
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
)

internal data class PhotoFrameTextRows(
    val title: Float?,
    val details: Float?,
    val branding: Float?,
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

    internal suspend fun export(
        resolver: ContentResolver,
        destination: PhotoFrameDestination,
        sourceUri: Uri,
        sourceName: String,
        preset: PhotoFramePreset,
        showBranding: Boolean,
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
                renderFrame(bitmap, metadata, preset, showBranding)
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

    private fun renderFrame(
        source: Bitmap,
        metadata: PhotoFrameMetadata,
        preset: PhotoFramePreset,
        showBranding: Boolean,
    ): Bitmap {
        val layout = calculatePhotoFrameLayout(source.width, source.height)
        val output = Bitmap.createBitmap(
            layout.canvasWidth,
            layout.canvasHeight,
            Bitmap.Config.ARGB_8888,
        )
        try {
            val canvas = Canvas(output)
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

            drawMetadata(canvas, layout, metadata, preset, showBranding)
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
                }
            }
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
        canvas: Canvas,
        layout: PhotoFrameLayout,
        metadata: PhotoFrameMetadata,
        preset: PhotoFramePreset,
        showBranding: Boolean,
    ) {
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
        val rows = photoFrameTextRows(hasTitle, hasDetails, showBranding)
        val centerX = layout.canvasWidth / 2f
        val bandHeight = layout.canvasHeight - layout.metadataTop
        val brandBaseline = rows.title?.let { layout.metadataTop + bandHeight * it }
        if (
            preset == PhotoFramePreset.FROSTED &&
            (hasTitle || hasDetails || showBranding)
        ) {
            drawFrostedMetadataPanel(canvas, layout, bandHeight)
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
        val totalWidth = brandPaint.measureText(brand) + gap + modelPaint.measureText(model)
        var x = centerX - totalWidth / 2f
        if (brand.isNotEmpty() && brandBaseline != null) {
            canvas.drawText(brand, x, brandBaseline, brandPaint)
            x += brandPaint.measureText(brand) + gap
        }
        if (model.isNotEmpty() && brandBaseline != null) {
            canvas.drawText(model, x, brandBaseline, modelPaint)
        }

        if (hasDetails && rows.details != null) {
            val detailPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = mutedColor
                textSize = layout.canvasWidth * 0.020f
                typeface = Typeface.create("sans-serif", Typeface.NORMAL)
                textAlign = Paint.Align.CENTER
            }
            val maxDetailWidth = layout.canvasWidth *
                if (preset == PhotoFramePreset.FROSTED) 0.76f else 0.82f
            val detailWidth = detailPaint.measureText(details)
            if (detailWidth > maxDetailWidth) {
                detailPaint.textSize *= maxDetailWidth / detailWidth
            }
            val detailBaseline = layout.metadataTop + bandHeight * rows.details
            canvas.drawText(details, centerX, detailBaseline, detailPaint)
        }

        rows.branding?.let { brandingRow ->
            drawBranding(
                canvas = canvas,
                centerX = centerX,
                baseline = layout.metadataTop + bandHeight * brandingRow,
                preset = preset,
            )
        }
    }

    private fun drawFrostedMetadataPanel(
        canvas: Canvas,
        layout: PhotoFrameLayout,
        bandHeight: Float,
    ) {
        val horizontalInset = layout.canvasWidth * 0.072f
        val verticalInset = bandHeight * 0.08f
        val panel = RectF(
            horizontalInset,
            layout.metadataTop + verticalInset,
            layout.canvasWidth - horizontalInset,
            layout.canvasHeight - verticalInset,
        )
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

    private fun drawBranding(
        canvas: Canvas,
        centerX: Float,
        baseline: Float,
        preset: PhotoFramePreset,
    ) {
        val shortEdge = min(canvas.width, canvas.height).toFloat()
        Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
            color = when (preset) {
                PhotoFramePreset.MIST,
                PhotoFramePreset.CINEMA -> Color.argb(108, 250, 252, 253)
                PhotoFramePreset.MINIMAL,
                PhotoFramePreset.FROSTED -> Color.argb(82, 24, 31, 38)
            }
            textSize = shortEdge * 0.0135f
            // 保留紧凑完整的品牌名，只用轻盈的衬线斜体增加摄影签名感。
            typeface = Typeface.create("serif", Typeface.ITALIC)
            textAlign = Paint.Align.CENTER
            canvas.drawText(
                "ZTransfer",
                centerX,
                baseline,
                this,
            )
        }
    }

    private suspend fun saveRendered(
        resolver: ContentResolver,
        destination: PhotoFrameDestination,
        sourceName: String,
        preset: PhotoFramePreset,
        bitmap: Bitmap,
    ): PhotoFrameExportResult {
        val parentUri = destination.directoryUri
        val stem = File(sourceName).nameWithoutExtension
        val preferred = "${stem}_frame_${preset.fileSuffix}.jpg"
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

/** 照片与毛玻璃参数卡共用的圆角，随底部信息区高度等比缩放。 */
internal fun photoFrameCornerRadius(layout: PhotoFrameLayout): Float =
    (layout.canvasHeight - layout.metadataTop) * 0.26f

/**
 * 完整信息时排成三行；高级版关闭品牌后自动把两行内容重新居中。
 * 元数据缺项时也会收拢现有行，避免为不存在的行预留空位。
 */
internal fun photoFrameTextRows(
    hasTitle: Boolean,
    hasDetails: Boolean,
    showBranding: Boolean,
): PhotoFrameTextRows = when {
    showBranding && hasTitle && hasDetails ->
        PhotoFrameTextRows(title = 0.41f, details = 0.65f, branding = 0.84f)
    showBranding && hasTitle ->
        PhotoFrameTextRows(title = 0.48f, details = null, branding = 0.78f)
    showBranding && hasDetails ->
        PhotoFrameTextRows(title = null, details = 0.48f, branding = 0.78f)
    showBranding ->
        PhotoFrameTextRows(title = null, details = null, branding = 0.58f)
    hasTitle && hasDetails ->
        PhotoFrameTextRows(title = 0.46f, details = 0.70f, branding = null)
    hasTitle ->
        PhotoFrameTextRows(title = 0.58f, details = null, branding = null)
    hasDetails ->
        PhotoFrameTextRows(title = null, details = 0.58f, branding = null)
    else ->
        PhotoFrameTextRows(title = null, details = null, branding = null)
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
    ).joinToString("  ")

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
    }})(?: \\(\\d+\\)|_\\d+)?\\.jpe?g$",
    option = RegexOption.IGNORE_CASE,
)

internal fun isPhotoFrameOutputName(name: String): Boolean =
    PHOTO_FRAME_OUTPUT_PATTERN.containsMatchIn(name)

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
