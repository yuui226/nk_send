package com.ztransfer.ui.screen

import android.app.Instrumentation
import android.graphics.Bitmap
import android.os.SystemClock
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import com.ztransfer.MainActivity
import com.ztransfer.R
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.ui.theme.ZTransferTheme
import com.ztransfer.viewmodel.CameraState
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import java.util.concurrent.atomic.AtomicInteger

/** Real pager/gestures, with only the camera image source substituted. No camera is required. */
internal object RemoteReviewChecks {
    @Suppress("UNCHECKED_CAST")
    fun run(instrumentation: Instrumentation, activity: MainActivity, camera: CameraViewModel, transfer: TransferViewModel) {
        val state = CameraViewModel::class.java.getDeclaredField("_state").apply { isAccessible = true }
            .get(camera) as MutableStateFlow<CameraState>
        val original = state.value
        val visible = mutableStateOf(true)
        val queued = AtomicInteger()
        val dismissed = AtomicInteger()
        val loaded = AtomicInteger()
        var rotation = 0
        val display = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        val displayWidth = display.width
        val displayHeight = display.height
        display.recycle()
        val bitmap = Bitmap.createBitmap(900, 600, Bitmap.Config.RGB_565).apply { eraseColor(0xff40785a.toInt()) }
        val image = bitmap.asImageBitmap()
        val files = (1..4).map { NikonCamera.FileInfo(it, 100, "REVIEW_000$it.JPG", "20261015T12000$it") }
        fun labels(node: AccessibilityNodeInfo? = instrumentation.uiAutomation.rootInActiveWindow): List<String> {
            if (node == null) return emptyList()
            return buildList {
                node.text?.toString()?.let(::add)
                node.contentDescription?.toString()?.let(::add)
                for (i in 0 until node.childCount) addAll(labels(node.getChild(i)))
            }
        }
        fun await(message: String, test: () -> Boolean) {
            val deadline = SystemClock.uptimeMillis() + 8_000
            while (!test() && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(40)
            check(test()) { "$message; dismissed=${dismissed.get()}, queued=${queued.get()}; labels=${labels()}" }
        }
        fun screenshot(name: String) {
            val shot = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
            java.io.File(activity.filesDir, name).outputStream().use { shot.compress(Bitmap.CompressFormat.PNG, 100, it) }
            shot.recycle()
        }
        fun current(name: String) = labels().count { it == name } >= 2
        fun photoArea(checkLayout: Boolean = false): Int {
            val shot = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
            val bounds = android.graphics.Rect(shot.width, shot.height, 0, 0)
            for (y in 0 until shot.height step 2) for (x in 0 until shot.width step 2) {
                val color = shot.getPixel(x, y)
                if (android.graphics.Color.red(color) in 55..85 && android.graphics.Color.green(color) in 105..135 &&
                    android.graphics.Color.blue(color) in 75..105) {
                    bounds.left = minOf(bounds.left, x); bounds.top = minOf(bounds.top, y)
                    bounds.right = maxOf(bounds.right, x); bounds.bottom = maxOf(bounds.bottom, y)
                }
            }
            if (checkLayout) {
                // In landscape a 3:2 photo should use nearly the entire short screen dimension.
                check(bounds.width() > shot.width * .88f) { "Photo is undersized in layout $rotation: $bounds" }
                for (y in listOf(2, shot.height - 3)) {
                    val pixel = shot.getPixel(shot.width / 2, y)
                    check((pixel and 0xffffff) == 0) { "Review backdrop does not cover the system-bar edge" }
                }
                if (rotation != 0) {
                    fun find(node: AccessibilityNodeInfo?): android.graphics.Rect? {
                        if (node == null) return null
                        if (node.contentDescription?.toString() == activity.getString(R.string.cd_rotate_photo)) {
                            return android.graphics.Rect().also(node::getBoundsInScreen)
                        }
                        for (i in 0 until node.childCount) find(node.getChild(i))?.let { return it }
                        return null
                    }
                    val button = checkNotNull(find(instrumentation.uiAutomation.rootInActiveWindow))
                    val bottomGap = if (rotation == 1) button.exactCenterX() else shot.width - button.exactCenterX()
                    check(bottomGap < 40f * activity.resources.displayMetrics.density) {
                        "Landscape action is too far from the bottom edge: $bottomGap"
                    }
                }
            }
            shot.recycle()
            return bounds.width() * bounds.height()
        }
        fun screenPoint(x: Float, y: Float): Pair<Float, Float> {
            val point = when (rotation) {
                1 -> (1f-y) to x
                2 -> y to (1f-x)
                else -> x to y
            }
            // No screenshot/IPC between two taps: that can exceed Android's double-tap timeout.
            return point.first*displayWidth to point.second*displayHeight
        }
        fun tap() {
            val point = screenPoint(.5f, .5f)
            val down = SystemClock.uptimeMillis()
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, point.first, point.second, 0)
                instrumentation.sendPointerSync(event); event.recycle(); SystemClock.sleep(30)
            }
        }
        fun doubleTap() { tap(); SystemClock.sleep(50); tap(); SystemClock.sleep(450) }
        fun pinch(from: Float, to: Float) {
            val start = listOf(screenPoint(.5f-from, .5f), screenPoint(.5f+from, .5f))
            val end = listOf(screenPoint(.5f-to, .5f), screenPoint(.5f+to, .5f))
            val properties = Array(2) { i -> MotionEvent.PointerProperties().apply { id=i; toolType=MotionEvent.TOOL_TYPE_FINGER } }
            val down = SystemClock.uptimeMillis()
            fun send(action: Int, count: Int, fraction: Float) {
                val coords = Array(count) { i -> MotionEvent.PointerCoords().apply {
                    x=start[i].first+(end[i].first-start[i].first)*fraction
                    y=start[i].second+(end[i].second-start[i].second)*fraction
                    pressure=1f; size=1f
                } }
                val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, count, properties, coords,
                    0, 0, 1f, 1f, 0, 0, android.view.InputDevice.SOURCE_TOUCHSCREEN, 0)
                instrumentation.sendPointerSync(event); event.recycle(); SystemClock.sleep(16)
            }
            send(MotionEvent.ACTION_DOWN, 1, 0f)
            send(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 2, 0f)
            for (step in 1..20) send(MotionEvent.ACTION_MOVE, 2, step/20f)
            send(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 2, 1f)
            send(MotionEvent.ACTION_UP, 1, 1f)
            SystemClock.sleep(400)
        }
        fun swipe(x1: Float, y1: Float, x2: Float, y2: Float) {
            val screen = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
            val w = screen.width; val h = screen.height; screen.recycle()
            val down = SystemClock.uptimeMillis()
            for (step in 0..20) {
                val fraction = step / 20f
                val x = x1 + (x2-x1)*fraction
                val y = y1 + (y2-y1)*fraction
                val physical = when (rotation) {
                    1 -> (1f-y) to x
                    2 -> y to (1f-x)
                    else -> x to y
                }
                val action = when (step) { 0 -> MotionEvent.ACTION_DOWN; 20 -> MotionEvent.ACTION_UP; else -> MotionEvent.ACTION_MOVE }
                val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action,
                    physical.first*w, physical.second*h, 0)
                instrumentation.sendPointerSync(event)
                event.recycle()
                SystemClock.sleep(16)
            }
        }
        try {
            repeat(3) { layout ->
                rotation = layout
                val beforeLoad = loaded.get()
                instrumentation.runOnMainSync {
                    visible.value = true
                    state.value = original.copy(isConnectedToCamera = true)
                    activity.setContent {
                        ZTransferTheme {
                            BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                                val host = if (layout == 0) Modifier.fillMaxSize() else Modifier
                                    .requiredSize(maxHeight, maxWidth)
                                    .graphicsLayer { rotationZ = if (layout == 1) 90f else 270f }
                                Box(host) {
                                  if (visible.value) RemoteReviewSurface(layout) {
                                    PhotoPreviewOverlay(
                                        files.map { PhotoPreviewItem.Photo(it) }, 0, null, camera,
                                        hapticsEnabled = false, transfersBusy = false,
                                        activeProgressFlow = transfer.activeTransferProgress,
                                        review = PhotoReviewOptions(loadPreview = { _, _ -> loaded.incrementAndGet(); image }, landscape = layout != 0),
                                        onTransfer = { queued.incrementAndGet(); true },
                                        onCropTransfer = { _, _ -> queued.incrementAndGet(); true },
                                        onTransferBurst = { queued.incrementAndGet(); true },
                                        onDismiss = { dismissed.incrementAndGet(); visible.value = false },
                                    )
                                  }
                                }
                            }
                        }
                    }
                }
                await("Review FHD did not load in layout $layout") { loaded.get() > beforeLoad }
                SystemClock.sleep(500)
                val forbidden = listOf(R.string.cd_transfer, R.string.crop_title).map(activity::getString)
                check(labels().none { it in forbidden }) { "Review exposed a transfer/crop action" }
                screenshot("review-$layout-first.png")
                photoArea(checkLayout = true)
                swipe(.8f, .5f, .2f, .5f)
                await("Review did not page left") { current("REVIEW_0002.JPG") }
                SystemClock.sleep(700)
                screenshot("review-$layout-second.png")
                swipe(.5f, .65f, .5f, .25f)
                SystemClock.sleep(400)
                check(queued.get() == 0 && dismissed.get() == layout) { "Upward review gesture queued or dismissed a photo" }
                screenshot("review-$layout-after-up.png")
                swipe(.2f, .5f, .8f, .5f)
                SystemClock.sleep(700)
                screenshot("review-$layout-after-back.png")
                await("Review did not page back") { current("REVIEW_0001.JPG") }
                val originalArea = photoArea()
                doubleTap()
                check(dismissed.get() == layout && photoArea() > originalArea * 1.3f) { "Double tap did not zoom" }
                doubleTap()
                val resetArea = photoArea()
                check(dismissed.get() == layout && resetArea < originalArea * 1.1f) {
                    "Double tap did not reset zoom: layout=$layout, dismissed=${dismissed.get()}, area=$resetArea, original=$originalArea"
                }
                pinch(.08f, .20f)
                check(dismissed.get() == layout && photoArea() > originalArea * 1.3f) { "Pinch did not zoom in" }
                pinch(.20f, .06f)
                check(dismissed.get() == layout && photoArea() < originalArea * 1.1f) { "Pinch did not zoom out" }
                doubleTap()
                tap()
                await("Single tap did not close the zoomed review") { dismissed.get() == layout + 1 }
                // Let the previous overlay dispose before mounting the next orientation.
                SystemClock.sleep(200)
                check(queued.get() == 0)
            }
        } finally {
            instrumentation.runOnMainSync { visible.value = false; state.value = original }
            // Compose may still have a render reference; the small test bitmap is GC-owned.
        }
    }
}
