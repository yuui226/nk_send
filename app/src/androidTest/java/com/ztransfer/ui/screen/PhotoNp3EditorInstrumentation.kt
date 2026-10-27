package com.ztransfer.ui.screen

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.ztransfer.MainActivity
import com.ztransfer.R
import com.ztransfer.filter.BuiltInPhotoFilters
import com.ztransfer.filter.Np3PhotoFilterParameters
import com.ztransfer.filter.PHOTO_FILTER_COLOR_BAND_CENTERS
import com.ztransfer.filter.ParsedPhotoNp3
import com.ztransfer.filter.PhotoFilterColorBand
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.filter.PhotoNp3EditorState
import com.ztransfer.filter.PhotoNp3Source
import com.ztransfer.filter.PhotoNp3Store
import com.ztransfer.presets.PresetFile
import com.ztransfer.presets.PresetFolderSnapshot
import com.ztransfer.presets.presetFileLabels
import com.ztransfer.ui.theme.ThemeMode
import com.ztransfer.ui.theme.ZTransferTheme
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

/** The real editor/dialog with deterministic provider data, isolated from the user's NP3 store. */
class PhotoNp3EditorInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val report = Bundle()
        val preferences = targetContext.getSharedPreferences("photo_np3_editor_ui_test", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        var activity: MainActivity? = null
        var editor: PhotoNp3EditorState? = null
        var outcome = Activity.RESULT_CANCELED
        try {
            val root = PresetFile(Uri.parse("content://np3-ui-test/root/a"), "NP3 smoke.np3", 392, 1)
            val portrait = PresetFile(Uri.parse("content://np3-ui-test/portraits/b"), "NP3 smoke.np3", 392, 1,
                "Smoke portraits")
            val builtInCopy = PresetFile(Uri.parse("content://np3-ui-test/root/copy"), "Copied built-in.np3", 392, 1)
            val builtIn = BuiltInPhotoFilters.all.first()
            val source = FakeSource(listOf(root, portrait, builtInCopy), builtInCopy.uri, builtIn)
            val store = PhotoNp3Store(preferences)
            store.folders.replaceFolder(Uri.parse("content://np3-ui-test/tree/fixtures"), false)
            val selected = mutableStateOf(builtIn.id)
            val filters = mutableStateOf(BuiltInPhotoFilters.all)
            val enabled = mutableStateOf(true)
            val strength = mutableStateOf(60)
            val dark = mutableStateOf(false)
            val narrow = mutableStateOf(false)
            val state = main {
                PhotoNp3EditorState(store, source, "local", builtIn, scope,
                    onSelected = { preset, _ ->
                        if (filters.value.none { it.id == preset.id }) filters.value += preset
                        selected.value = preset.id
                        enabled.value = true
                    },
                    onUnavailable = { enabled.value = false },
                    notice = { error("Unexpected NP3 notice: $it") },
                ).also { editor = it; it.refresh() }
            }
            await { !state.loading && state.files.size == 3 }

            val monitor = addMonitor(MainActivity::class.java.name, null, false)
            targetContext.startActivity(Intent(targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            val host = checkNotNull(waitForMonitorWithTimeout(monitor, 10_000)) as MainActivity
            activity = host
            removeMonitor(monitor)
            runOnMainSync {
                host.setContent {
                    val density = LocalDensity.current
                    val configuration = LocalConfiguration.current
                    // Constrain the actual dialog's dp viewport too, without changing emulator settings.
                    val testDensity = if (narrow.value) {
                        Density(host.resources.displayMetrics.widthPixels / 280f, density.fontScale)
                    } else density
                    val testConfiguration = Configuration(configuration).apply {
                        if (narrow.value) {
                            screenWidthDp = 280
                            screenHeightDp = (host.resources.displayMetrics.heightPixels / testDensity.density).toInt()
                        }
                    }
                    CompositionLocalProvider(LocalDensity provides testDensity,
                        LocalConfiguration provides testConfiguration) {
                        ZTransferTheme(themeMode = if (dark.value) ThemeMode.DARK else ThemeMode.LIGHT) {
                            Surface(Modifier.fillMaxSize()) {
                                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                                    Box(Modifier.width(if (narrow.value) 260.dp else 360.dp)) {
                                        PhotoFilterEditor(filters.value, emptyList(), emptyMap(), selected.value,
                                            enabled.value, strength.value,
                                            onDisabled = { enabled.value = false },
                                            onSelected = { selected.value = it; enabled.value = true },
                                            onIntensityChanged = { _, value -> strength.value = value },
                                            onFavoriteToggled = {}, hapticsEnabled = false, np3 = state)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // The app can override its Activity locale independently of targetContext.
            val all = host.getString(R.string.photo_filter_category_all)
            val rootCategory = host.getString(R.string.lut_uncategorized)
            val folderAction = host.getString(R.string.photo_filter_folder)
            val labels = presetFileLabels(source.files, rootCategory)
            val firstBuiltInName = BuiltInPhotoFilters.nameResId(builtIn.id)?.let(host::getString)
                ?: builtIn.name
            val screenshots = mutableListOf<String>()
            for (compact in listOf(false, true)) {
                main {
                    dark.value = compact
                    narrow.value = compact
                    selected.value = builtIn.id
                    state.resetSelection(builtIn)
                }
                await { !state.loading }
                val variant = if (compact) "dark-narrow" else "light"
                openChooser(folderAction)
                awaitText(all)
                awaitText(firstBuiltInName)
                screenshots += screenshot("photo-np3-editor-$variant-builtins.png")
                click(firstBuiltInName)
                await { selected.value == builtIn.id && state.selectedUri == null }

                openChooser(folderAction)
                clickCategory(rootCategory, all)
                awaitText(labels.getValue(root.uri))
                screenshots += screenshot("photo-np3-editor-$variant-root.png")
                click(labels.getValue(root.uri))
                await { !state.loading && state.selectedUri == root.uri && selected.value == source.recipe(root).preset.id }

                openChooser(folderAction)
                clickCategory(checkNotNull(portrait.category), all)
                awaitText(labels.getValue(portrait.uri))
                screenshots += screenshot("photo-np3-editor-$variant-folder.png")
                click(labels.getValue(portrait.uri))
                await { !state.loading && state.selectedUri == portrait.uri && selected.value == source.recipe(portrait).preset.id }

                // An exact built-in source intentionally shares its render ID. The UI must still
                // distinguish the selected external file from an explicitly chosen built-in row.
                openChooser(folderAction)
                clickCategory(rootCategory, all)
                click(labels.getValue(builtInCopy.uri))
                await { !state.loading && state.selectedUri == builtInCopy.uri && selected.value == builtIn.id }
                awaitWheelDescription(host.getString(R.string.photo_filter) + ", " + labels.getValue(builtInCopy.uri))
                openChooser(folderAction)
                clickScrolled(firstBuiltInName, labels.getValue(builtInCopy.uri), AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
                await { selected.value == builtIn.id && state.selectedUri == null }
                awaitWheelDescription(host.getString(R.string.photo_filter) + ", " + firstBuiltInName)
            }
            report.putString("result", "PASS: real long-press chooser, built-ins, root/subfolder selection, duplicate labels, same-source built-in selection, light and dark 280dp viewport")
            report.putString("screenshots", screenshots.joinToString("\n"))
            outcome = Activity.RESULT_OK
        } catch (error: Throwable) {
            report.putString("failure", error.stackTraceToString())
            runCatching { report.putString("failure_screenshot", screenshot("photo-np3-editor-failure.png")) }
        } finally {
            main { editor?.close(); scope.cancel(); activity?.finish() }
            preferences.edit().clear().commit()
        }
        finish(outcome, report)
    }

    private fun find(predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        if (android.os.Build.VERSION.SDK_INT >= 33) uiAutomation.clearCache()
        fun visit(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if (node.isVisibleToUser && predicate(node)) return node
            for (i in 0 until node.childCount) node.getChild(i)?.let { child ->
                visit(child)?.let { return it }
            }
            return null
        }
        return uiAutomation.rootInActiveWindow?.let(::visit)
    }

    private fun findText(text: String) = find { it.text?.toString() == text }

    private fun awaitText(text: String) {
        val deadline = SystemClock.uptimeMillis() + 5000
        while (findText(text) == null && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(40)
        check(findText(text) != null) { "Missing visible text: $text" }
    }

    private fun openChooser(folderLabel: String) {
        val deadline = SystemClock.uptimeMillis() + 5000
        var wheel: AccessibilityNodeInfo? = null
        while (wheel == null && SystemClock.uptimeMillis() < deadline) {
            // This isolated editor has exactly one long-click target: its filter wheel.
            wheel = find { it.isLongClickable }
            if (wheel == null) SystemClock.sleep(40)
        }
        check(checkNotNull(wheel) { "Filter wheel is not long-clickable" }
            .performAction(AccessibilityNodeInfo.ACTION_LONG_CLICK)) { "Filter wheel long press failed" }
        awaitText(folderLabel)
    }

    private fun clickCategory(text: String, anchor: String) =
        clickScrolled(text, anchor, AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)

    private fun clickScrolled(text: String, anchor: String, action: Int) {
        if (findText(text) != null) { click(text); return }
        awaitText(anchor)
        var column = checkNotNull(findText(anchor))
        while (!column.isScrollable) column = checkNotNull(column.parent) { "Missing category scroll container" }
        repeat(10) {
            if (findText(text) != null) { click(text); return }
            column.performAction(action)
            // Accessibility publishes the post-scroll tree after Compose's animation.
            // A false action at the bottom must not fail before that tree has arrived.
            SystemClock.sleep(600)
            column.refresh()
        }
        error("Missing category: $text")
    }

    private fun awaitWheelDescription(expected: String) {
        val deadline = SystemClock.uptimeMillis() + 5000
        fun matchingWheel() = find { it.contentDescription?.toString()?.contains(expected) == true }
        while (matchingWheel() == null && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(40)
        check(matchingWheel() != null) {
            val visibleLabels = buildString {
                this@PhotoNp3EditorInstrumentation.find { node ->
                    val text = node.text?.toString().orEmpty()
                    val description = node.contentDescription?.toString().orEmpty()
                    if (text.isNotEmpty() || description.isNotEmpty()) {
                        appendLine("text=[$text] contentDescription=[$description]")
                    }
                    false
                }
            }
            "Unexpected selected filter source; expected wheel to contain: $expected\nVisible labels:\n$visibleLabels"
        }
    }

    private fun click(text: String) {
        awaitText(text)
        var node = checkNotNull(findText(text))
        while (!node.isClickable) node = checkNotNull(node.parent)
        check(node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) { "Click failed: $text" }
        SystemClock.sleep(150)
    }

    private fun <T> main(block: () -> T): T {
        var result: Result<T>? = null
        runOnMainSync { result = runCatching(block) }
        return checkNotNull(result).getOrThrow()
    }

    private fun await(condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 5000
        while (!main(condition)) {
            check(SystemClock.uptimeMillis() < deadline) { "NP3 editor did not settle" }
            SystemClock.sleep(20)
        }
    }

    private fun screenshot(name: String): String {
        val bitmap = checkNotNull(uiAutomation.takeScreenshot())
        val file = File(targetContext.cacheDir, name)
        file.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
        return file.absolutePath
    }

    private class FakeSource(
        val files: List<PresetFile>,
        private val builtInSource: Uri,
        private val builtIn: PhotoFilterPreset,
    ) : PhotoNp3Source {
        override suspend fun scan(uri: Uri, replacing: Boolean, signal: CancellationSignal): PresetFolderSnapshot {
            signal.throwIfCanceled()
            return PresetFolderSnapshot(files, false)
        }
        override suspend fun read(file: PresetFile, signal: CancellationSignal): ParsedPhotoNp3 {
            signal.throwIfCanceled()
            return recipe(file)
        }
        override fun releaseGrant(uri: Uri) = Unit
        fun recipe(file: PresetFile): ParsedPhotoNp3 {
            if (file.uri == builtInSource) {
                return ParsedPhotoNp3(checkNotNull(BuiltInPhotoFilters.catalogKey(builtIn.id)), builtIn, false)
            }
            val hash = (if (file.category == null) "a" else "b").repeat(64)
            return ParsedPhotoNp3(hash, PhotoFilterPreset("np3:$hash:np3-srgb-v1", file.label,
                Np3PhotoFilterParameters(0, 0, 0, 0, 0, 0,
                    PHOTO_FILTER_COLOR_BAND_CENTERS.map { PhotoFilterColorBand(it, 0, 0, 0) })), false)
        }
    }
}
