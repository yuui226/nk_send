package com.ztransfer.ui.screen

import com.ztransfer.util.HistogramMode

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Rect
import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp
import com.ztransfer.MainActivity
import com.ztransfer.ui.theme.ZTransferTheme
import java.io.File
import kotlin.math.abs

/** Exercise the production scope composable with known image data, independent of a camera. */
class RemoteScopeInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    @OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
    override fun onStart() {
        val result = Bundle()
        var activity: MainActivity? = null
        var outcome = Activity.RESULT_CANCELED
        try {
            uiAutomation.serviceInfo = uiAutomation.serviceInfo.apply {
                flags = flags or AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
            }
            val source = Bitmap.createBitmap(640, 420, Bitmap.Config.ARGB_8888)
            val pixels = IntArray(640 * 420) { index ->
                val x = index % 640; val y = index / 640
                // A known scene with a blue sky, warm hillside, shadow and bright subject.
                val hill = 185 + (35 * kotlin.math.sin(x / 80.0)).toInt()
                when {
                    (x - 490) * (x - 490) + (y - 85) * (y - 85) < 27 * 27 -> Color.rgb(255, 236, 162)
                    y < hill -> Color.rgb(60 + y / 4, 125 + y / 5, 206 + y / 6)
                    else -> Color.rgb((130 + (y - hill) / 3).coerceAtMost(245), 80 + x / 10, 28 + y / 7)
                }
            }
            source.setPixels(pixels, 0, 640, 0, 0, 640, 420)
            val image = source.asImageBitmap()
            val histogram = calculateLuminanceHistogram(source, true)
            val wave = analyzeMonitorFrame(source, false, true).waveform!!
            val rgbWave = analyzeMonitorFrame(source, false, true, true).waveform!!
            val showHistogram = mutableStateOf(true)
            val showWaveform = mutableStateOf(true)
            val rgb = mutableStateOf(false)
            val height = mutableStateOf(230.dp)
            activity = startActivitySync(Intent(targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
            runOnMainSync {
                activity.setContent {
                    ZTransferTheme {
                        Column(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color(0xFF202126))
                            .padding(top = 40.dp).semantics { testTagsAsResourceId = true }) {
                            Text("Scope rendering / synthetic input", color = androidx.compose.ui.graphics.Color.White)
                            Box(Modifier.fillMaxWidth().height(height.value)) {
                                Image(image, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                                MonitorAnalysisOverlays(if (showHistogram.value) histogram else null,
                                    if (showWaveform.value) { if (rgb.value) rgbWave else wave } else null,
                                    false, Modifier.fillMaxSize(), HistogramMode.RGB,
                                    if (rgb.value) WaveformMode.RGB else WaveformMode.LUMA)
                            }
                        }
                    }
                }
            }
            SystemClock.sleep(800)
            val left = bounds("monitor-histogram")
            val right = bounds("monitor-waveform")
            check(right.left > left.right && abs(right.top - left.top) <= 1)
            screenshot("scopes-both.png")
            runOnMainSync { showHistogram.value = false }
            SystemClock.sleep(200)
            screenshot("scopes-moving.png")
            SystemClock.sleep(80)
            screenshot("scopes-moving-late.png")
            SystemClock.sleep(500)
            val loneWave = bounds("monitor-waveform")
            check(loneWave == left) { "Waveform did not occupy the histogram anchor: $loneWave / $left" }
            check(node("monitor-histogram") == null)
            screenshot("scopes-waveform.png")
            runOnMainSync { rgb.value = true }
            SystemClock.sleep(250)
            screenshot("scopes-waveform-rgb.png")
            runOnMainSync { showHistogram.value = true; showWaveform.value = false }
            SystemClock.sleep(600)
            check(bounds("monitor-histogram") == left && node("monitor-waveform") == null)
            screenshot("scopes-histogram.png")
            // Rapid reversal must settle to the latest switch state, without duplicate slots.
            repeat(6) { i ->
                runOnMainSync { showHistogram.value = i % 2 == 0; showWaveform.value = true }
                SystemClock.sleep(40)
            }
            SystemClock.sleep(600)
            check(bounds("monitor-waveform") == left && node("monitor-histogram") == null)
            runOnMainSync { height.value = 98.dp; showHistogram.value = true }
            SystemClock.sleep(600)
            val shortLeft = bounds("monitor-histogram")
            val shortRight = bounds("monitor-waveform")
            check(shortLeft.height() >= 24 && shortLeft.right < shortRight.left && shortRight.right <= targetContext.resources.displayMetrics.widthPixels)
            screenshot("scopes-compact.png")
            runOnMainSync { showHistogram.value = false; showWaveform.value = false }
            SystemClock.sleep(500)
            check(node("monitor-histogram") == null && node("monitor-waveform") == null)
            result.putString("result", "PASS: side-by-side scopes, identical left anchor and size for either alone, exit removal, rapid reversal, compact bounds; screenshots captured including motion")
            outcome = Activity.RESULT_OK
        } catch (e: Throwable) {
            screenshot("scopes-failure.png")
            result.putString("failure", e.stackTraceToString())
        } finally {
            activity?.let { runOnMainSync { it.finish() } }
        }
        finish(outcome, result)
    }
    private fun node(id: String): AccessibilityNodeInfo? {
        if (android.os.Build.VERSION.SDK_INT >= 33) uiAutomation.clearCache()
        fun find(n: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if (n.viewIdResourceName == id) return n
            for (i in 0 until n.childCount) n.getChild(i)?.let { find(it)?.let { found -> return found } }
            return null
        }
        return uiAutomation.rootInActiveWindow?.let(::find)
    }
    private fun bounds(id: String): Rect = node(id)?.let { Rect().also(it::getBoundsInScreen) } ?: error("Missing scope: $id")
    private fun screenshot(name: String) {
        uiAutomation.takeScreenshot()?.let { bitmap ->
            File(targetContext.filesDir, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
    }
}
