package com.ztransfer.ui.screen

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.content.Context
import android.os.Bundle
import android.os.SystemClock
import androidx.activity.compose.setContent
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.lifecycle.ViewModelProvider
import com.ztransfer.MainActivity
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.ui.theme.ZTransferTheme
import com.ztransfer.viewmodel.CameraState
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import java.util.concurrent.atomic.AtomicInteger

/** JVM tests and assembleDebug cannot detect ART rejection of the generated monitor method. */
class RemoteEntryInstrumentation : Instrumentation() {
    private var reviewOnly = false
    private var albumOnly = false

    override fun onCreate(arguments: Bundle?) {
        reviewOnly = arguments?.getString("reviewOnly")?.toBoolean() == true
        albumOnly = arguments?.getString("albumOnly")?.toBoolean() == true
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val result = Bundle()
        var activity: MainActivity? = null
        var outcome = Activity.RESULT_CANCELED
        val preferences = targetContext.getSharedPreferences("ztransfer", Context.MODE_PRIVATE)
        val pcKey = "remote_computer_control"
        val savedPc = if (preferences.contains(pcKey)) preferences.getBoolean(pcKey, false) else null
        val savedLock = preferences.getBoolean("remote_layout_locked", false)
        val savedRotation = preferences.getInt("remote_locked_rotation", 0)
        try {
            computerControlPreferences()
            // Exercise the actual production entry, not a small replacement of its viewfinder.
            Class.forName("com.ztransfer.ui.screen.RemoteScreenKt", true, targetContext.classLoader)
                .declaredMethods
            Class.forName("com.ztransfer.ui.screen.PhotoPreviewKt", true, targetContext.classLoader)
                .declaredMethods
            // The animated home page need not become idle before we replace its content.
            val monitor = addMonitor(MainActivity::class.java.name, null, false)
            targetContext.startActivity(Intent(targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            activity = checkNotNull(waitForMonitorWithTimeout(monitor, 10_000)) as MainActivity
            removeMonitor(monitor)
            await("Activity window did not resume") {
                activity.hasWindowFocus() && activity.lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)
            }
            if (!reviewOnly && !albumOnly) {
                val visible = mutableStateOf(false)
                val entered = AtomicInteger()
                val exited = AtomicInteger()
                runOnMainSync {
                    val owner = ViewModelProvider(activity)
                    val camera = owner[CameraViewModel::class.java]
                    val transfer = owner[TransferViewModel::class.java]
                    activity.setContent {
                        ZTransferTheme {
                            if (visible.value) {
                                RemoteScreen(camera, transfer, onNavigateBack = {})
                                SideEffect { entered.incrementAndGet() }
                                DisposableEffect(Unit) { onDispose { exited.incrementAndGet() } }
                            }
                        }
                    }
                }
                repeat(3) { index ->
                    val desiredPc = index % 2 == 0
                    check(preferences.edit().putBoolean(pcKey, desiredPc)
                        .putBoolean("remote_layout_locked", true).putInt("remote_locked_rotation", index).commit())
                    val before = entered.get()
                    runOnMainSync { visible.value = true }
                    await("Monitor entry ${index + 1} was not composed") { entered.get() > before }
                    SystemClock.sleep(1_500)
                    checkNotNull(uiAutomation.takeScreenshot()).let { shot ->
                        java.io.File(targetContext.filesDir, "review-monitor-$index.png").outputStream().use {
                            shot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                        }
                        shot.recycle()
                    }
                    checkReviewButtonPosition(activity, index)
                    runOnMainSync { visible.value = false }
                    await("Monitor exit was not disposed") { exited.get() == index + 1 }
                    check(RemoteToolPreferences(preferences).computerControl.value == desiredPc) {
                        "Monitor entry/disconnect/exit erased the saved PC choice"
                    }
                }
                runOnMainSync { albumRefreshWaitsForPreview(ViewModelProvider(activity)[CameraViewModel::class.java]) }
            }
            val camera = ViewModelProvider(activity)[CameraViewModel::class.java]
            val transfer = ViewModelProvider(activity)[TransferViewModel::class.java]
            if (albumOnly) AlbumPreviewChecks.run(this, activity, camera, transfer)
            else RemoteReviewChecks.run(this, activity, camera, transfer)
            result.putString("result", when {
                albumOnly -> "PASS: real album JPG/NEF/video tools, effects master switch, paging in both directions, stable tool positions, no unintended queue/close, and ART verification"
                reviewOnly -> "PASS: portrait and both landscape review FHD/paging/no-queue/close, PC preference persistence/off/hide, and ART verification"
                else -> "PASS: portrait and both landscape review FHD/paging/no-queue/close and button placement, PC preference persistence/off/hide, ART verification, three monitor entry/exit cycles, and deferred album refresh after overlapping FHD preview"
            })
            outcome = Activity.RESULT_OK
        } catch (error: Throwable) {
            result.putString("failure", error.stackTraceToString())
        } finally {
            activity?.let { runOnMainSync { it.finish() } }
            preferences.edit().apply {
                if (savedPc == null) remove(pcKey) else putBoolean(pcKey, savedPc)
                putBoolean("remote_layout_locked", savedLock)
                putInt("remote_locked_rotation", savedRotation)
            }.commit()
        }
        finish(outcome, result)
    }

    private fun checkReviewButtonPosition(activity: MainActivity, rotation: Int) {
        val label = activity.getString(com.ztransfer.R.string.remote_review)
        fun find(node: android.view.accessibility.AccessibilityNodeInfo?): android.graphics.Rect? {
            if (node == null) return null
            if (node.contentDescription?.toString() == label) {
                return android.graphics.Rect().also(node::getBoundsInScreen)
            }
            for (index in 0 until node.childCount) find(node.getChild(index))?.let { return it }
            return null
        }
        val bounds = checkNotNull(find(uiAutomation.rootInActiveWindow)) { "Review button missing in layout $rotation" }
        val display = checkNotNull(uiAutomation.takeScreenshot())
        val x = bounds.exactCenterX() / display.width
        val y = bounds.exactCenterY() / display.height
        display.recycle()
        val expectedCorner = when (rotation) {
            0 -> x < .25f && y > .75f // portrait shutter row, left of the centered shutter
            1 -> x < .30f && y > .70f // clockwise landscape bottom-right
            else -> x > .70f && y < .30f // counterclockwise landscape bottom-right
        }
        check(expectedCorner) { "Review button is in the wrong corner: rotation=$rotation, x=$x, y=$y" }
    }

    /** Exercise the real ViewModel pause/resume path without adding production test hooks. */
    @Suppress("UNCHECKED_CAST")
    private fun albumRefreshWaitsForPreview(viewModel: CameraViewModel) {
        fun field(name: String) = CameraViewModel::class.java.getDeclaredField(name).apply { isAccessible = true }
        val cameraField = field("camera")
        check(cameraField.get(viewModel) == null) { "This test requires no connected camera" }
        val state = field("_state").get(viewModel) as MutableStateFlow<CameraState>
        val generation = field("fileLoadGeneration")
        val pending = field("fileLoadPending")
        val originalState = state.value
        val existing = NikonCamera.FileInfo(101, 1024, "DSC_0101.JPG", "20261015T120000")
        // No transport exists. The unconfirmed-PC guard stops the eventual scan before IO;
        // this also verifies that a failed recovery preserves the published album.
        val camera = NikonCamera(targetContext).apply { remoteControlModeSet = true }
        viewModel.setFhdActive(true)
        val monitor = viewModel.acquireRemoteActivity()
        try {
            cameraField.set(viewModel, camera)
            state.value = originalState.copy(
                isConnectedToCamera = true, hasCompletedFileScan = true,
                isLoadingFiles = false, files = listOf(existing),
            )
            val before = generation.getLong(viewModel)
            monitor.close()
            check(generation.getLong(viewModel) == before + 1) { "Monitor refresh was lost while FHD was active" }
            check(pending.getBoolean(viewModel)) { "Refresh was not retained for preview close" }
            check(!state.value.isLoadingFiles) { "Scan started before preview released the camera" }
            check(state.value.files == listOf(existing)) { "Deferred refresh discarded the album" }
            viewModel.setFhdActive(false)
            check(generation.getLong(viewModel) == before + 2) { "Preview close did not resume the pending refresh" }
            check(state.value.files == listOf(existing)) { "Unconfirmed mode release discarded the album" }
        } finally {
            state.value = originalState
            cameraField.set(viewModel, null)
            monitor.close()
            viewModel.setFhdActive(false)
        }
    }

    private fun computerControlPreferences() {
        val disk = targetContext.getSharedPreferences("remote-pc-preference-test", Context.MODE_PRIVATE)
        disk.edit().clear().commit()
        try {
            var tools = RemoteToolPreferences(disk)
            check(!tools.computerControl.value)
            tools.computerControl.value = true
            tools = RemoteToolPreferences(disk)
            check(tools.computerControl.value)
            tools.computerControl.value = false
            check(!RemoteToolPreferences(disk).computerControl.value)
            for (movie in listOf(false, true)) {
                tools.computerControl.value = true
                tools.layout(movie).setVisible(RemoteTool.COMPUTER_CONTROL, false)
                check(!RemoteToolPreferences(disk).computerControl.value)
            }
        } finally { disk.edit().clear().commit() }
    }

    private fun await(message: String, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 10_000
        while (!condition() && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(20)
        check(condition()) { message }
    }
}
