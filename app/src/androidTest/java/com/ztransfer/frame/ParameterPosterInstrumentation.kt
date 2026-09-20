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
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
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
            val preset = PhotoFramePreset.PARAMETER_POSTER
            val defaults = defaultPhotoFrameMetadataSettings(preset)
            val all = defaults.copy(showLensModel = true, showCoordinates = true, showAltitude = true, showCity = true, showRegion = true, showDate = true, showTime = true)
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
            val longText = metadata.copy(make = "Hasselblad", model = "Hasselblad X2D 100C",
                lensModel = "Hasselblad XCD 35-75mm f/3.5-4.5 Zoom Lens", city = "Light & Shadow City", region = "Blue Hour District")
            val stress = PhotoFrameExporter.renderPreview(targetContext, portrait, longText, preset,
                PhotoFrameWatermark(enabled = true, text = "ZTransfer"), metadataSettings = all,
                longEdge = 1440, previewPlaceholders = false)
            File(dir, "portrait-long.png").outputStream().use { stress.compress(Bitmap.CompressFormat.PNG, 100, it) }
            stress.recycle()
            // Exercise the actual full-resolution region renderer and MediaStore export path.
            for ((name, source) in listOf("portrait" to portrait, "landscape" to landscape)) {
                val file = File(dir, "source-$name.jpg")
                file.outputStream().use { source.compress(Bitmap.CompressFormat.JPEG, 95, it) }
                val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                val resolver = targetContext.contentResolver
                val exported = runBlocking {
                    PhotoFrameExporter.exportBesideSource(targetContext, resolver,
                        PhotoFrameMediaStoreSource(Uri.fromFile(file), file.name, collection, collection, "Pictures/ZTransferTests/", null, mutableSetOf()),
                        preset, PhotoFrameWatermark(enabled = false), metadataSettings = all)
                }.getOrThrow()
                resolver.query(collection, arrayOf(MediaStore.Images.Media._ID), "${MediaStore.Images.Media.DISPLAY_NAME} = ?", arrayOf(exported.displayName), null)!!.use { cursor ->
                    check(cursor.moveToFirst())
                    val uri = ContentUris.withAppendedId(collection, cursor.getLong(0))
                    try {
                        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                        resolver.openInputStream(uri)!!.use { BitmapFactory.decodeStream(it, null, bounds) }
                        val layout = calculateOriginalParameterPosterLayout(source.width, source.height)
                        check(bounds.outWidth == layout.canvasWidth && bounds.outHeight == layout.canvasHeight)
                    } finally { resolver.delete(uri, null, null) }
                }
            }
            landscape.recycle(); portrait.recycle()
            result.putString("result", "PASS: six visual cases including long text and watermark; original-quality portrait and landscape exports")
            result.putString("images", dir.absolutePath)
            finish(Activity.RESULT_OK, result)
        } catch (error: Throwable) {
            result.putString("failure", error.stackTraceToString())
            finish(Activity.RESULT_CANCELED, result)
        }
    }
}
