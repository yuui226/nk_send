package com.ztransfer.protocol

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.exifinterface.media.ExifInterface
import com.ztransfer.R
import com.ztransfer.util.applyExifOrientation
import java.io.ByteArrayOutputStream
import java.io.ByteArrayInputStream

/** Debug-only endpoint backed by the embedded camera simulator in the app process. */
object CameraEndpointOverride {
    private const val SIMULATOR_HOST = "127.0.0.1"
    @Volatile private var simulatorEnabled = false

    fun applyLaunchIntent(@Suppress("UNUSED_PARAMETER") intent: android.content.Intent?) = Unit

    fun enableSimulator(context: Context): Boolean {
        simulatorEnabled = true
        DebugCameraSimulator.start(loadFeaturedImage(context.applicationContext))
        return true
    }

    fun hostOrNull(): String? = SIMULATOR_HOST.takeIf { simulatorEnabled }

    /** Keeps the original for downloads and derives camera-like FHD + thumbnail responses. */
    private fun loadFeaturedImage(context: Context): DebugCameraSimulator.FeaturedImage {
        val image = context.resources.openRawResource(R.raw.debug_sample_01).use { it.readBytes() }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(image, 0, image.size, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "invalid debug_sample_01" }
        val orientation = runCatching {
            ExifInterface(ByteArrayInputStream(image)).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)

        var sampleSize = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sampleSize * 2) >= 1_920) {
            sampleSize *= 2
        }
        val decoded = checkNotNull(
            BitmapFactory.decodeByteArray(
                image,
                0,
                image.size,
                BitmapFactory.Options().apply { inSampleSize = sampleSize },
            )
        )
        val oriented = applyExifOrientation(decoded, orientation)
        val fhdBitmap = scaleToLongEdge(oriented, 1_920)
        val fhdPreview = ByteArrayOutputStream().use { output ->
            check(fhdBitmap.compress(Bitmap.CompressFormat.JPEG, 92, output))
            output.toByteArray()
        }
        val thumbnailBitmap = scaleToLongEdge(fhdBitmap, 480)
        val thumbnailWidth = thumbnailBitmap.width
        val thumbnailHeight = thumbnailBitmap.height
        val thumbnail = ByteArrayOutputStream().use { output ->
            check(thumbnailBitmap.compress(Bitmap.CompressFormat.JPEG, 86, output))
            output.toByteArray()
        }
        if (thumbnailBitmap !== fhdBitmap) thumbnailBitmap.recycle()
        if (fhdBitmap !== oriented) fhdBitmap.recycle()
        oriented.recycle()

        val swapsAxes = orientation in setOf(
            ExifInterface.ORIENTATION_TRANSPOSE,
            ExifInterface.ORIENTATION_ROTATE_90,
            ExifInterface.ORIENTATION_TRANSVERSE,
            ExifInterface.ORIENTATION_ROTATE_270,
        )

        return DebugCameraSimulator.FeaturedImage(
            image = image,
            fhdPreview = fhdPreview,
            thumbnail = thumbnail,
            width = if (swapsAxes) bounds.outHeight else bounds.outWidth,
            height = if (swapsAxes) bounds.outWidth else bounds.outHeight,
            thumbnailWidth = thumbnailWidth,
            thumbnailHeight = thumbnailHeight,
        )
    }

    private fun scaleToLongEdge(source: Bitmap, maxLongEdge: Int): Bitmap {
        val longEdge = maxOf(source.width, source.height)
        if (longEdge <= maxLongEdge) return source
        val scale = maxLongEdge.toFloat() / longEdge
        return Bitmap.createScaledBitmap(
            source,
            (source.width * scale).toInt().coerceAtLeast(1),
            (source.height * scale).toInt().coerceAtLeast(1),
            true,
        )
    }
}
