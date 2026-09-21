package com.ztransfer.ui.screen

import android.app.Activity
import android.app.Instrumentation
import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaMetadataRetriever
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
import androidx.compose.ui.graphics.asImageBitmap
import com.ztransfer.recorder.RecordingSink
import com.ztransfer.recorder.ViewfinderRecorder
import java.io.File

/** Real Android preferences, image sampling and MediaCodec/Muxer verification. */
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
            recording(1f, false)
            recording(1.5f, true)
            if (visual) renderOverlays()
            result.putString("result", "PASS: preference restoration/migration/hidden-state repair, stable order, fixed tools, shared throttled analysis, luminance/waveform geometry, real MP4 de-squeeze and paused finalization")
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
        p.hd.value = true; p.histogram.value = true; p.waveform.value = true
        p.exposure.value = ExposureAssist.FALSE_COLOR; p.grid.value = ViewfinderGrid.entries.last()
        p.level.value = true; p.lockedRotation.value = 2; p.locked.value = true
        p.move(RemoteTool.WAVEFORM, 0)
        check(disk.edit().commit()) // wait for earlier apply writes, then reconstruct the owner
        p = RemoteToolPreferences(disk)
        check(p.hd.value && p.histogram.value && p.waveform.value && p.level.value)
        check(p.exposure.value == ExposureAssist.FALSE_COLOR && p.grid.value == ViewfinderGrid.entries.last())
        check(p.locked.value && p.lockedRotation.value == 2 && p.order.first() == RemoteTool.WAVEFORM)
        val order = p.order
        p.move(RemoteTool.ROTATE, 0); check(p.order == order)
        RemoteTool.entries.forEach { p.setVisible(it, false) }
        p = RemoteToolPreferences(disk)
        check(RemoteTool.entries.none(p::visible))
        check(!p.hd.value && !p.fps.value && !p.audio.value && !p.histogram.value && !p.waveform.value && !p.level.value && !p.locked.value)
        check(p.grid.value == ViewfinderGrid.OFF && p.exposure.value == ExposureAssist.OFF && p.desqueeze.value == 1f)
        RemoteTool.entries.forEach { p.setVisible(it, true) }
        check(RemoteTool.entries.all(p::visible) && !p.hd.value && p.exposure.value == ExposureAssist.OFF)
        check(p.order == order)
        check(disk.edit().putString("remote_tool_order", "waveform,removed,waveform,rotate,hd")
            .putString("remote_grid", "removed").putFloat("remote_desqueeze_multiplier", Float.NaN)
            .putStringSet("remote_hidden_tools", setOf("hd")).putBoolean("remote_hd", true).commit())
        p = RemoteToolPreferences(disk)
        check(p.order.take(2) == listOf(RemoteTool.WAVEFORM, RemoteTool.HD))
        check(p.order.size == RemoteTool.regular.size && p.order.distinct().size == p.order.size)
        check(!p.hd.value && p.grid.value == ViewfinderGrid.OFF && p.desqueeze.value == 1f)
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
        check(throttle.analyze(source, true, true, 1100) === both)
        check(throttle.analyze(source, true, true, 1125) !== both)
        val color = checkNotNull(both.falseColor).asAndroidBitmap()
        check(color.width == 256 && color.height == 192)
        check(color.getPixel(0, 0) == falseColorForLuma(0))
        check(color.getPixel(255, 100) == falseColorForLuma(254))
        val wave = checkNotNull(both.waveform).asAndroidBitmap()
        check(wave.width == 128 && wave.height == 64)
        check(Color.alpha(wave.getPixel(0, 63)) > 0 && Color.alpha(wave.getPixel(127, 1)) > 0)
        check(wave.getPixel(0, 0) == 0 && wave.getPixel(127, 63) == 0)
        check(source.getPixel(0, 0) == Color.BLACK && source.getPixel(639, 0) == Color.WHITE)
        val onlyWave = checkNotNull(throttle.analyze(source, false, true, 1130))
        check(onlyWave.falseColor == null && onlyWave.waveform != null)
        check(throttle.analyze(source, false, false, 1131) == null)
        source.recycle()
    }
    private fun recording(factor: Float, paused: Boolean) {
        val dir = File(targetContext.cacheDir, "remote-recording-$factor").apply { mkdirs() }
        val bitmap = Bitmap.createBitmap(320, 240, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.rgb(128, 128, 128))
        // A gray source must remain gray even when false-color analysis is calculated alongside it.
        val recorder = ViewfinderRecorder(RecordingSink.AppDir(dir), 320, 240, desqueezeMultiplier = factor)
        check(recorder.start())
        val base = SystemClock.elapsedRealtimeNanos()
        repeat(24) { index ->
            analyzeMonitorFrame(bitmap, true, true)
            check(recorder.encodeFrame(bitmap.asImageBitmap(), base + index * 33_333_333L, factor))
        }
        // A live HD-resolution change must not fail or change the file geometry.
        val large = Bitmap.createScaledBitmap(bitmap, 640, 480, true)
        repeat(6) { check(recorder.encodeFrame(large.asImageBitmap(), base + (24 + it) * 33_333_333L, factor)) }
        if (paused) recorder.pause()
        val file = File(dir, checkNotNull(recorder.stop()))
        check(!recorder.isRecording && !recorder.isPaused && file.length() > 1000)
        MediaMetadataRetriever().use { reader ->
            reader.setDataSource(file.absolutePath)
            check(reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt() == (320 * factor).toInt())
            check(reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT) == "240")
            val frame = checkNotNull(reader.getFrameAtTime(0))
            for (x in listOf(5, frame.width / 2, frame.width - 6)) {
                val pixel = frame.getPixel(x, frame.height / 2)
                check(kotlin.math.abs(Color.red(pixel) - Color.green(pixel)) < 8)
                check(kotlin.math.abs(Color.blue(pixel) - Color.green(pixel)) < 8)
                check(Color.green(pixel) in 90..165) // no letterbox or false-color tint
            }
            frame.recycle()
        }
        bitmap.recycle(); large.recycle(); file.delete()
    }
}
