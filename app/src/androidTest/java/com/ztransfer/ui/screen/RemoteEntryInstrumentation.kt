package com.ztransfer.ui.screen

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import androidx.activity.compose.setContent
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.lifecycle.ViewModelProvider
import com.ztransfer.MainActivity
import com.ztransfer.ui.theme.ZTransferTheme
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferViewModel
import java.util.concurrent.atomic.AtomicInteger

/** JVM tests and assembleDebug cannot detect ART rejection of the generated monitor method. */
class RemoteEntryInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val result = Bundle()
        var activity: MainActivity? = null
        var outcome = Activity.RESULT_CANCELED
        try {
            // Exercise the actual production entry, not a small replacement of its viewfinder.
            Class.forName("com.ztransfer.ui.screen.RemoteScreenKt", true, targetContext.classLoader)
                .declaredMethods
            // The animated home page need not become idle before we replace its content.
            val monitor = addMonitor(MainActivity::class.java.name, null, false)
            targetContext.startActivity(Intent(targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            activity = checkNotNull(waitForMonitorWithTimeout(monitor, 10_000)) as MainActivity
            removeMonitor(monitor)
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
                val before = entered.get()
                runOnMainSync { visible.value = true }
                await("Monitor entry ${index + 1} was not composed") { entered.get() > before }
                SystemClock.sleep(500)
                checkNotNull(uiAutomation.takeScreenshot()).recycle()
                runOnMainSync { visible.value = false }
                await("Monitor exit was not disposed") { exited.get() == index + 1 }
            }
            result.putString("result", "PASS: ART class verification and three real monitor entry/render/exit cycles without a camera")
            outcome = Activity.RESULT_OK
        } catch (error: Throwable) {
            result.putString("failure", error.stackTraceToString())
        } finally {
            activity?.let { runOnMainSync { it.finish() } }
        }
        finish(outcome, result)
    }

    private fun await(message: String, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 10_000
        while (!condition() && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(20)
        check(condition()) { message }
    }
}
