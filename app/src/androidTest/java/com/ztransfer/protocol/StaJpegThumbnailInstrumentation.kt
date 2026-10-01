package com.ztransfer.protocol

import android.app.Activity
import android.app.Instrumentation
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Bundle
import java.io.ByteArrayOutputStream

/** Exercise the real Android JPEG decoder, resizing, encoding, and fallback decisions. */
class StaJpegThumbnailInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val result = Bundle()
        try {
            for ((width, height) in listOf(1920 to 1280, 1280 to 1920, 320 to 240, 3840 to 2560)) {
                val source = jpeg(width, height)
                check(source.size <= STA_JPEG_THUMBNAIL_MAX_BYTES)
                val thumbnail = checkNotNull(createStaJpegThumbnail(source, 160))
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(thumbnail, 0, thumbnail.size, bounds)
                check(maxOf(bounds.outWidth, bounds.outHeight) == minOf(maxOf(width, height), 640))
                check(kotlin.math.abs(bounds.outWidth.toDouble() / bounds.outHeight - width.toDouble() / height) < 0.01)
                check((width > height) == (bounds.outWidth > bounds.outHeight))
            }
            check(createStaJpegThumbnail(jpeg(160, 120), 160) == null)
            check(createStaJpegThumbnail(jpeg(640, 480), 640) == null)
            val valid = jpeg(640, 480)
            check(createStaJpegThumbnail(valid.copyOf(valid.size - 1), 160) == null)
            check(createStaJpegThumbnail(ByteArray(STA_JPEG_THUMBNAIL_MAX_BYTES + 1), 160) == null)
            check(createStaJpegThumbnail(byteArrayOf(-1, -40, -1, -39), 160) == null)
            result.putString("result", "PASS: landscape, portrait, no upscale, sampled large image, non-improvement, truncated, oversized, invalid JPEG")
            finish(Activity.RESULT_OK, result)
        } catch (error: Throwable) {
            result.putString("failure", error.stackTraceToString())
            finish(Activity.RESULT_CANCELED, result)
        }
    }

    private fun jpeg(width: Int, height: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.RGB_565)
        return try {
            bitmap.eraseColor(Color.rgb(66, 128, 192))
            ByteArrayOutputStream().use {
                check(bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it))
                it.toByteArray()
            }
        } finally { bitmap.recycle() }
    }
}
