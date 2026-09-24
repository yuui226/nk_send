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

/** Touch the production toolbar, including drag slop, live reflow and visibility callbacks. */
class RemoteToolEditorInstrumentation : Instrumentation() {
    private lateinit var labels: android.content.Context
    private fun label(id: Int) = labels.getString(id)
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    override fun onStart() {
        val result = Bundle()
        var activity: MainActivity? = null
        var outcome = Activity.RESULT_CANCELED
        val disk = targetContext.getSharedPreferences("ztransfer", 0)
        val savedRemotePrefs = disk.all.filterKeys { it.startsWith("remote_") }
        val savedTransferDir = disk.getString("transfer_dir", null)
        try {
            // Dedicated emulator run: restore toolbar defaults, preserving unrelated app preferences.
            val keys = listOf("remote_tool_order_photo", "remote_hidden_tools_photo", "remote_lock_starts_second_row_photo", "remote_hd", "remote_grid", "remote_layout_locked")
            check(disk.edit().apply { keys.forEach { remove(it) } }.commit())
            // This UI-only test never records or transfers files. Supply a well-formed tree URI
            // to satisfy the monitor entry prerequisite, then restore the user's setting.
            check(disk.edit().putString("transfer_dir",
                savedTransferDir ?: "content://com.android.externalstorage.documents/tree/primary%3ADownload").commit())
            fun tools() = RemoteToolPreferences(disk)
            fun layout() = tools().layout(false)
            uiAutomation // Activate accessibility before composing the real application.
            // Do not wait indefinitely for a previously open, animated settings page to idle.
            val monitor = addMonitor(MainActivity::class.java.name, null, false)
            try {
                runOnMainSync {
                    targetContext.startActivity(Intent(targetContext, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
                }
                activity = monitor.waitForActivityWithTimeout(10_000) as? MainActivity
                    ?: error("MainActivity did not resume within 10 seconds")
            } finally { removeMonitor(monitor) }
            labels = checkNotNull(activity)
            // Navigate through the actual app; there is no editor-only activity or blank preview.
            for (attempt in 0 until 40) {
                if (node(label(R.string.remote_tool_manage)) != null) break
                else {
                    node(label(R.string.cd_remote_entry))?.let { tap(Rect().also(it::getBoundsInScreen)) }
                        ?: node("打开模拟照片")?.let { tap(Rect().also(it::getBoundsInScreen)) }
                    SystemClock.sleep(200)
                }
            }
            tap(bounds(label(R.string.remote_tool_manage)))
            SystemClock.sleep(600)
            val fullscreen = bounds(RemoteTool.FULLSCREEN)
            val rotate = bounds(RemoteTool.ROTATE)
            check(kotlin.math.abs(fullscreen.centerY() - rotate.centerY()) <= 10)
            val lock = bounds(RemoteTool.LOCK)
            check(lock.centerY() > rotate.centerY() && kotlin.math.abs(lock.centerX() - bounds(RemoteTool.HD).centerX()) <= 8)
            screenshot("remote-editor-default.png")
            // Photo mode excludes the movie-only audio tool even while editing.
            check(node(label(RemoteTool.AUDIO.title)) == null)
            tap(bounds(RemoteTool.GRID))
            SystemClock.sleep(500)
            check(!layout().visible(RemoteTool.GRID) && layout().order.last() == RemoteTool.GRID)
            check(tools().grid.value == ViewfinderGrid.OFF)
            tap(bounds(RemoteTool.GRID))
            SystemClock.sleep(500)
            check(layout().visible(RemoteTool.GRID) && layout().shownTools.last() == RemoteTool.GRID) { "Restore failed: ${layout().hiddenTools}, ${layout().order}" }
            check(tools().grid.value == ViewfinderGrid.OFF)
            val from = bounds(RemoteTool.HD)
            val to = bounds(RemoteTool.WAVEFORM)
            check(to.centerY() > from.centerY())
            drag(from, to)
            SystemClock.sleep(700)
            check(layout().shownTools.indexOf(RemoteTool.HD) >= 8) { "Cross-row drag did not move HD: ${layout().order}" }
            check(layout().visible(RemoteTool.HD) && layout().hiddenTools.isEmpty()) { "Drop incorrectly triggered a click" }
            check(kotlin.math.abs(bounds(RemoteTool.FULLSCREEN).centerX() - fullscreen.centerX()) <= 8)
            check(kotlin.math.abs(bounds(RemoteTool.ROTATE).centerX() - rotate.centerX()) <= 8)
            // Fixed actions are inert while editing.
            tap(bounds(RemoteTool.ROTATE)); check(node(label(R.string.remote_tool_done)) != null)
            // The default second-row item remains movable and hideable, independently per mode.
            drag(bounds(RemoteTool.LOCK), bounds(RemoteTool.FPS)); SystemClock.sleep(600)
            check(!layout().lockStartsSecondRow && tools().layout(true).lockStartsSecondRow)
            check(layout().shownTools.first() == RemoteTool.LOCK)
            tap(bounds(RemoteTool.LOCK)); SystemClock.sleep(400)
            check(!layout().visible(RemoteTool.LOCK))
            tap(bounds(RemoteTool.LOCK)); SystemClock.sleep(400)
            check(layout().shownTools.last() == RemoteTool.LOCK && !layout().lockStartsSecondRow)
            // Hidden tools cannot be reordered by a drag, but remain tappable.
            tap(bounds(RemoteTool.HD)); SystemClock.sleep(500)
            val order = layout().order
            check(node(label(R.string.remote_tool_done)) != null) { "Editing ended while hiding HD" }
            screenshot("remote-editor-before-hidden-drag.png")
            drag(bounds(RemoteTool.HD), bounds(RemoteTool.FPS))
            SystemClock.sleep(400)
            check(layout().order == order && !layout().visible(RemoteTool.HD))
            val done = bounds(label(R.string.remote_tool_done))
            tap(done); SystemClock.sleep(500)
            check(node(label(RemoteTool.HD.title)) == null)
            check(node(label(RemoteTool.AUDIO.title)) == null)
            check(node(label(R.string.remote_tool_manage)) != null)
            tap(bounds(label(R.string.remote_tool_manage))); SystemClock.sleep(400)
            check(node(label(RemoteTool.HD.title)) != null)
            screenshot("remote-editor.png")
            // Hide through the real editor so the UI and stored preferences stay synchronized.
            RemoteTool.regular.forEach {
                if (layout().visible(it)) { tap(bounds(it)); SystemClock.sleep(300) }
            }
            SystemClock.sleep(500)
            tap(bounds(label(R.string.remote_tool_done))); SystemClock.sleep(500)
            check(node(label(R.string.remote_tool_manage)) != null)
            check(bounds(RemoteTool.ROTATE).centerX() > labels.resources.displayMetrics.widthPixels - 48)
            val sparseFullscreen = bounds(RemoteTool.FULLSCREEN)
            val sparseRotate = bounds(RemoteTool.ROTATE)
            check(kotlin.math.abs((sparseRotate.left - sparseFullscreen.right) -
                (rotate.left - fullscreen.right)) <= 2) {
                "Fixed-pair spacing changed between full and sparse rows"
            }
            check(sparseFullscreen.centerX() > labels.resources.displayMetrics.widthPixels * 0.65f)
            check(sparseRotate.left - sparseFullscreen.right <= sparseFullscreen.width()) {
                "Sparse toolbar separated the fixed pair: $sparseFullscreen / $sparseRotate"
            }
            screenshot("remote-editor-minimal.png")
            tap(bounds(RemoteTool.FULLSCREEN)); SystemClock.sleep(900)
            check(node(label(R.string.remote_tool_manage)) == null)
            check(node(label(R.string.cd_remote_fullscreen_exit)) != null)
            check(node("DISP") != null)
            screenshot("remote-immersive-layout.png")
            tap(bounds(label(R.string.cd_remote_fullscreen_exit))); SystemClock.sleep(600)
            check(node(label(R.string.remote_tool_manage)) == null) { "Landscape exposed its editor" }
            screenshot("remote-landscape-toolbar.png")
            tap(bounds(RemoteTool.ROTATE)); SystemClock.sleep(800)
            tap(bounds(RemoteTool.ROTATE)); SystemClock.sleep(800)
            check(node(label(R.string.remote_tool_manage)) != null)
            check(node(label(R.string.remote_tool_done)) == null) { "Returning to portrait resumed editing" }
            result.putString("result", "PASS: whole-button visibility, restore-to-tail, actual cross-row drag, no click after drag, hidden non-draggable, photo editor excludes audio, default lock at second-row start and drag/hide/restore, fixed controls, all-hidden manager access")
            outcome = Activity.RESULT_OK
        } catch (e: Throwable) {
            screenshot("remote-editor-failure.png")
            result.putString("failure", e.stackTraceToString())

        } finally {
            activity?.let { runOnMainSync { it.finish() } }
            disk.edit().apply {
                if (savedTransferDir == null) remove("transfer_dir") else putString("transfer_dir", savedTransferDir)
                disk.all.keys.filter { it.startsWith("remote_") }.forEach { remove(it) }
                savedRemotePrefs.forEach { (key, value) ->
                    when (value) {
                        is Boolean -> putBoolean(key, value)
                        is Int -> putInt(key, value)
                        is Long -> putLong(key, value)
                        is Float -> putFloat(key, value)
                        is String -> putString(key, value)
                        is Set<*> -> putStringSet(key, value.filterIsInstance<String>().toSet())
                    }
                }
            }.commit()
        }
        finish(outcome, result)
    }
    private fun node(label: String): AccessibilityNodeInfo? {
        if (android.os.Build.VERSION.SDK_INT >= 33) uiAutomation.clearCache()
        fun find(n: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if (n.contentDescription?.toString() == label || n.text?.toString() == label) return n
            for (i in 0 until n.childCount) n.getChild(i)?.let { find(it)?.let { found -> return found } }
            return null
        }
        return uiAutomation.rootInActiveWindow?.let(::find)
    }
    private fun bounds(tool: RemoteTool) = bounds(label(tool.title))
    private fun bounds(label: String): Rect {
        repeat(12) {
            node(label)?.let { return Rect().also(it::getBoundsInScreen) }
            SystemClock.sleep(100)
        }
        fun describe(n: AccessibilityNodeInfo): String = "${n.contentDescription}/${n.text} " +
            (0 until n.childCount).mapNotNull { n.getChild(it)?.let(::describe) }.joinToString()
        error("Missing tool: $label; tree=${uiAutomation.rootInActiveWindow?.let(::describe)}")
    }
    private fun event(down: Long, action: Int, x: Float, y: Float) {
        val e = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x, y, 0)
        try { check(uiAutomation.injectInputEvent(e, true)) } finally { e.recycle() }
    }
    private fun tap(r: Rect) {
        android.util.Log.i("RemoteEditorTest", "tap $r")
        val now = SystemClock.uptimeMillis()
        event(now, MotionEvent.ACTION_DOWN, r.exactCenterX(), r.exactCenterY())
        SystemClock.sleep(55)
        event(now, MotionEvent.ACTION_UP, r.exactCenterX(), r.exactCenterY())
        SystemClock.sleep(80) // Editing intentionally has a continuous wiggle animation.
    }
    private fun drag(from: Rect, to: Rect) {
        android.util.Log.i("RemoteEditorTest", "drag $from -> $to")
        // Hidden items intentionally do not consume drags. Start inside the icon but outside
        // Android's edge-back region, so this gesture tests the editor rather than system Back.
        val margin = 40f * labels.resources.displayMetrics.density
        val safeLeft = maxOf(from.left.toFloat() + 2, margin)
        val safeRight = minOf(from.right.toFloat() - 2, labels.resources.displayMetrics.widthPixels - margin)
        val startX = if (safeLeft <= safeRight) from.exactCenterX().coerceIn(safeLeft, safeRight) else from.exactCenterX()
        val now = SystemClock.uptimeMillis()
        event(now, MotionEvent.ACTION_DOWN, startX, from.exactCenterY())
        repeat(24) { i ->
            SystemClock.sleep(25)
            val t = (i + 1) / 24f
            event(now, MotionEvent.ACTION_MOVE, startX + (to.exactCenterX() - startX) * t,
                from.exactCenterY() + (to.exactCenterY() - from.exactCenterY()) * t)
        }
        event(now, MotionEvent.ACTION_UP, to.exactCenterX(), to.exactCenterY())
        SystemClock.sleep(80) // Editing intentionally has a continuous wiggle animation.
    }
    private fun screenshot(name: String) {
        runCatching { uiAutomation.takeScreenshot()?.let { bitmap ->
            File(targetContext.filesDir, name).outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        } }
    }
}
