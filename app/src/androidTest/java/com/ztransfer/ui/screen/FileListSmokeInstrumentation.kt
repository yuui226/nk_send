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
import android.os.SystemClock
import android.util.LruCache
import android.view.KeyEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import com.ztransfer.MainActivity
import com.ztransfer.R
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.ui.theme.ThemeMode
import com.ztransfer.ui.theme.ZTransferTheme
import com.ztransfer.viewmodel.CameraState
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferState
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.File

/** Actual album screen on an emulator, using isolated preferences/cache and synthetic photos. */
class FileListSmokeInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val report = Bundle()
        val store = ViewModelStore()
        var activity: MainActivity? = null
        var outcome = Activity.RESULT_CANCELED
        try {
            check(Build.FINGERPRINT.contains("generic") || Build.MODEL.contains("sdk", ignoreCase = true)) {
                "This smoke test is emulator-only"
            }
            check((targetContext.getSystemService(Context.USB_SERVICE) as UsbManager).deviceList.isEmpty()) {
                "Disconnect USB devices before running the synthetic catalog test"
            }
            val monitor = addMonitor(MainActivity::class.java.name, null, false)
            targetContext.startActivity(Intent(targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            activity = checkNotNull(waitForMonitorWithTimeout(monitor, 10_000)) as MainActivity
            removeMonitor(monitor)
            val host = checkNotNull(activity)
            val isolated = SmokeApplication(host.application)
            // This flag only pauses this isolated VM's AP discovery; no GPS service is started.
            isolated.getSharedPreferences("nikon_gps", Context.MODE_PRIVATE).edit()
                .putBoolean("enabled", true).commit()
            isolated.getSharedPreferences("ztransfer", Context.MODE_PRIVATE).edit()
                .putBoolean("remote_entry_intro_v2_used", true).commit()
            lateinit var camera: CameraViewModel
            lateinit var transfer: TransferViewModel
            lateinit var state: MutableStateFlow<CameraState>
            val photos = (1..6).map { index -> NikonCamera.FileInfo(
                handle = 880_000 + index,
                size = 1_024L,
                fileName = "SMOKE_${index.toString().padStart(4, '0')}.JPG",
                captureDate = "20261028T1200${(index * 3).toString().padStart(2, '0')}",
            ) }
            runOnMainSync {
                val provider = ViewModelProvider(store, ViewModelProvider.AndroidViewModelFactory(isolated))
                camera = provider[CameraViewModel::class.java]
                transfer = provider[TransferViewModel::class.java]
                check(camera.getCamera() == null)
                @Suppress("UNCHECKED_CAST")
                val injectedState = CameraViewModel::class.java.getDeclaredField("_state")
                    .apply { isAccessible = true }.get(camera) as MutableStateFlow<CameraState>
                state = injectedState
                @Suppress("UNCHECKED_CAST")
                val cache = CameraViewModel::class.java.getDeclaredField("thumbnailCache")
                    .apply { isAccessible = true }.get(camera) as LruCache<Int, ImageBitmap>
                photos.forEachIndexed { index, file ->
                    cache.put(file.handle, Bitmap.createBitmap(120, 80, Bitmap.Config.RGB_565)
                        .apply { eraseColor(0xff407040.toInt() + index * 0x080808) }.asImageBitmap())
                }
                @Suppress("UNCHECKED_CAST")
                val transferState = TransferViewModel::class.java.getDeclaredField("_state")
                    .apply { isAccessible = true }.get(transfer) as MutableStateFlow<TransferState>
                transferState.value = TransferState(thumbnailColumns = 3, hapticsEnabled = false,
                    collapseBurstPhotos = false, photoEffectsEnabled = false)
                state.value = state.value.copy(files = photos, isConnectedToCamera = true,
                    isLoadingFiles = false, hasCompletedFileScan = true)
                host.setContent {
                    ZTransferTheme(themeMode = ThemeMode.LIGHT) {
                        FileListScreen(camera, transfer,
                            queueTargetBounds = null,
                            onQueueFlightStarted = {}, onQueueFlightFinished = {},
                            onQueueFlightsCancelled = {}, onQueueFlightCaught = {},
                            onPreviewVisibilityChanged = {}, backHandlerEnabled = true,
                            onRequestExitConfirmation = {}, onNavigateToRemote = {})
                    }
                }
            }
            val day = "2026-10-28"
            await("Initial photos missing") { node(photos.first().fileName) != null && node(day) != null }
            screenshot("file-list-initial.png")
            repeat(2) {
                clickLabel(day)
                await("Date did not collapse") { node(day) != null && node(photos.first().fileName) == null }
                SystemClock.sleep(350)
                clickLabel(day)
                await("Date did not expand") { node(photos.first().fileName) != null }
                SystemClock.sleep(350)
            }
            runOnMainSync { state.value = state.value.copy(files = emptyList()) }
            await("Deleted photos/header remained after catalog exit") { node(day) == null && node(photos.first().fileName) == null }
            SystemClock.sleep(400)
            runOnMainSync { state.value = state.value.copy(files = listOf(photos.first())) }
            await("First photo on empty card did not return") { node(day) != null && node(photos.first().fileName) != null }
            SystemClock.sleep(400)
            clickLabel(day)
            await("Catalog animation left date input locked") { node(photos.first().fileName) == null }
            SystemClock.sleep(350)
            clickLabel(day)
            await("Restored date did not expand") { node(photos.first().fileName) != null }

            clickLabel(host.getString(R.string.cd_filter_type))
            await("Filter panel did not open") { node(host.getString(R.string.filter_untransferred)) != null }
            screenshot("file-list-filter.png")
            sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            await("Filter panel did not close") { node(host.getString(R.string.filter_untransferred)) == null }
            SystemClock.sleep(300)
            // The existing ZMark entry has no label. Resolve the actual top-left clickable node,
            // rather than adding a production test tag or assuming a device-specific coordinate.
            val dateTop = bounds(checkNotNull(node(day))).top
            val settingsEntry = allNodes().filter { it.isVisibleToUser && it.isClickable }
                .filter { bounds(it).bottom <= dateTop && !bounds(it).isEmpty }
                .minByOrNull { bounds(it).left }
            checkNotNull(settingsEntry) { "Missing top-left settings entry" }
                .performAction(AccessibilityNodeInfo.ACTION_CLICK)
            await("Settings panel did not open") { node(host.getString(R.string.settings)) != null }
            screenshot("file-list-settings.png")
            sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            await("Settings panel did not close") { node(host.getString(R.string.settings)) == null }
            check(transfer.state.value.tasks.isEmpty()) { "Smoke interaction unexpectedly queued a photo" }
            check(camera.getCamera() == null) { "Smoke test connected a real camera" }
            screenshot("file-list-restored.png")
            report.putString("result", "PASS: real album fold/unfold, empty-card recovery, filter and settings")
            outcome = Activity.RESULT_OK
        } catch (error: Throwable) {
            report.putString("error", error.stackTraceToString())
        } finally {
            runOnMainSync { activity?.setContent { }; store.clear(); activity?.finish() }
        }
        finish(outcome, report)
    }

    private fun allNodes(): List<AccessibilityNodeInfo> {
        if (Build.VERSION.SDK_INT >= 33) uiAutomation.clearCache()
        val result = ArrayList<AccessibilityNodeInfo>()
        fun visit(node: AccessibilityNodeInfo?) {
            if (node == null) return
            result += node
            for (index in 0 until node.childCount) visit(node.getChild(index))
        }
        visit(uiAutomation.rootInActiveWindow)
        return result
    }

    private fun node(label: String): AccessibilityNodeInfo? = allNodes().firstOrNull {
        it.isVisibleToUser && (it.text?.toString()?.lines()?.contains(label) == true ||
            it.contentDescription?.toString() == label)
    }

    private fun clickLabel(label: String) {
        await("Missing action $label") { node(label) != null }
        var action = checkNotNull(node(label))
        while (!action.isClickable) action = checkNotNull(action.parent) { "$label has no clickable ancestor" }
        check(action.performAction(AccessibilityNodeInfo.ACTION_CLICK)) { "$label rejected click" }
    }

    private fun bounds(node: AccessibilityNodeInfo) = Rect().also(node::getBoundsInScreen)

    private fun await(message: String, predicate: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 8_000
        while (SystemClock.uptimeMillis() < deadline) {
            if (predicate()) return
            SystemClock.sleep(40)
        }
        check(predicate()) { message }
    }

    private fun screenshot(name: String) {
        val bitmap = checkNotNull(uiAutomation.takeScreenshot())
        File(targetContext.filesDir, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    private class SmokeApplication(base: Context) : Application() {
        init { attachBaseContext(base) }
        override fun getApplicationContext(): Context = this
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
            super.getSharedPreferences("file_list_smoke_$name", mode)
        override fun getCacheDir(): File = File(super.getCacheDir(), "file-list-smoke").apply { mkdirs() }
    }
}
