package com.ztransfer.ui.screen

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.ztransfer.MainActivity
import com.ztransfer.presets.PresetFile
import com.ztransfer.protocol.builtInPictureControls
import com.ztransfer.ui.theme.ZTransferTheme
import java.io.File
import java.util.concurrent.atomic.AtomicReference

/** Real category navigation and constrained Compose layout; no camera writes or folder grants. */
class PresetCategoryInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val report = Bundle()
        var activity: MainActivity? = null
        var outcome = Activity.RESULT_CANCELED
        try {
            val builtIns = builtInPictureControls(targetContext.assets)
            check(builtIns.isNotEmpty())
            fun file(name: String, category: String? = null) = PresetFile(
                Uri.parse("content://category-test/${category ?: "root"}/$name"), "$name.np3", 834, 1, category)
            val root = file("Root preset")
            val portrait = file("Portrait preset", "人像")
            val film = file("Film preset", "胶片")
            val original = listOf(root, portrait, film)
            val collisions = pictureControlPresetCategories(builtIns,
                original + file("User built-in", "内置") + file("User root", "未分类"), "内置", "未分类")
            check(collisions.map { it.key }.distinct().size == collisions.size)
            check(collisions.first().options.size == builtIns.size)
            check(collisions.first().options.all { it is PictureControlPresetChoice.BuiltIn })
            check(collisions.single { it.key == "root" }.options.single() == PictureControlPresetChoice.Document(root))
            check(collisions.single { it.key == "folder:内置" }.options.all { it is PictureControlPresetChoice.Document })

            val files = mutableStateOf(original)
            val short = mutableStateOf(false)
            val lut = mutableStateOf(false)
            val selected = mutableStateOf<Uri?>(film.uri)
            val choice = AtomicReference<PictureControlPresetChoice>()
            val monitor = addMonitor(MainActivity::class.java.name, null, false)
            targetContext.startActivity(Intent(targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            activity = checkNotNull(waitForMonitorWithTimeout(monitor, 10_000)) as MainActivity
            removeMonitor(monitor)
            runOnMainSync {
                activity.setContent {
                    ZTransferTheme {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            Surface {
                                Column(Modifier.width(260.dp).height(if (short.value) 200.dp else 420.dp)
                                    .padding(horizontal = 10.dp, vertical = 6.dp)) {
                                    Text("更换 C9", Modifier.padding(8.dp))
                                    PresetFolderButton("更换文件夹", true, Modifier.fillMaxWidth().padding(bottom = 6.dp)) {}
                                    if (lut.value) {
                                        PresetCategoryList(files.value, selected.value,
                                            modifier = Modifier.weight(1f).fillMaxWidth()) { file ->
                                            RemotePresetChoice(file.label, file.uri == selected.value, false, true) {}
                                        }
                                    } else {
                                        val categories = pictureControlPresetCategories(builtIns, files.value, "内置", "未分类")
                                        PresetCategoryBrowser(categories, null, { it.key },
                                            modifier = Modifier.weight(1f).fillMaxWidth()) { item ->
                                            val label = when (item) {
                                                is PictureControlPresetChoice.BuiltIn -> item.preset.name
                                                is PictureControlPresetChoice.Document -> item.file.label
                                            }
                                            RemotePresetChoice(label, false, false, true) { choice.set(item) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            awaitText(builtIns.first().name)
            screenshot("preset-categories-tall.png")
            click(builtIns.first().name)
            check(choice.get() is PictureControlPresetChoice.BuiltIn)
            click("未分类"); awaitText(root.label); click(root.label)
            check(choice.get() == PictureControlPresetChoice.Document(root))
            click("人像"); awaitText(portrait.label)
            runOnMainSync { files.value = original + file("Added preset", "人像") }
            awaitText("Added preset") // Refresh preserves the open category.
            click(portrait.label)
            check(choice.get() == PictureControlPresetChoice.Document(portrait))
            click("内置"); awaitText(builtIns.first().name)
            runOnMainSync { short.value = true }
            SystemClock.sleep(300)
            screenshot("preset-categories-short.png")
            click("人像"); awaitText(portrait.label)
            runOnMainSync { files.value = emptyList() }
            awaitText(builtIns.first().name) // Removed/missing folder falls back to built-ins.
            runOnMainSync { files.value = original; lut.value = true; short.value = false }
            awaitText(film.label) // Shared LUT adapter starts at the selected file's category.
            click("人像"); awaitText(portrait.label)
            runOnMainSync { files.value = original + file("Refreshed LUT", "人像") }
            awaitText("Refreshed LUT")
            runOnMainSync { selected.value = root.uri }
            awaitText(root.label)
            report.putString("result", "PASS: built-ins retained, root/subfolder categories, label collisions, choice source, refresh/removal, 260dp layouts, LUT selection and refresh")
            outcome = Activity.RESULT_OK
        } catch (error: Throwable) {
            report.putString("failure", error.stackTraceToString())
        } finally {
            activity?.let { runOnMainSync { it.finish() } }
        }
        finish(outcome, report)
    }

    private fun find(text: String): AccessibilityNodeInfo? {
        fun visit(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if (node.text?.toString() == text && node.isVisibleToUser) return node
            for (i in 0 until node.childCount) node.getChild(i)?.let { visit(it)?.let { found -> return found } }
            return null
        }
        return uiAutomation.rootInActiveWindow?.let(::visit)
    }
    private fun awaitText(text: String) {
        val deadline = SystemClock.uptimeMillis() + 5000
        while (find(text) == null && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(50)
        check(find(text) != null) { "Missing visible text: $text" }
    }
    private fun click(text: String) {
        awaitText(text)
        var node = checkNotNull(find(text))
        while (!node.isClickable) node = checkNotNull(node.parent)
        check(node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) { "Click failed: $text" }
        SystemClock.sleep(200)
    }
    private fun screenshot(name: String) {
        val image = checkNotNull(uiAutomation.takeScreenshot())
        File(targetContext.cacheDir, name).outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        image.recycle()
    }
}
