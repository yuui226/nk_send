package com.ztransfer.ui.screen

import android.app.Instrumentation
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Build
import android.os.SystemClock
import android.util.LruCache
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.ztransfer.MainActivity
import com.ztransfer.R
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.ui.theme.ZTransferTheme
import com.ztransfer.viewmodel.CameraState
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import java.util.concurrent.atomic.AtomicInteger

/** Exercise the album branch on ART with real cached images, without a camera or production hooks. */
internal object AlbumPreviewChecks {
    @Suppress("UNCHECKED_CAST")
    fun run(instrumentation: Instrumentation, activity: MainActivity, camera: CameraViewModel, transfer: TransferViewModel) {
        check(camera.getCamera() == null) { "Album preview checks require no connected camera" }
        fun field(name: String) = CameraViewModel::class.java.getDeclaredField(name).apply { isAccessible = true }
        val state = field("_state").get(camera) as MutableStateFlow<CameraState>
        val cache = field("thumbnailCache").get(camera) as LruCache<Int, ImageBitmap>
        val original = state.value
        val visible = mutableStateOf(true)
        val effectsEnabled = mutableStateOf(true)
        val dismissed = AtomicInteger()
        val queued = AtomicInteger()
        val files = listOf("JPG", "NEF", "MOV").mapIndexed { index, extension ->
            NikonCamera.FileInfo(640_001 + index, 1024, "ALBUM_000${index + 1}.$extension", "20261018T12000$index")
        }
        val previousImages = files.associate { it.handle to cache.get(it.handle) }
        val bitmap = Bitmap.createBitmap(900, 600, Bitmap.Config.RGB_565).apply { eraseColor(0xff477a58.toInt()) }
        val image = bitmap.asImageBitmap()
        val effect = activity.getString(R.string.photo_effects_open_editor)
        val crop = activity.getString(R.string.crop_title)
        val histogram = activity.getString(R.string.cd_preview_histogram)
        val rotate = activity.getString(R.string.cd_rotate_photo)

        fun node(label: String): AccessibilityNodeInfo? {
            if (Build.VERSION.SDK_INT >= 33) instrumentation.uiAutomation.clearCache()
            fun find(current: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
                if (current == null) return null
                if (current.isVisibleToUser &&
                    (current.text?.toString() == label || current.contentDescription?.toString() == label)) return current
                for (index in 0 until current.childCount) find(current.getChild(index))?.let { return it }
                return null
            }
            return find(instrumentation.uiAutomation.rootInActiveWindow)
        }
        fun await(message: String, condition: () -> Boolean) {
            val deadline = SystemClock.uptimeMillis() + 8_000
            while (!condition() && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(40)
            check(condition()) { message }
        }
        fun bounds(label: String) = Rect().also { checkNotNull(node(label)) { "Missing $label" }.getBoundsInScreen(it) }
        fun checkTools(file: NikonCamera.FileInfo, effects: Boolean, cropping: Boolean, imageTools: Boolean) {
            await("Album preview did not settle on ${file.fileName}") {
                node(file.fileName) != null && (node(effect) != null) == effects &&
                    (node(crop) != null) == cropping && (node(histogram) != null) == imageTools &&
                    (node(rotate) != null) == imageTools
            }
            // Wait past the shared fade before checking the settled positions or starting another gesture.
            SystemClock.sleep(250)
        }
        fun send(action: Int, downTime: Long, x: Float, y: Float) {
            val event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, x, y, 0)
            try { instrumentation.sendPointerSync(event) } finally { event.recycle() }
        }
        fun doubleTapImage() {
            val display = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
            val x = display.width * .5f; val y = display.height * .5f
            display.recycle()
            repeat(2) { tap ->
                val down = SystemClock.uptimeMillis()
                send(MotionEvent.ACTION_DOWN, down, x, y)
                SystemClock.sleep(20)
                send(MotionEvent.ACTION_UP, down, x, y)
                if (tap == 0) SystemClock.sleep(60)
            }
            // The zoom tween takes 240 ms; allow its final frame before dragging again.
            SystemClock.sleep(300)
        }
        fun swipe(forward: Boolean) {
            val display = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
            val width = display.width; val height = display.height; display.recycle()
            val down = SystemClock.uptimeMillis()
            for (step in 0..20) {
                val fraction = step / 20f
                val x = if (forward) .8f - .6f * fraction else .2f + .6f * fraction
                val action = when (step) { 0 -> MotionEvent.ACTION_DOWN; 20 -> MotionEvent.ACTION_UP; else -> MotionEvent.ACTION_MOVE }
                send(action, down, width * x, height * .5f)
                SystemClock.sleep(16)
            }
        }
        fun checkFixedImageTools(expectedHistogram: Rect, expectedRotate: Rect) {
            for ((label, expected) in listOf(histogram to expectedHistogram, rotate to expectedRotate)) {
                val actual = bounds(label)
                check(kotlin.math.abs(actual.centerX() - expected.centerX()) <= 2 &&
                    kotlin.math.abs(actual.centerY() - expected.centerY()) <= 2) {
                    "$label moved after a visibility/page transition: $expected -> $actual"
                }
            }
        }

        try {
            instrumentation.runOnMainSync {
                files.forEach { cache.put(it.handle, image) }
                state.value = original.copy(isConnectedToCamera = false)
                activity.setContent {
                    ZTransferTheme {
                        if (visible.value) PhotoPreviewOverlay(
                            items = files.map { PhotoPreviewItem.Photo(it) },
                            initialIndex = 0, anchorRect = null, cameraViewModel = camera,
                            hapticsEnabled = false, transfersBusy = false,
                            photoEffectsViewModel = transfer,
                            photoEffectsEnabled = effectsEnabled.value,
                            activeProgressFlow = transfer.activeTransferProgress,
                            onTransfer = { queued.incrementAndGet(); true },
                            onCropTransfer = { _, _ -> queued.incrementAndGet(); true },
                            onDismiss = { dismissed.incrementAndGet(); visible.value = false },
                        )
                    }
                }
            }
            checkTools(files[0], effects = true, cropping = true, imageTools = true)
            val histogramBounds = bounds(histogram)
            val rotateBounds = bounds(rotate)
            val effectBounds = bounds(effect)
            instrumentation.runOnMainSync { effectsEnabled.value = false }
            checkTools(files[0], effects = false, cropping = true, imageTools = true)
            checkFixedImageTools(histogramBounds, rotateBounds)
            instrumentation.runOnMainSync { effectsEnabled.value = true }
            checkTools(files[0], effects = true, cropping = true, imageTools = true)
            check(bounds(effect) == effectBounds) { "Effect button changed position after toggling its master switch" }
            checkFixedImageTools(histogramBounds, rotateBounds)

            // The derived zoom gate must follow the live viewport: horizontal input pans an
            // enlarged JPEG, then becomes pager input again after double-tap restoration.
            doubleTapImage()
            swipe(forward = true)
            checkTools(files[0], effects = true, cropping = true, imageTools = true)
            check(queued.get() == 0 && dismissed.get() == 0) {
                "Zoom/pan triggered queue or dismissal"
            }
            checkFixedImageTools(histogramBounds, rotateBounds)
            doubleTapImage()

            swipe(forward = true)
            checkTools(files[1], effects = false, cropping = false, imageTools = true)
            checkFixedImageTools(histogramBounds, rotateBounds)
            swipe(forward = true)
            checkTools(files[2], effects = false, cropping = false, imageTools = false)
            swipe(forward = false)
            checkTools(files[1], effects = false, cropping = false, imageTools = true)
            checkFixedImageTools(histogramBounds, rotateBounds)
            swipe(forward = false)
            checkTools(files[0], effects = true, cropping = true, imageTools = true)
            check(bounds(effect) == effectBounds) { "Effect button changed position after paging back" }
            checkFixedImageTools(histogramBounds, rotateBounds)
            check(queued.get() == 0 && dismissed.get() == 0) { "Paging triggered an unrelated action" }
        } finally {
            instrumentation.runOnMainSync {
                visible.value = false
                state.value = original
                previousImages.forEach { (handle, previous) ->
                    if (previous == null) cache.remove(handle) else cache.put(handle, previous)
                }
            }
            // Compose may retain the image until the final frame; leave bitmap disposal to GC.
        }
    }
}
