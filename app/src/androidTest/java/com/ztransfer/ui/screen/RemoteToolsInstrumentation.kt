package com.ztransfer.ui.screen

import com.ztransfer.util.HistogramMode

import android.app.Activity
import android.app.Instrumentation
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Bundle
import android.os.SystemClock
import android.content.Intent
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.ztransfer.MainActivity
import com.ztransfer.ui.theme.ZTransferTheme
import androidx.compose.ui.graphics.asAndroidBitmap
import java.io.File

/** Real Android preferences and image sampling verification. */
class RemoteToolsInstrumentation : Instrumentation() {
    private var visual = false
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        visual = arguments?.getString("visual") == "true"
        start()
    }
    override fun onStart() {
        val result = Bundle()
        try {
            preferences()
            analysis()
            if (visual) renderOverlays()
            result.putString("result", "PASS: photo/movie layout isolation and restoration, audio availability, hidden effects, stable order, fixed tools, shared throttled analysis, luminance/waveform geometry")
            finish(Activity.RESULT_OK, result)
        } catch (error: Throwable) {
            result.putString("failure", error.stackTraceToString())
            finish(Activity.RESULT_CANCELED, result)
        }
    }
    private fun renderOverlays() {
        val source = Bitmap.createBitmap(640, 480, Bitmap.Config.ARGB_8888)
        source.eraseColor(Color.GRAY)
        val analysis = analyzeMonitorFrame(source, true, true)
        val histogram = calculateLuminanceHistogram(source)
        val activity = startActivitySync(Intent(targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        runOnMainSync {
            activity.setContent {
                ZTransferTheme {
                    Column(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.DarkGray).padding(top = 28.dp)) {
                        for (height in listOf(98, 197, 250)) {
                            Box(Modifier.fillMaxWidth().height(height.dp).padding(4.dp).background(androidx.compose.ui.graphics.Color.Black)) {
                                FalseColorOverlay(analysis.falseColor!!, 3f, Modifier.fillMaxSize())
                                MonitorAnalysisOverlays(histogram, analysis.waveform, true, Modifier.fillMaxSize())
                                Text("M  AF-C", color = androidx.compose.ui.graphics.Color.White)
                            }
                        }
                    }
                }
            }
        }
        waitForIdleSync()
        SystemClock.sleep(500)
        val screenshot = uiAutomation.takeScreenshot()
        File(targetContext.filesDir, "remote-analysis-layout.png").outputStream().use { screenshot.compress(Bitmap.CompressFormat.PNG, 100, it) }
        screenshot.recycle()
        runOnMainSync { activity.finish() }
        source.recycle()
    }
    private fun preferences() {
        val disk = targetContext.getSharedPreferences("remote-tools-test", 0)
        check(disk.edit().clear().putBoolean("remote_audio_levels_visible", false)
            .putFloat("remote_desqueeze_multiplier", 1.5f).commit())
        var p = RemoteToolPreferences(disk)
        check(!p.audio.value && p.desqueeze.value == 1.5f && p.fps.value)
        p.hd.value = true; p.histogram.value = HistogramMode.RGB; p.waveform.value = WaveformMode.RGB
        p.exposure.value = ExposureAssist.FALSE_COLOR; p.grid.value = ViewfinderGrid.entries.last()
        p.level.value = true; p.lockedRotation.value = 2; p.locked.value = true
        p.layout(false).move(RemoteTool.WAVEFORM, 0)
        check(disk.edit().commit())
        p = RemoteToolPreferences(disk)
        check(p.hd.value && p.histogram.value == HistogramMode.RGB && p.waveform.value == WaveformMode.RGB && p.level.value)
        check(p.exposure.value == ExposureAssist.FALSE_COLOR && p.grid.value == ViewfinderGrid.entries.last())
        check(p.locked.value && p.lockedRotation.value == 2 && p.layout(false).order.first() == RemoteTool.WAVEFORM)
        val photo = p.layout(false)
        val movie = p.layout(true)
        check(RemoteTool.AUDIO !in photo.order && !photo.visible(RemoteTool.AUDIO))
        check(movie.visible(RemoteTool.AUDIO) && movie.shownTools[5] == RemoteTool.PICTURE_CONTROL)
        check(movie.order.filterNot { it == RemoteTool.PICTURE_CONTROL } ==
            RemoteTool.regular.filterNot { it == RemoteTool.PICTURE_CONTROL })
        val originalPhotoOrder = photo.order
        RemoteTool.pinned.forEach { fixed ->
            photo.move(fixed, 0)
            photo.setVisible(fixed, false)
            check(photo.visible(fixed) && movie.visible(fixed))
        }
        check(photo.order == originalPhotoOrder && p.locked.value)
        // Neither hiding nor reordering photo tools changes the movie layout.
        photo.setVisible(RemoteTool.HD, false)
        check(movie.visible(RemoteTool.HD))
        movie.setVisible(RemoteTool.AUDIO, false)
        movie.move(RemoteTool.GRID, 0)
        val photoOrder = photo.order
        photo.setVisible(RemoteTool.AUDIO, true)
        check(photo.order == photoOrder && !photo.visible(RemoteTool.AUDIO))
        check(photo.order.first() == RemoteTool.WAVEFORM && movie.order.first() == RemoteTool.GRID)
        val restored = RemoteToolPreferences(disk)
        check(restored.layout(false).order == photo.order && restored.layout(true).order == movie.order)
        check(!restored.layout(false).visible(RemoteTool.HD) && restored.layout(true).visible(RemoteTool.HD))
        check(!restored.layout(true).visible(RemoteTool.AUDIO))
        check(RemoteTool.pinned.all { restored.layout(false).visible(it) && restored.layout(true).visible(it) })
        // Entering a mode applies its hidden state without changing the other layout.
        p.hd.value = true
        photo.hiddenTools.forEach { photo.setVisible(it, false) }
        check(!p.hd.value && movie.visible(RemoteTool.HD))
        for (layout in listOf(photo, movie)) {
            val order = layout.order
            RemoteTool.pinned.forEach { layout.move(it, 0) }; check(layout.order == order)
            RemoteTool.entries.forEach { layout.setVisible(it, false) }
            check(layout.available.none(layout::visible))
            check(RemoteTool.pinned.all(layout::visible))
            RemoteTool.entries.forEach { layout.setVisible(it, true) }
            check(layout.order == layout.available)
            layout.setVisible(RemoteTool.GRID, false)
            check(layout.hiddenTools == listOf(RemoteTool.GRID) && layout.order.last() == RemoteTool.GRID)
            val hiddenOrder = layout.order
            layout.move(RemoteTool.GRID, 0); check(layout.order == hiddenOrder)
            layout.setVisible(RemoteTool.HD, false)
            check(layout.hiddenTools == listOf(RemoteTool.GRID, RemoteTool.HD))
            layout.setVisible(RemoteTool.GRID, true)
            check(layout.shownTools.last() == RemoteTool.GRID && layout.hiddenTools == listOf(RemoteTool.HD))
            layout.move(RemoteTool.GRID, 0)
            check(layout.shownTools.first() == RemoteTool.GRID && layout.order.last() == RemoteTool.HD)
        }
        check(!p.hd.value && !p.fps.value && !p.audio.value && p.histogram.value == HistogramMode.OFF && p.waveform.value == WaveformMode.OFF && !p.level.value && p.locked.value)
        check(p.grid.value == ViewfinderGrid.OFF && p.exposure.value == ExposureAssist.OFF && p.desqueeze.value == 1f)
        check(disk.edit().putString("remote_tool_order_photo", "waveform,lock,removed,waveform,rotate,audio,hd")
            .putStringSet("remote_hidden_tools_photo", setOf("lock", "rotate"))
            .putString("remote_grid", "removed").putFloat("remote_desqueeze_multiplier", Float.NaN).commit())
        p = RemoteToolPreferences(disk)
        check(RemoteTool.pinned.all(p.layout(false)::visible))
        check(p.layout(false).hiddenTools.isEmpty())
        check(p.layout(false).order.take(2) == listOf(RemoteTool.WAVEFORM, RemoteTool.HD))
        check(p.layout(false).order.size == RemoteTool.regular.size - 1)
        check(p.layout(false).order.distinct().size == p.layout(false).order.size)
        check(p.grid.value == ViewfinderGrid.OFF && p.desqueeze.value == 1f)
        check(ExposureAssist.OFF.next().next().next() == ExposureAssist.OFF)
        disk.edit().clear().commit()
    }
    private fun analysis() {
        val source = Bitmap.createBitmap(640, 480, Bitmap.Config.ARGB_8888)
        val row = IntArray(640) { val l = it * 255 / 639; Color.rgb(l, l, l) }
        repeat(480) { source.setPixels(row, 0, 640, 0, it, 640, 1) }
        check(monitorLuma(Color.BLACK) == 0 && monitorLuma(Color.WHITE) == 255)
        check(monitorLuma(Color.RED) == 76 && monitorLuma(Color.GREEN) == 149)
        val throttle = MonitorAnalysisThrottle()
        check(throttle.analyze(source, false, false, 0) == null)
        val both = checkNotNull(throttle.analyze(source, true, true, 1000))
        val following = checkNotNull(throttle.analyze(source, true, true, 1100))
        check(following.falseColor !== both.falseColor)
        check(following.waveform === both.waveform)
        check(throttle.analyze(source, true, true, 1125) !== both)
        val color = checkNotNull(both.falseColor).asAndroidBitmap()
        check(color.width == 256 && color.height == 192)
        check(color.getPixel(0, 0) == falseColorForLuma(0))
        check(color.getPixel(255, 100) == falseColorForLuma(254))
        val wave = checkNotNull(both.waveform).asAndroidBitmap()
        check(wave.width == 256 && wave.height == 128)
        check(Color.alpha(wave.getPixel(0, 127)) > 0 && (Color.alpha(wave.getPixel(255, 0)) > 0 || Color.alpha(wave.getPixel(255, 1)) > 0))
        check(wave.getPixel(0, 0) == 0 && wave.getPixel(255, 127) == 0)
        check(source.getPixel(0, 0) == Color.BLACK && source.getPixel(639, 0) == Color.WHITE)
        val onlyWave = checkNotNull(throttle.analyze(source, false, true, 1130))
        check(onlyWave.falseColor == null && onlyWave.waveform != null)
        check(throttle.analyze(source, false, false, 1131) == null)
        val red = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.RED) }
        val rgbHistogram = calculateLuminanceHistogram(red, includeRgb = true)
        check(rgbHistogram.rgb!![0][255] == 1f && rgbHistogram.rgb!![0][0] == 0f)
        check(rgbHistogram.rgb!![1][0] == 1f && rgbHistogram.rgb!![2][0] == 1f)
        check(calculateLuminanceHistogram(red).rgb == null) // Photo preview remains luma-only.
        val rgb = checkNotNull(throttle.analyze(red, false, true, 1200, rgb = true))
        check(rgb.waveformMode == WaveformMode.RGB)
        val rgbWave = rgb.waveform!!.asAndroidBitmap()
        check(Color.red(rgbWave.getPixel(0, 0)) > 240 && Color.green(rgbWave.getPixel(0, 0)) == 0)
        check(Color.green(rgbWave.getPixel(0, 127)) > 240 && Color.blue(rgbWave.getPixel(0, 127)) > 240)
        check(rgbWave.getPixel(0, 64) == 0)
        check(throttle.analyze(red, false, true, 1201, rgb = true) === rgb)
        val luma = checkNotNull(throttle.analyze(red, false, true, 1202))
        check(luma !== rgb && luma.waveformMode == WaveformMode.LUMA) // Mode invalidates throttle immediately.
        check(HistogramMode.OFF.next() == HistogramMode.RGB && HistogramMode.RGB.next() == HistogramMode.LUMA && HistogramMode.LUMA.next() == HistogramMode.OFF)
        check(WaveformMode.OFF.next() == WaveformMode.LUMA && WaveformMode.LUMA.next() == WaveformMode.RGB && WaveformMode.RGB.next() == WaveformMode.OFF)
        red.recycle()
        source.recycle()
    }
}
