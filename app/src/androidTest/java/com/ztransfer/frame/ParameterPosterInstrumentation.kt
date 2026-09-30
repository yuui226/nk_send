package com.ztransfer.frame

import android.app.Activity
import android.app.Instrumentation
import android.content.ContentUris
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import android.os.Bundle
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface
import com.ztransfer.R
import kotlinx.coroutines.runBlocking
import java.io.File

class ParameterPosterInstrumentation : Instrumentation() {
    private var geometryOnly = false
    private var exportsOnly = false
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        geometryOnly = arguments?.getString("geometryOnly") == "true"
        exportsOnly = arguments?.getString("exportsOnly") == "true"
        start()
    }
    override fun onStart() {
        val result = Bundle()
        try {
            val dir = File(targetContext.filesDir, "parameter-poster-tests").apply { mkdirs() }
            val decoded = BitmapFactory.decodeResource(targetContext.resources, R.raw.debug_sample_01, BitmapFactory.Options().apply { inSampleSize = 4 })
            val orientation = targetContext.resources.openRawResource(R.raw.debug_sample_01).use {
                ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            }
            val rotation = when (orientation) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
            val upright = if (rotation != 0f) {
                Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, Matrix().apply { postRotate(rotation) }, true)
            } else decoded
            val portrait = Bitmap.createScaledBitmap(upright, 600, 900, true)
            if (upright !== decoded) upright.recycle()
            decoded.recycle()
            val landscape = Bitmap.createBitmap(portrait, 0, 200, 600, 400)
            val metadata = PhotoFrameMetadata("NIKON", "NIKON Z f", "f/2.8", "1/250", "ISO100", "50mm",
                lensModel = "NIKKOR Z 70-200mm f/2.8 VR S", latitude = 30.25, longitude = 120.15,
                altitudeMeters = 520.0, city = "光影市", region = "蓝调区", dateTime = "2026:09:20 14:32:08")
            // Narrowing must not spend the space reclaimed from smaller type on larger gaps.
            for (common in listOf(PhotoFramePreset.MIST, PhotoFramePreset.CINEMA,
                PhotoFramePreset.MINIMAL, PhotoFramePreset.FROSTED)) {
                var previousGaps: List<Float>? = null
                for (percent in listOf(99, 90, 80, 70, 60)) {
                    val layout = PhotoFrameExporter.calculateMeasuredFrame(targetContext, 1000, 1500,
                        common, percent, metadata, PhotoFrameWatermark(enabled = false))
                    val rows = checkNotNull(layout.textLayout).items.groupBy { it.baseline }.values.toList()
                    val gaps = rows.zipWithNext { a, b ->
                        b.minOf { it.baseline + it.run.bounds.top } -
                            a.maxOf { it.baseline + it.run.bounds.bottom }
                    }
                    previousGaps?.let { previous ->
                        check(previous.size == gaps.size)
                        check(gaps.indices.all { gaps[it] <= previous[it] + 0.05f }) {
                            "$common $percent: narrowing increased line gaps: $previous -> $gaps"
                        }
                    }
                    previousGaps = gaps
                }
            }
            // AUTO uses the same left-aligned signature as the default-width plaque.
            for (percent in listOf(90, 80, 70, 60)) {
                val plans = listOf(PhotoFrameWatermarkPosition.AUTO, PhotoFrameWatermarkPosition.LEFT).map { position ->
                    val layout = PhotoFrameExporter.calculateMeasuredFrame(targetContext, 1000, 1500,
                        PhotoFramePreset.PLAQUE, percent, metadata,
                        PhotoFrameWatermark(enabled = true, text = "Signature", position = position))
                    checkNotNull(layout.textLayout).items.filter { it.run.watermark != null }
                }
                check(plans[0].isNotEmpty() && plans[0].size == plans[1].size)
                plans[0].zip(plans[1]).forEach { (auto, left) ->
                    check(kotlin.math.abs(auto.x - left.x) < 0.01f &&
                        kotlin.math.abs(auto.baseline - left.baseline) < 0.01f) {
                        "Plaque $percent: AUTO signature must retain LEFT placement"
                    }
                    check(kotlin.math.abs(auto.x + auto.run.left - 58f) < 0.05f)
                }
            }
            for ((w, h) in listOf(1500 to 1000, 1000 to 1500, 1000 to 1000, 2400 to 1000, 1000 to 2400)) {
                for (percent in 60..200 step 10) {
                    val layout = PhotoFrameExporter.calculateMeasuredFrame(targetContext, w, h,
                        PhotoFramePreset.PLAQUE, percent, metadata,
                        PhotoFrameWatermark(enabled = true, text = "Signature"))
                    verifyCompactLayout(layout)
                    val leftRows = checkNotNull(layout.textLayout).items.filter { it.x < 575f }
                        .groupBy { it.baseline }.values.toList()
                    val gaps = leftRows.zipWithNext { a, b ->
                        b.minOf { it.baseline + it.run.bounds.top } - a.maxOf { it.baseline + it.run.bounds.bottom }
                    }
                    check(gaps.isNotEmpty() && gaps.max() - gaps.min() < 0.05f) {
                        "Plaque $w/$h $percent: unequal left column gaps $gaps"
                    }
                }
            }
            for (percent in listOf(90, 80, 70, 60)) {
                val inset = PhotoFrameExporter.calculateMeasuredFrame(targetContext, 1000, 1500,
                    PhotoFramePreset.BRAND_INSET, percent, metadata, PhotoFrameWatermark(enabled = false))
                val lens = checkNotNull(inset.photoTextLayout).items.first { it.run.text.contains("NIKKOR") }
                check(lens.run.paint.typeface == android.graphics.Typeface.create(
                    "sans-serif-condensed", android.graphics.Typeface.BOLD_ITALIC))
                val archive = PhotoFrameExporter.calculateMeasuredFrame(targetContext, 1000, 1500,
                    PhotoFramePreset.COLOR_ARCHIVE, percent, metadata, PhotoFrameWatermark(enabled = false))
                val archiveRows = checkNotNull(archive.textLayout).items.groupBy { it.baseline }.values.toList()
                val gapLimit = (calculateOriginalQualityFrameLayout(1000, 1500, PhotoFramePreset.COLOR_ARCHIVE)
                    .let { it.canvasHeight - it.photoBottom }) * 0.055f * percent / 100f
                archiveRows.zipWithNext().forEach { (a, b) ->
                    val gap = b.minOf { it.baseline + it.run.bounds.top } - a.maxOf { it.baseline + it.run.bounds.bottom }
                    check(gap <= gapLimit + 0.05f) { "Archive $percent: gap increased $gap > $gapLimit" }
                }
            }
            // There is no rendering-path change at 100%. Check geometry AND typography.
            for (frame in PhotoFramePreset.entries.filter { it != PhotoFramePreset.IMMERSIVE }) {
                for ((w, h) in listOf(1500 to 1000, 1000 to 1500, 1000 to 1000, 2400 to 1000, 1000 to 2400)) {
                    var previous: PhotoFrameLayout? = null
                    for (percent in listOf(60, 80, 90, 99, 100, 101, 110, 150, 200)) {
                        val current = PhotoFrameExporter.calculateMeasuredFrame(targetContext, w, h, frame,
                            percent, metadata, PhotoFrameWatermark(enabled = false))
                        verifyCompactLayout(current)
                        check(kotlin.math.abs(current.photoRight - current.photoLeft - w) < 0.05f)
                        check(kotlin.math.abs(current.photoBottom - current.photoTop - h) < 0.05f)
                        if (percent == 100 || percent == 101) previous?.let { old ->
                            check(kotlin.math.abs(current.canvasWidth - old.canvasWidth) < w * 0.05f)
                            check(kotlin.math.abs(current.canvasHeight - old.canvasHeight) < h * 0.05f)
                            for ((before, after) in listOf(old.textLayout to current.textLayout,
                                old.photoTextLayout to current.photoTextLayout)) {
                                if (before != null && after != null) {
                                    check(before.items.map { it.run.text } == after.items.map { it.run.text }) {
                                        "$frame $w/$h $percent changed text at default boundary"
                                    }
                                    before.items.zip(after.items).forEach { (a, b) ->
                                        check(a.run.paint.typeface == b.run.paint.typeface)
                                        check(kotlin.math.abs(a.run.paint.textSize - b.run.paint.textSize) < 0.01f)
                                        check(kotlin.math.abs(a.x - b.x) < 30f && kotlin.math.abs(a.baseline - b.baseline) < 30f)
                                    }
                                }
                            }
                        }
                        previous = current
                    }
                }
            }
            for ((w, h) in listOf(1500 to 1000, 1000 to 1500, 1000 to 1000, 2400 to 1000)) {
                for (percent in 60..200 step 10) {
                    val layout = PhotoFrameExporter.calculateMeasuredFrame(targetContext, w, h,
                        PhotoFramePreset.FROSTED, percent, metadata,
                        PhotoFrameWatermark(enabled = true, text = "Signature"))
                    val panel = PhotoFrameExporter.frostedMetadataPanelBounds(layout)
                    check(panel.left == layout.photoLeft && panel.right == layout.photoRight)
                    for (item in checkNotNull(layout.textLayout).items) {
                        val left = (item.x + item.run.left) * layout.textLayoutScale
                        val right = left + item.run.width * layout.textLayoutScale
                        check(left >= panel.left && right <= panel.right)
                    }
                    verifyCompactLayout(layout)
                }
            }
            val preset = PhotoFramePreset.PARAMETER_POSTER
            val defaults = defaultPhotoFrameMetadataSettings(preset)
            val all = defaults.copy(showLensModel = true, showCoordinates = true, showAltitude = true, showCity = true, showRegion = true, showDate = true, showTime = true)
            if (!geometryOnly && !exportsOnly) {
            for ((name, source, settings) in listOf(
                Triple("portrait-default", portrait, defaults),
                Triple("portrait-all", portrait, all),
                Triple("landscape-all", landscape, all),
                Triple("portrait-reference", portrait, defaults.copy(showModel = false, showFocalLength = false)),
                Triple("portrait-off", portrait, all.copy(showBrand = false, showModel = false, showExposure = false, showFocalLength = false, showLensModel = false, showCoordinates = false, showAltitude = false, showCity = false, showRegion = false, showDate = false, showTime = false)),
            )) {
                val rendered = PhotoFrameExporter.renderPreview(targetContext, source, metadata, preset,
                    PhotoFrameWatermark(enabled = false), metadataSettings = settings, longEdge = 1440, previewPlaceholders = false)
                File(dir, "$name.png").outputStream().use { rendered.compress(Bitmap.CompressFormat.PNG, 100, it) }
                rendered.recycle()
            }
            // Check every compact detent, preserving original photo dimensions.
            for ((orientationName, source) in listOf("portrait" to portrait, "landscape" to landscape)) {
                for (percent in listOf(90, 80, 70, 60)) {
                    for ((densityName, settings) in listOf("all" to all, "brand" to all.copy(
                        showModel = false, showExposure = false, showFocalLength = false,
                        showLensModel = false, showCoordinates = false, showAltitude = false,
                        showCity = false, showRegion = false, showDate = false, showTime = false,
                        brandStyle = PhotoFrameBrandStyle.LOGO,
                    ))) {
                        val presented = metadata.withPresentation(settings)
                        val layout = calculateMeasuredParameterPosterLayout(source.width, source.height, percent, presented)
                        check(layout.photoRight - layout.photoLeft == source.width.toFloat())
                        check(layout.photoBottom - layout.photoTop == source.height.toFloat())
                        val plan = checkNotNull(layout.posterLayout)
                        plan.columns.forEach { column ->
                            check(column.scale == 1f)
                            check(column.area.top >= 0f && column.area.left >= 0f)
                            check(column.area.right * layout.posterLayoutScale <= layout.canvasWidth + 1)
                            check(column.area.bottom * layout.posterLayoutScale <= layout.canvasHeight + 1)
                        }
                        val output = PhotoFrameExporter.renderPreview(targetContext, source, metadata, preset,
                            PhotoFrameWatermark(enabled = false), metadataSettings = settings.copy(widthPercent = percent),
                            longEdge = 1440, previewPlaceholders = false)
                        File(dir, "compact-$orientationName-$densityName-$percent.png").outputStream().use {
                            output.compress(Bitmap.CompressFormat.PNG, 100, it)
                        }
                        output.recycle()
                    }
                }
            }
            for (common in PhotoFramePreset.entries.filter { it != PhotoFramePreset.IMMERSIVE && it != PhotoFramePreset.PARAMETER_POSTER }) {
                for ((orientationName, source) in listOf("portrait" to portrait, "landscape" to landscape)) {
                    for (percent in listOf(200, 150, 110, 100, 90, 80, 70, 60)) {
                        for (logoOnly in listOf(false, true)) {
                            val settings = all.copy(widthPercent = percent, showBrand = true,
                                showModel = !logoOnly, showExposure = !logoOnly, showFocalLength = !logoOnly,
                                showLensModel = !logoOnly, showCoordinates = !logoOnly, showAltitude = !logoOnly,
                                showCity = !logoOnly, showRegion = !logoOnly, showDate = !logoOnly, showTime = !logoOnly,
                                brandStyle = if (logoOnly) PhotoFrameBrandStyle.LOGO else PhotoFrameBrandStyle.TEXT)
                            if (percent in 60..200) {
                                val measured = PhotoFrameExporter.calculateMeasuredFrame(targetContext, source.width, source.height,
                                    common, percent, metadata.withPresentation(settings),
                                    PhotoFrameWatermark(enabled = !logoOnly, text = "Light and Shadow"))
                                verifyCompactLayout(measured)
                            }
                            val output = PhotoFrameExporter.renderPreview(targetContext, source, metadata, common,
                                PhotoFrameWatermark(enabled = !logoOnly, text = "Light and Shadow"), metadataSettings = settings,
                                longEdge = 1440, previewPlaceholders = false)
                            File(dir, "compact-${common.name}-$orientationName-$logoOnly-$percent.png").outputStream().use {
                                output.compress(Bitmap.CompressFormat.PNG, 100, it)
                            }
                            output.recycle()
                        }
                    }
                }
            }
            }
            val none = all.copy(showBrand = false, showModel = false, showFocalLength = false,
                showExposure = false, showLensModel = false, showDate = false, showTime = false,
                showCoordinates = false, showAltitude = false, showCity = false, showRegion = false)
            val individualFields = listOf(none, none.copy(showBrand = true),
                none.copy(showBrand = true, brandStyle = PhotoFrameBrandStyle.LOGO), none.copy(showModel = true),
                none.copy(showFocalLength = true), none.copy(showExposure = true), none.copy(showLensModel = true),
                none.copy(showDate = true), none.copy(showTime = true), none.copy(showCoordinates = true),
                none.copy(showAltitude = true), none.copy(showCity = true), none.copy(showRegion = true), all)
            for (testPreset in PhotoFramePreset.entries.filter { it != PhotoFramePreset.IMMERSIVE }) {
                for (settings in individualFields + defaultPhotoFrameMetadataSettings(testPreset)) {
                    for ((w, h) in listOf(1800 to 1200, 1200 to 1800)) {
                        verifyCompactLayout(PhotoFrameExporter.calculateMeasuredFrame(targetContext, w, h, testPreset, 60,
                            metadata.withPresentation(settings), PhotoFrameWatermark(enabled = false)))
                    }
                }
            }
            val watermarkHash = "b03dc32041414b55a3a34b0ce3d351799c8c236ff4994d04af33ebd63f72ba6f"
            val watermarkFile = photoFrameWatermarkImageFile(targetContext, watermarkHash)
            watermarkFile.parentFile!!.mkdirs()
            val watermarkBitmap = Bitmap.createBitmap(128, 64, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.WHITE) }
            watermarkFile.outputStream().use { watermarkBitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            watermarkBitmap.recycle()
            try {
                for (testPreset in PhotoFramePreset.entries.filter { it != PhotoFramePreset.IMMERSIVE }) {
                    for (position in PhotoFrameWatermarkPosition.entries) {
                        for (content in PhotoFrameWatermarkContent.entries) {
                            val watermark = PhotoFrameWatermark(enabled = true, text = "Light and Shadow",
                                content = content, imageHash = watermarkHash, sizePercent = 300, position = position)
                            // Image watermarks use photo positions in the editor.
                            if (content == PhotoFrameWatermarkContent.IMAGE && !position.isPhotoPlacement()) continue
                            verifyCompactLayout(PhotoFrameExporter.calculateMeasuredFrame(targetContext, 1800, 1200,
                                testPreset, 60, metadata.withPresentation(all), watermark))
                        }
                    }
                }
            } finally { watermarkFile.delete() }
            // Geometry-only stress cases avoid allocating giant canvases while covering every brand,
            // unusual aspect ratios, long Unicode text, and the inner-photo brand/watermark lane.
            for (testPreset in PhotoFramePreset.entries.filter { it != PhotoFramePreset.IMMERSIVE }) {
                for ((w, h) in listOf(6000 to 4000, 4000 to 6000, 4000 to 4000, 6000 to 1000, 1000 to 6000, 80 to 120)) {
                    val settings = all.copy(widthPercent = 60, brandStyle = PhotoFrameBrandStyle.LOGO)
                    for (make in listOf("Nikon") + BrandLogoPaths.vectors.keys) {
                        val value = metadata.copy(make = make, model = "$make Professional 2026",
                            lensModel = "35-150mm f/2-2.8 Di III VXD · 镜头 👩🏽‍💻 é",
                            city = "Light and Shadow Photography City", region = "Blue Hour District").withPresentation(settings)
                        val measured = PhotoFrameExporter.calculateMeasuredFrame(targetContext, w, h, testPreset, 60,
                            value, PhotoFrameWatermark(enabled = true, text = "Light and Shadow", sizePercent = 100))
                        verifyCompactLayout(measured)
                        check(measured.photoRight - measured.photoLeft == w.toFloat())
                        check(measured.photoBottom - measured.photoTop == h.toFloat())
                    }
                }
            }
            if (!geometryOnly) {
            val longText = metadata.copy(make = "Hasselblad", model = "Hasselblad X2D 100C",
                lensModel = "Hasselblad XCD 35-75mm f/3.5-4.5 Zoom Lens", city = "Light & Shadow City", region = "Blue Hour District")
            val stress = PhotoFrameExporter.renderPreview(targetContext, portrait, longText, preset,
                PhotoFrameWatermark(enabled = true, text = "ZTransfer"), metadataSettings = all,
                longEdge = 1440, previewPlaceholders = false)
            File(dir, "portrait-long.png").outputStream().use { stress.compress(Bitmap.CompressFormat.PNG, 100, it) }
            stress.recycle()
            // Export real JPEGs through region decoding and MediaStore, with EXIF metadata.
            // This catches normalization accidentally restoring a compact setting to 100%.
            val multiTile = Bitmap.createScaledBitmap(portrait, 1800, 2700, true)
            for ((name, source) in listOf("portrait" to portrait, "landscape" to landscape, "multi-tile" to multiTile)) {
                val file = File(dir, "source-$name.jpg")
                file.outputStream().use { source.compress(Bitmap.CompressFormat.JPEG, 95, it) }
                ExifInterface(file).apply {
                    setAttribute(ExifInterface.TAG_MAKE, "NIKON")
                    setAttribute(ExifInterface.TAG_MODEL, "NIKON Z f")
                    setAttribute(ExifInterface.TAG_LENS_MODEL, "NIKKOR Z 70-200mm f/2.8 VR S")
                    setAttribute(ExifInterface.TAG_F_NUMBER, "2.8")
                    setAttribute(ExifInterface.TAG_EXPOSURE_TIME, "0.004")
                    setAttribute(ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY, "100")
                    setAttribute(ExifInterface.TAG_FOCAL_LENGTH, "50")
                    setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, "2026:09:20 14:32:08")
                    saveAttributes()
                }
                val originalBytes = file.readBytes()
                val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                val resolver = targetContext.contentResolver
                val actualMetadata = PhotoFrameExporter.readPreviewMetadata(resolver, Uri.fromFile(file))
                val exportPresets = if (name == "multi-tile") listOf(PhotoFramePreset.MIST,
                    PhotoFramePreset.PARAMETER_POSTER, PhotoFramePreset.BRAND_GALLERY) else
                    PhotoFramePreset.entries.filter { it != PhotoFramePreset.IMMERSIVE }
                for (exportPreset in exportPresets) {
                    for (percent in if (name == "multi-tile") listOf(60) else listOf(60, 80, 100, 110, 200)) {
                        val exportSettings = all.copy(widthPercent = percent, showCity = false, showRegion = false)
                        val watermark = PhotoFrameWatermark(enabled = false)
                        val exported = runBlocking {
                            PhotoFrameExporter.exportBesideSource(targetContext, resolver,
                                PhotoFrameMediaStoreSource(Uri.fromFile(file), file.name, collection, collection,
                                    "Pictures/ZTransferTests/", null, mutableSetOf()),
                                exportPreset, watermark, metadataSettings = exportSettings)
                        }.getOrThrow()
                        resolver.query(collection, arrayOf(MediaStore.Images.Media._ID),
                            "${MediaStore.Images.Media.DISPLAY_NAME} = ?", arrayOf(exported.displayName), null)!!.use { cursor ->
                            check(cursor.moveToFirst())
                            val uri = ContentUris.withAppendedId(collection, cursor.getLong(0))
                            try {
                                val decodedOutput = resolver.openInputStream(uri)!!.use { BitmapFactory.decodeStream(it) }
                                checkNotNull(decodedOutput)
                                val expected = PhotoFrameExporter.calculateMeasuredFrame(targetContext,
                                    source.width, source.height, exportPreset, percent,
                                    actualMetadata.withPresentation(exportSettings), watermark)
                                check(decodedOutput.width == expected.canvasWidth && decodedOutput.height == expected.canvasHeight) {
                                    "$exportPreset $name $percent export size mismatch"
                                }
                                File(dir, "export-${exportPreset.name}-$name-$percent.jpg").outputStream().use { stream ->
                                    resolver.openInputStream(uri)!!.use { it.copyTo(stream) }
                                }
                                decodedOutput.recycle()
                            } finally { resolver.delete(uri, null, null) }
                        }
                        check(originalBytes.contentEquals(file.readBytes())) { "Export modified the source" }
                    }
                }
            }
            multiTile.recycle()
            }
            landscape.recycle(); portrait.recycle()
            result.putString("result", if (geometryOnly) "PASS: every field alone, empty/default/full information, all brands and maximum watermarks"
                else "PASS: unified-frame fixtures, measured bounds, 133 JPEG region exports including multi-tile, unchanged originals")
            result.putString("images", dir.absolutePath)
            finish(Activity.RESULT_OK, result)
        } catch (error: Throwable) {
            result.putString("failure", error.stackTraceToString())
            finish(Activity.RESULT_CANCELED, result)
        }
    }
    private fun verifyCompactLayout(layout: PhotoFrameLayout) {
        layout.photoTextLayout?.let { plan ->
            val height = (layout.photoBottom - layout.photoTop) / (layout.photoRight - layout.photoLeft) * 1000f
            verifyTextPlan(plan, 1f, 1000f, height)
        }
        val plan = layout.textLayout ?: return
        verifyTextPlan(plan, layout.textLayoutScale, layout.canvasWidth.toFloat(), layout.canvasHeight.toFloat())
    }

    private fun verifyTextPlan(plan: MeasuredFrameTextPlan, scale: Float, canvasWidth: Float, canvasHeight: Float) {
        val boxes = plan.items.map { item ->
            android.graphics.RectF((item.x + item.run.left) * scale,
                (item.baseline + item.run.bounds.top) * scale,
                (item.x + item.run.left + item.run.width) * scale,
                (item.baseline + item.run.bounds.bottom) * scale)
        }
        boxes.forEach { box ->
            check(box.left >= -0.1f && box.top >= -0.1f &&
                box.right <= canvasWidth + 0.1f && box.bottom <= canvasHeight + 0.1f) {
                "Text outside canvas: $box in ${canvasWidth}x${canvasHeight}"
            }
        }
        for (a in boxes.indices) for (b in a + 1 until boxes.size) {
            val overlapX = minOf(boxes[a].right, boxes[b].right) - maxOf(boxes[a].left, boxes[b].left)
            val overlapY = minOf(boxes[a].bottom, boxes[b].bottom) - maxOf(boxes[a].top, boxes[b].top)
            check(overlapX <= 0.05f || overlapY <= 0.05f) { "Overlapping text: ${boxes[a]} / ${boxes[b]}" }
        }
    }

}
