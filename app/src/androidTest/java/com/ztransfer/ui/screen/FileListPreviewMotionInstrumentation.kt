package com.ztransfer.ui.screen

import android.app.Activity
import android.app.Application
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.Rect
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.LruCache
import android.view.PixelCopy
import android.view.ViewTreeObserver
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import com.ztransfer.MainActivity
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.ui.theme.ThemeMode
import com.ztransfer.ui.theme.ZTransferTheme
import com.ztransfer.viewmodel.CameraState
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferState
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs

/** Captures real album -> preview opening frames, without production hooks or a camera. */
class FileListPreviewMotionInstrumentation : Instrumentation() {
    private var rotationQuarterTurns = 0
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        rotationQuarterTurns = arguments?.getString("rotation")?.toIntOrNull() ?: 0
        start()
    }

    override fun onStart() {
        val report = Bundle()
        val store = ViewModelStore()
        var activity: MainActivity? = null
        var captures: FrameCaptures? = null
        var outcome = Activity.RESULT_CANCELED
        try {
            check(Build.FINGERPRINT.contains("generic") || Build.MODEL.contains("sdk", true)) {
                "Synthetic preview motion capture is emulator-only"
            }
            check((targetContext.getSystemService(Context.USB_SERVICE) as UsbManager).deviceList.isEmpty())
            val monitor = addMonitor(MainActivity::class.java.name, null, false)
            targetContext.startActivity(Intent(targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            activity = checkNotNull(waitForMonitorWithTimeout(monitor, 10_000)) as MainActivity
            removeMonitor(monitor)
            val host = checkNotNull(activity)
            val isolated = PreviewApplication(host.application)
            // Suppress AP discovery in this isolated VM. This does not start GPS or change user preferences.
            isolated.getSharedPreferences("nikon_gps", Context.MODE_PRIVATE).edit()
                .putBoolean("enabled", true).commit()
            val previewVisible = AtomicBoolean()
            val files = (1..6).map { index -> NikonCamera.FileInfo(
                handle = 970_000 + index, size = 1024,
                fileName = "MOTION_${index.toString().padStart(4, '0')}.JPG",
                captureDate = "20261028T1200${(index * 3).toString().padStart(2, '0')}",
            ) }
            // Off-centre source makes a wrong centre/pivot obvious, unlike the middle grid cell.
            val selected = files[0]
            lateinit var camera: CameraViewModel
            lateinit var transfer: TransferViewModel
            runOnMainSync {
                val provider = ViewModelProvider(store, ViewModelProvider.AndroidViewModelFactory(isolated))
                camera = provider[CameraViewModel::class.java]
                transfer = provider[TransferViewModel::class.java]
                check(camera.getCamera() == null)
                @Suppress("UNCHECKED_CAST")
                val state = CameraViewModel::class.java.getDeclaredField("_state")
                    .apply { isAccessible = true }.get(camera) as MutableStateFlow<CameraState>
                @Suppress("UNCHECKED_CAST")
                val cache = CameraViewModel::class.java.getDeclaredField("thumbnailCache")
                    .apply { isAccessible = true }.get(camera) as LruCache<Int, ImageBitmap>
                files.forEach { file ->
                    cache.put(file.handle, Bitmap.createBitmap(600, 400, Bitmap.Config.ARGB_8888)
                        .apply { eraseColor(if (file == selected) 0xffff00ff.toInt() else 0xff306040.toInt()) }
                        .asImageBitmap())
                }
                @Suppress("UNCHECKED_CAST")
                val transferState = TransferViewModel::class.java.getDeclaredField("_state")
                    .apply { isAccessible = true }.get(transfer) as MutableStateFlow<TransferState>
                transferState.value = TransferState(thumbnailColumns = 3, hapticsEnabled = false,
                    collapseBurstPhotos = false, photoEffectsEnabled = false, tapToPreview = true,
                    previewRotationQuarterTurns = rotationQuarterTurns)
                state.value = state.value.copy(files = files, isConnectedToCamera = true,
                    isLoadingFiles = false, hasCompletedFileScan = true)
                host.setContent {
                    ZTransferTheme(themeMode = ThemeMode.LIGHT) {
                        FileListScreen(camera, transfer, queueTargetBounds = null,
                            onQueueFlightStarted = {}, onQueueFlightFinished = {},
                            onQueueFlightsCancelled = {}, onQueueFlightCaught = {},
                            onPreviewVisibilityChanged = { previewVisible.set(it) },
                            backHandlerEnabled = true, onRequestExitConfirmation = {},
                            onNavigateToRemote = {})
                    }
                }
            }
            await("Selected thumbnail missing") { node(selected.fileName) != null }
            SystemClock.sleep(500) // Let initial date/thumb entrance finish before measuring the opening.
            var action = checkNotNull(node(selected.fileName))
            while (!action.isClickable) action = checkNotNull(action.parent)
            val cell = Rect().also(action::getBoundsInScreen)
            val collector = FrameCaptures(host, previewVisible)
            captures = collector
            runOnMainSync { collector.capture("before") }
            await("Baseline PixelCopy failed") { collector.completed.get() >= 1 }
            collector.tapAtMs = SystemClock.uptimeMillis()
            runOnMainSync { collector.start() }
            check(action.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            await("Preview did not open") { previewVisible.get() }
            SystemClock.sleep(900)
            runOnMainSync { collector.stop(); collector.capture("settled-a") }
            await("First settled frame missing") { collector.pending.get() == 0 }
            SystemClock.sleep(100)
            runOnMainSync { collector.capture("settled-b") }
            await("Second settled frame missing") { collector.pending.get() == 0 }

            val before = checkNotNull(collector.markerBounds("before")) { "No magenta source in baseline" }
            val finalA = checkNotNull(collector.markerBounds("settled-a")) { "No photo at final position" }
            val finalB = checkNotNull(collector.markerBounds("settled-b")) { "Final photo disappeared" }
            check(cell.contains(before.centerX(), before.centerY())) { "Marker $before is not in clicked cell $cell" }
            check(finalA.width() > before.width() * 1.5f) { "Preview did not expand: $before -> $finalA" }
            check(listOf(abs(finalA.left-finalB.left), abs(finalA.top-finalB.top),
                abs(finalA.right-finalB.right), abs(finalA.bottom-finalB.bottom)).all { it <= 4 }) {
                "Settled preview jumped: $finalA -> $finalB"
            }
            sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
            await("Preview did not return to the source grid") { !previewVisible.get() }
            check(node(selected.fileName) != null) { "Source photo missing after return" }
            check(camera.getCamera() == null && transfer.state.value.tasks.isEmpty())
            collector.notes = "clickedCell=$cell\nsourceMarker=$before\nsettledMarker=$finalB\n" +
                "Opening origin: inspect the opening PNG sequence and CSV. PixelCopy is asynchronous, " +
                "so missing a vsync is not itself a failure. During expansion both the source tile " +
                "and preview can be magenta; CSV records their combined bounds, not a fabricated animation rect.\n"
            report.putString("result", "PASS: real grid click opens/settles without queuing; opening frames captured for origin inspection")
            outcome = Activity.RESULT_OK
        } catch (error: Throwable) {
            report.putString("error", error.stackTraceToString())
        } finally {
            captures?.let { collector ->
                runOnMainSync { collector.stop() }
                runCatching {
                    await("PixelCopy callbacks did not finish") { collector.pending.get() == 0 }
                    report.putString("frames", collector.writeFiles().absolutePath)
                }.onFailure { report.putString("captureError", it.stackTraceToString()) }
                collector.close()
            }
            runOnMainSync { activity?.setContent { }; store.clear(); activity?.finish() }
        }
        finish(outcome, report)
    }

    private fun node(label: String): AccessibilityNodeInfo? {
        if (Build.VERSION.SDK_INT >= 33) uiAutomation.clearCache()
        fun find(current: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
            if (current == null) return null
            if (current.isVisibleToUser && (current.text?.toString()?.lines()?.contains(label) == true ||
                current.contentDescription?.toString() == label)) return current
            for (index in 0 until current.childCount) find(current.getChild(index))?.let { return it }
            return null
        }
        return find(uiAutomation.rootInActiveWindow)
    }

    private fun await(message: String, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 8_000
        while (!condition() && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(20)
        check(condition()) { message }
    }

    private class FrameCaptures(val activity: MainActivity, val visible: AtomicBoolean) {
        private val worker = HandlerThread("preview-frame-copy").apply { start() }
        private val handler = Handler(worker.looper)
        private val decor = activity.window.decorView
        private val origin = IntArray(2).also(decor::getLocationOnScreen)
        private val frames = ConcurrentLinkedQueue<Frame>()
        private var sequence = 0
        val pending = AtomicInteger()
        val completed = AtomicInteger()
        var tapAtMs = 0L
        var notes = ""
        private val listener = ViewTreeObserver.OnDrawListener {
            // Bounded memory and requests: capture actual draws, without requesting extra app frames.
            if (sequence < 25 && pending.get() < 3) capture("opening")
        }

        fun start() = decor.viewTreeObserver.addOnDrawListener(listener)
        fun stop() { if (decor.viewTreeObserver.isAlive) decor.viewTreeObserver.removeOnDrawListener(listener) }

        fun capture(label: String) {
            val index = sequence++
            val drawAt = SystemClock.uptimeMillis()
            val isPreview = visible.get()
            // Small destination keeps 24 frames comfortably bounded on a low-memory emulator.
            val bitmap = Bitmap.createBitmap((decor.width / 3).coerceAtLeast(1),
                (decor.height / 3).coerceAtLeast(1), Bitmap.Config.ARGB_8888)
            pending.incrementAndGet()
            try {
                PixelCopy.request(activity.window, bitmap, { result ->
                    frames += Frame(index, label, drawAt, SystemClock.uptimeMillis(), isPreview, result, bitmap)
                    completed.incrementAndGet()
                    pending.decrementAndGet()
                }, handler)
            } catch (error: Throwable) {
                pending.decrementAndGet()
                bitmap.recycle()
                throw error
            }
        }

        fun markerBounds(label: String): Rect? = frames.firstOrNull { it.label == label }?.let(::markerBounds)

        private fun markerBounds(frame: Frame): Rect? {
            if (frame.result != PixelCopy.SUCCESS) return null
            val bitmap = frame.bitmap
            val pixels = IntArray(bitmap.width * bitmap.height)
            bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
            var left = bitmap.width; var top = bitmap.height; var right = -1; var bottom = -1
            pixels.forEachIndexed { index, pixel ->
                val red = (pixel ushr 16) and 255; val green = (pixel ushr 8) and 255; val blue = pixel and 255
                if (red >= 80 && blue >= 80 && green < minOf(red, blue) / 3 && abs(red-blue) < 45) {
                    val x = index % bitmap.width; val y = index / bitmap.width
                    left = minOf(left, x); right = maxOf(right, x)
                    top = minOf(top, y); bottom = maxOf(bottom, y)
                }
            }
            if (right < left) return null
            return Rect(origin[0] + left * decor.width / bitmap.width,
                origin[1] + top * decor.height / bitmap.height,
                origin[0] + (right+1) * decor.width / bitmap.width,
                origin[1] + (bottom+1) * decor.height / bitmap.height)
        }

        fun writeFiles(): File {
            val dir = File(activity.filesDir, "preview-motion-${System.currentTimeMillis()}").apply { mkdirs() }
            val csv = StringBuilder("frame,label,drawAfterTapMs,copyAfterTapMs,previewVisible,result,markerBoundsScreen\n")
            frames.sortedBy { it.index }.forEach { frame ->
                val name = "${frame.index.toString().padStart(2, '0')}-${frame.label}.png"
                File(dir, name).outputStream().use { frame.bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                csv.append("${frame.index},${frame.label},${frame.drawAt-tapAtMs},${frame.copiedAt-tapAtMs},")
                    .append("${frame.preview},${frame.result},\"${markerBounds(frame)}\"\n")
            }
            File(dir, "frames.csv").writeText(csv.toString())
            File(dir, "notes.txt").writeText(notes)
            return dir
        }

        fun close() { worker.quitSafely(); worker.join(2_000); frames.forEach { it.bitmap.recycle() } }
        private data class Frame(val index: Int, val label: String, val drawAt: Long, val copiedAt: Long,
            val preview: Boolean, val result: Int, val bitmap: Bitmap)
    }

    private class PreviewApplication(base: Context) : Application() {
        init { attachBaseContext(base) }
        override fun getApplicationContext(): Context = this
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
            super.getSharedPreferences("preview_motion_$name", mode)
        override fun getCacheDir(): File = File(super.getCacheDir(), "preview-motion").apply { mkdirs() }
    }
}
