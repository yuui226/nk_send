package com.ztransfer.ui.screen

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import android.os.SystemClock
import android.view.MotionEvent
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.isSpecified
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.dp
import com.ztransfer.MainActivity
import com.ztransfer.ui.theme.ZTransferTheme
import java.io.File
import kotlin.math.abs

/** Touch-test the shared production viewport's nested hit testing, independently of camera hardware. */
class MonitorInteractionInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    override fun onStart() {
        val result = Bundle()
        var activity: MainActivity? = null
        var outcome = Activity.RESULT_CANCELED
        try {
            val viewport = ViewfinderViewport()
            var origin = Offset.Zero
            var tap = Offset.Unspecified
            val roll = mutableFloatStateOf(4f)
            val disp = mutableStateOf(MonitorDispMode.EXPOSURE)
            activity = startActivitySync(Intent(targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
            runOnMainSync {
                activity.setContent {
                    ZTransferTheme {
                        Column(Modifier.fillMaxSize().background(Color(0xFF19252B)).padding(top = 50.dp)) {
                            ZoomableViewfinder(viewport, 1.5f,
                                Modifier.fillMaxWidth().aspectRatio(1.5f).onGloballyPositioned {
                                    origin = it.boundsInWindow().topLeft
                                }) {
                                Box(Modifier.fillMaxSize().background(Color(0xFF73939C)).pointerInput(Unit) {
                                    detectTapGestures(onDoubleTap = { viewport.reset() }, onTap = { tap = it })
                                })
                            }
                            Box(Modifier.fillMaxWidth().height(180.dp)) {
                                ViewfinderLevelOverlay(roll.floatValue, Modifier.fillMaxSize())
                            }
                            ImmersiveMonitorFooter(disp.value,
                                listOf("M", "1/250", "F2.8", "ISO 100"), true, Modifier.fillMaxWidth())
                        }
                    }
                }
            }
            waitForIdleSync(); SystemClock.sleep(400)
            val center = origin + Offset(viewport.size.width / 2f, viewport.size.height / 2f)
            pinch(center, viewport.size.width * 0.10f, viewport.size.width * 0.24f)
            SystemClock.sleep(400)
            check(viewport.scale > 1.7f) { "Pinch did not reach production viewport: ${viewport.scale}" }
            val at = center + Offset(viewport.size.width * 0.15f, 0f)
            tap(at); SystemClock.sleep(400)
            val expected = viewport.size.width / 2f + (at.x - center.x - viewport.offset.x) / viewport.scale
            check(tap.isSpecified && abs(tap.x - expected) < 3f) {
                "Nested focus hit-test lost inverse zoom: $tap, expected x=$expected"
            }
            screenshot("monitor-zoom-horizon-tilted.png")
            runOnMainSync { roll.floatValue = 0f }
            SystemClock.sleep(300)
            screenshot("monitor-zoom-horizon-level.png")
            tap(center); SystemClock.sleep(70); tap(center); SystemClock.sleep(400)
            check(viewport.scale == 1f && viewport.offset == Offset.Zero) { "Double tap did not reset" }
            check(MonitorDispMode.EXPOSURE.next().next().next() == MonitorDispMode.EXPOSURE)
            result.putString("result", "PASS: two-finger zoom, inverse-transformed focus tap, double-tap reset; level/tilted screenshots")
            outcome = Activity.RESULT_OK
        } catch (e: Throwable) { result.putString("failure", e.stackTraceToString()) }
        finally { activity?.let { runOnMainSync { it.finish() } } }
        finish(outcome, result)
    }
    private fun tap(point: Offset) {
        val now = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(now, SystemClock.uptimeMillis(), action, point.x, point.y, 0)
            sendPointerSync(event); event.recycle()
        }
    }
    private fun pinch(center: Offset, startRadius: Float, endRadius: Float) {
        val down = SystemClock.uptimeMillis()
        val props = Array(2) { i -> MotionEvent.PointerProperties().apply { id = i; toolType = MotionEvent.TOOL_TYPE_FINGER } }
        fun send(action: Int, count: Int, radius: Float) {
            val coords = Array(count) { i -> MotionEvent.PointerCoords().apply {
                x = center.x + if (i == 0) -radius else radius
                y = center.y; pressure = 1f; size = 1f
            } }
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, count,
                props, coords, 0, 0, 1f, 1f, 0, 0, android.view.InputDevice.SOURCE_TOUCHSCREEN, 0)
            sendPointerSync(event); event.recycle()
        }
        send(MotionEvent.ACTION_DOWN, 1, startRadius)
        send(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 2, startRadius)
        for (step in 1..12) {
            SystemClock.sleep(20)
            send(MotionEvent.ACTION_MOVE, 2, startRadius + (endRadius - startRadius) * step / 12)
        }
        send(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 2, endRadius)
        send(MotionEvent.ACTION_UP, 1, endRadius)
    }
    private fun screenshot(name: String) {
        val image = uiAutomation.takeScreenshot()
        File(targetContext.filesDir, name).outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        image.recycle()
    }
}
