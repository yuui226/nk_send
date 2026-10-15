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
        val preferences = targetContext.getSharedPreferences("ztransfer", Context.MODE_PRIVATE)
        val pcKey = "remote_computer_control"
        val savedPc = if (preferences.contains(pcKey)) preferences.getBoolean(pcKey, false) else null
        try {
            computerControlPreferences()
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
                val desiredPc = index % 2 == 0
                check(preferences.edit().putBoolean(pcKey, desiredPc).commit())
                val before = entered.get()
                runOnMainSync { visible.value = true }
                await("Monitor entry ${index + 1} was not composed") { entered.get() > before }
                SystemClock.sleep(500)
                checkNotNull(uiAutomation.takeScreenshot()).recycle()
                runOnMainSync { visible.value = false }
                await("Monitor exit was not disposed") { exited.get() == index + 1 }
                check(RemoteToolPreferences(preferences).computerControl.value == desiredPc) {
                    "Monitor entry/disconnect/exit erased the saved PC choice"
                }
            }
            result.putString("result", "PASS: PC preference persistence/off/hide, ART verification, and three real monitor entry/render/exit cycles preserving PC choice without a camera")
            outcome = Activity.RESULT_OK
        } catch (error: Throwable) {
            result.putString("failure", error.stackTraceToString())
        } finally {
            activity?.let { runOnMainSync { it.finish() } }
            preferences.edit().apply {
                if (savedPc == null) remove(pcKey) else putBoolean(pcKey, savedPc)
            }.commit()
        }
        finish(outcome, result)
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
