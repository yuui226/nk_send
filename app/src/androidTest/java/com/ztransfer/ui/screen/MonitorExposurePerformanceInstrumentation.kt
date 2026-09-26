package com.ztransfer.ui.screen

import android.app.Activity
import android.app.Instrumentation
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Bundle
import android.os.SystemClock
import androidx.compose.ui.graphics.asAndroidBitmap

/** Pixel freshness and bounded processing; does not open or exercise the tool editor. */
class MonitorExposurePerformanceInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    override fun onStart() {
        val result = Bundle()
        val source = Bitmap.createBitmap(1920, 1080, Bitmap.Config.ARGB_8888)
        try {
            val throttle = MonitorAnalysisThrottle()
            source.eraseColor(Color.BLACK)
            val first = checkNotNull(throttle.analyze(source, true, true, 1000))
            source.eraseColor(Color.WHITE)
            val next = checkNotNull(throttle.analyze(source, true, true, 1016))
            check(next.falseColor !== first.falseColor)
            check(next.waveform === first.waveform) // Scope cadence is independent.
            check(first.falseColor!!.asAndroidBitmap().getPixel(0, 0) == falseColorForLuma(0))
            check(next.falseColor!!.asAndroidBitmap().getPixel(0, 0) == falseColorForLuma(255))
            check(checkNotNull(throttle.analyze(source, true, true, 1125)).waveform !== first.waveform)
            check(checkNotNull(throttle.analyze(source, false, true, 1140)).falseColor == null)
            val scopeOnly = checkNotNull(throttle.analyze(source, false, true, 1141))
            check(throttle.analyze(source, false, true, 1142) === scopeOnly)
            val rgbScope = checkNotNull(throttle.analyze(source, false, true, 1143, rgb = true))
            check(rgbScope.waveform !== scopeOnly.waveform)
            check(throttle.analyze(source, false, true, 1144, rgb = true) === rgbScope)
            check(throttle.analyze(source, false, false, 1150) == null)
            check(checkNotNull(throttle.analyze(source, false, true, 1151)).waveform !== rgbScope.waveform)
            check(calculateLuminanceHistogram(source).rgb == null)
            check(calculateLuminanceHistogram(source, includeRgb = true).rgb?.size == 3)
            check(!source.isRecycled)
            val times = LongArray(120) {
                val start = SystemClock.elapsedRealtimeNanos()
                val analysis = analyzeMonitorFrame(source, true, false)
                analysis.falseColor!!.asAndroidBitmap().recycle() // No UI owns these test frames.
                SystemClock.elapsedRealtimeNanos() - start
            }.sorted()
            result.putString("falseColor1080p", "medianMs=${times[60] / 1e6} p95Ms=${times[114] / 1e6}")
            check(calculateZebraMask(source).let { mask -> mask.cells.all { it } })
            source.eraseColor(Color.BLACK)
            check(calculateZebraMask(source).cells.none { it })
            result.putString("result", "PASS: latest-frame colors, independent waveform, source ownership, zebra thresholds")
            finish(Activity.RESULT_OK, result)
        } catch (error: Throwable) {
            result.putString("failure", error.stackTraceToString())
            finish(Activity.RESULT_CANCELED, result)
        } finally { source.recycle() }
    }
}
