package com.ztransfer.ui.screen

import android.app.Activity
import android.app.Instrumentation
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Bundle
import java.io.ByteArrayOutputStream

/** Real Android JPEG decoding: detects regression to the display bitmap's 5-bit channels. */
class PreviewHistogramPrecisionInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    override fun onStart() {
        val result = Bundle()
        var outcome = Activity.RESULT_CANCELED
        try {
            fun jpeg(bitmap: Bitmap): ByteArray = ByteArrayOutputStream().use {
                check(bitmap.compress(Bitmap.CompressFormat.JPEG, 100, it))
                it.toByteArray()
            }
            val gradient = Bitmap.createBitmap(256, 64, Bitmap.Config.ARGB_8888)
            try {
                gradient.setPixels(IntArray(256 * 64) { Color.rgb(it % 256, it % 256, it % 256) }, 0, 256, 0, 0, 256, 64)
                val histogram = checkNotNull(previewHistogramFromJpeg(jpeg(gradient)))
                val rgb = checkNotNull(histogram.rgb)
                check(rgb.all { it.size == 256 && it.count { count -> count > 0f } > 200 })
                check(rgb[0].contentEquals(rgb[1]) && rgb[1].contentEquals(rgb[2]))
            } finally { gradient.recycle() }
            val mixed = Bitmap.createBitmap(100, 1, Bitmap.Config.ARGB_8888)
            try {
                // R splits evenly; G remains entirely black. Shared scale must retain 1:2 peaks.
                mixed.setPixels(IntArray(100) { if (it < 50) Color.RED else Color.BLACK }, 0, 100, 0, 0, 100, 1)
                val rgb = checkNotNull(calculateLuminanceHistogram(mixed, true, Int.MAX_VALUE).rgb)
                check(rgb[0][0] == 0.5f && rgb[0][255] == 0.5f && rgb[1][0] == 1f)
            } finally { mixed.recycle() }
            for (color in listOf(Color.BLACK, Color.WHITE)) {
                val source = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888)
                try {
                    source.eraseColor(color)
                    val rgb = checkNotNull(previewHistogramFromJpeg(jpeg(source))?.rgb)
                    val endpoint = if (color == Color.BLACK) 0 else 255
                    check(rgb.all { it[endpoint] == 1f && it.count { count -> count > 0f } == 1 })
                } finally { source.recycle() }
            }
            check(previewHistogramFromJpeg(byteArrayOf(1, 2, 3)) == null)
            result.putString("result", "PASS: JPEG grayscale retains >200 levels; RGB channels agree; shared peak preserves ratios; black/white endpoints; invalid input fallback")
            outcome = Activity.RESULT_OK
        } catch (error: Throwable) { result.putString("failure", error.stackTraceToString()) }
        finish(outcome, result)
    }
}
