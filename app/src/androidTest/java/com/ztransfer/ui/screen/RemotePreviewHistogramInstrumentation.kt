package com.ztransfer.ui.screen

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.graphics.Rect
import android.os.Bundle
import android.os.SystemClock
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.ztransfer.MainActivity
import com.ztransfer.R
import java.io.File

/** Navigate the real simulated-photo list and preview, including reopening with the saved mode. */
class RemotePreviewHistogramInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    override fun onStart() {
        val result = Bundle()
        val prefs = targetContext.getSharedPreferences("ztransfer", 0)
        val keys = listOf("preview_histogram_mode", "preview_histogram_enabled", "tap_to_preview")
        val saved = prefs.all.filterKeys { it in keys }
        var activity: MainActivity? = null
        var outcome = Activity.RESULT_CANCELED
        try {
            prefs.edit().putString("preview_histogram_mode", "OFF").putBoolean("tap_to_preview", true).commit()
            uiAutomation
            activity = startActivitySync(Intent(targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
            val label = activity.getString(R.string.cd_preview_histogram)
            for (i in 0 until 40) {
                if (node("ZSIM_0001.JPG") != null) break
                node("打开模拟照片")?.let { tap(Rect().also(it::getBoundsInScreen)) }
                SystemClock.sleep(200)
            }
            val sourceTile = bounds("ZSIM_0001.JPG")
            tap(sourceTile); SystemClock.sleep(700)
            for (mode in listOf("RGB", "LUMA", "OFF", "RGB")) {
                tap(bounds(label)); SystemClock.sleep(450)
                check(prefs.getString("preview_histogram_mode", null) == mode) { "Expected $mode" }
                screenshot("preview-histogram-${mode.lowercase()}.png")
            }
            // Use the real preview's tap-to-close gesture; injected Back with zero event times
            // can be deferred by Android's predictive-back dispatch until the following touch.
            tap(bounds("ZSIM_0001.JPG"))
            // Preview closes through its return-to-thumbnail animation before accepting a new open.
            SystemClock.sleep(1500)
            // No paging/scrolling occurred. Reuse the observed source tile: accessibility can
            // still return the removed full-screen image for this same content description.
            tap(sourceTile); SystemClock.sleep(600)
            tap(bounds(label)); SystemClock.sleep(400)
            check(prefs.getString("preview_histogram_mode", null) == "LUMA") { "Reopened preview lost its RGB selection" }
            result.putString("result", "PASS: real preview cycles RGB / original luma / off, saves each mode and restores it on reopening; screenshots captured")
            outcome = Activity.RESULT_OK
        } catch (e: Throwable) {
            screenshot("preview-histogram-failure.png")
            result.putString("failure", e.stackTraceToString())
        } finally {
            activity?.let { runOnMainSync { it.finish() } }
            prefs.edit().apply {
                keys.forEach { remove(it) }
                saved.forEach { (key, value) -> when (value) {
                    is String -> putString(key, value)
                    is Boolean -> putBoolean(key, value)
                } }
            }.commit()
        }
        finish(outcome, result)
    }
    private fun node(label: String): AccessibilityNodeInfo? {
        if (android.os.Build.VERSION.SDK_INT >= 33) uiAutomation.clearCache()
        fun find(n: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if (n.contentDescription?.toString() == label) return n
            for (i in 0 until n.childCount) n.getChild(i)?.let { find(it)?.let { found -> return found } }
            return null
        }
        return uiAutomation.rootInActiveWindow?.let(::find)
    }
    private fun bounds(label: String): Rect {
        repeat(20) { node(label)?.let { return Rect().also(it::getBoundsInScreen) }; SystemClock.sleep(100) }
        error("Missing control: $label")
    }
    private fun tap(r: Rect) {
        android.util.Log.i("PreviewHistogramTest", "tap $r")
        val now = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(now, SystemClock.uptimeMillis(), action, r.exactCenterX(), r.exactCenterY(), 0)
            try { check(uiAutomation.injectInputEvent(event, true)) } finally { event.recycle() }
            SystemClock.sleep(55)
        }
    }
    private fun screenshot(name: String) {
        uiAutomation.takeScreenshot()?.let { image ->
            File(targetContext.filesDir, name).outputStream().use { image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
            image.recycle()
        }
    }
}
