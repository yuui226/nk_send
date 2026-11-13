package com.ztransfer.ui.screen

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Rect
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
import com.ztransfer.filter.LutAdjustments
import com.ztransfer.filter.Np3PhotoFilterParameters
import com.ztransfer.filter.PHOTO_FILTER_COLOR_BAND_CENTERS
import com.ztransfer.filter.ParsedPhotoNp3
import com.ztransfer.filter.PhotoFilterColorBand
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.filter.PhotoNp3EditorState
import com.ztransfer.filter.PhotoNp3Source
import com.ztransfer.filter.PhotoNp3Store
import com.ztransfer.filter.photoFilterCatalogKey
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
            val rememberedIntensities = mutableStateOf<Map<String, Int>>(emptyMap())
            val adjustments = mutableStateOf(LutAdjustments())
            val adjustmentChanges = mutableListOf<Pair<String, LutAdjustments>>()
            val strengthChanges = mutableListOf<Pair<String, Int>>()
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
                                        PhotoFilterEditor(filters.value, emptyList(), rememberedIntensities.value, selected.value,
                                            enabled.value, strength.value, adjustments.value,
                                            onDisabled = { enabled.value = false },
                                            onSelected = { selected.value = it; enabled.value = true },
                                            onIntensityChanged = { id, value ->
                                                strengthChanges += id to value
                                                strength.value = value
                                                photoFilterCatalogKey(id)?.let { key ->
                                                    rememberedIntensities.value = rememberedIntensities.value + (key to value)
                                                }
                                            },
                                            onAdjustmentsChanged = { id, value ->
                                                adjustmentChanges += id to value
                                                adjustments.value = value
                                            },
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
            val settingsAction = host.getString(R.string.photo_filter_settings)
            val intensityLabel = host.getString(R.string.photo_filter_intensity)
            val contrastLabel = host.getString(R.string.photo_lut_contrast)
            val adjustmentLabels = listOf(intensityLabel, contrastLabel,
                host.getString(R.string.photo_lut_saturation),
                host.getString(R.string.photo_lut_highlights),
                host.getString(R.string.photo_lut_shadows))
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

                // Exercise the production disclosure and real wheel actions. No fake renderer or
                // writable application preferences are involved in these UI-only adjustments.
                awaitAdjustmentWheels(adjustmentLabels, visible = false)
                click(settingsAction)
                awaitAdjustmentWheels(adjustmentLabels, visible = true)
                if (!compact) {
                    // Valid restored controls need not land on the UI's usual five-step grid.
                    main { adjustments.value = LutAdjustments(9, -7, 13, -24) }
                    awaitWheelDescription("$contrastLabel, 9")
                    awaitWheelDescription(host.getString(R.string.photo_lut_saturation) + ", -7")
                    awaitWheelDescription(host.getString(R.string.photo_lut_highlights) + ", 13")
                    awaitWheelDescription(host.getString(R.string.photo_lut_shadows) + ", -24")
                    clickWheel(contrastLabel)
                    await { adjustments.value.contrast == 5 }
                    main { adjustments.value = LutAdjustments() }
                    awaitWheelDescription("$contrastLabel, 0")
                }
                val previousAdjustments = main { adjustments.value }
                val previousAdjustmentCount = main { adjustmentChanges.size }
                clickWheel(contrastLabel)
                await { adjustmentChanges.size == previousAdjustmentCount + 1 }
                val expectedAdjustments = previousAdjustments.copy(contrast = previousAdjustments.contrast - 5)
                main {
                    check(adjustments.value == expectedAdjustments)
                    check(adjustmentChanges.last() == (builtIn.id to expectedAdjustments))
                }
                awaitWheelDescription("$contrastLabel, ${expectedAdjustments.contrast}")
                val previousStrength = main { strength.value }
                val previousStrengthCount = main { strengthChanges.size }
                clickWheel(intensityLabel)
                await { strengthChanges.size == previousStrengthCount + 1 }
                val expectedStrength = previousStrength - 2
                main { check(strengthChanges.last() == (builtIn.id to expectedStrength)) }
                awaitWheelDescription("$intensityLabel, $expectedStrength%")
                screenshots += screenshot("photo-np3-editor-$variant-adjustments.png")

                click(settingsAction)
                awaitAdjustmentWheels(adjustmentLabels, visible = false)
                click(settingsAction)
                awaitAdjustmentWheels(adjustmentLabels, visible = true)
                awaitWheelDescription("$contrastLabel, ${expectedAdjustments.contrast}")
                awaitWheelDescription("$intensityLabel, $expectedStrength%")

                // Disable through the actual chooser: its exit transition must remove every
                // finishing wheel, while the owner's recipe remains ready for a later enable.
                openChooser(folderAction)
                click(host.getString(R.string.photo_filter_turn_off))
                await { !enabled.value }
                awaitAdjustmentWheels(adjustmentLabels, visible = false)
                main {
                    check(adjustments.value == expectedAdjustments)
                    check(strength.value == expectedStrength)
                }
                screenshots += screenshot("photo-np3-editor-$variant-disabled.png")
                // Re-enable the same recipe through the chooser. Its remembered strength and
                // finishing controls must survive disabling rather than reset to defaults.
                openChooser(folderAction)
                click(firstBuiltInName)
                await { enabled.value && selected.value == builtIn.id }
                awaitAdjustmentWheels(adjustmentLabels, visible = true)
                awaitWheelDescription("$contrastLabel, ${expectedAdjustments.contrast}")
                awaitWheelDescription("$intensityLabel, $expectedStrength%")
                main { adjustments.value = LutAdjustments(35, -20, 15, -40) }
                awaitWheelDescription("$contrastLabel, 35")
                clickWheel(host.getString(R.string.photo_color_reset))
                await { strength.value == 80 && adjustments.value == LutAdjustments() }
                check(main { selected.value } == builtIn.id)
                awaitWheelDescription("$intensityLabel, 80%")
                awaitWheelDescription("$contrastLabel, 0")
                click(settingsAction)
                awaitAdjustmentWheels(adjustmentLabels, visible = false)
            }
            report.putString("result", "PASS: real long-press chooser, built-ins, root/subfolder selection, duplicate labels, same-source built-in selection; five-wheel disclosure, real adjustment/intensity callbacks, collapse and disable retention/re-enable, icon reset of all five controls; light and dark 280dp viewport")
            report.putString("screenshots", screenshots.joinToString("\n"))
            outcome = Activity.RESULT_OK
        } catch (error: Throwable) {
            report.putString("failure", error.stackTraceToString())
            runCatching { report.putString("failure_screenshot", screenshot("photo-np3-editor-failure.png")) }
            runCatching {
                val dump = accessibilityDump()
                val file = File(targetContext.cacheDir, "photo-np3-editor-failure-tree.txt")
                file.writeText(dump)
                report.putString("failure_accessibility_tree", file.absolutePath)
                report.putString("failure_accessibility_excerpt", dump.take(12_000))
            }
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

    private fun wheel(label: String): AccessibilityNodeInfo? {
        // Compose can expose the descriptive semantics separately from the clickable modifier.
        // Resolve the actual action in that wheel's subtree/ancestors, as click(text) does for
        // ordinary controls, rather than requiring the descriptive node itself to be clickable.
        val described = find { it.contentDescription?.toString()?.let { description -> description == label || description.contains("$label, ") } == true }
            ?: return null
        fun supportsClick(node: AccessibilityNodeInfo): Boolean = node.isVisibleToUser && node.isEnabled &&
            (node.isClickable || node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK })
        fun actionInSubtree(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if (supportsClick(node)) return node
            for (index in 0 until node.childCount) {
                node.getChild(index)?.let { child -> actionInSubtree(child)?.let { return it } }
            }
            return null
        }
        actionInSubtree(described)?.let { return it }
        var ancestor = described.parent
        while (ancestor != null) {
            if (supportsClick(ancestor)) return ancestor
            ancestor = ancestor.parent
        }
        return null
    }

    private fun clickWheel(label: String) {
        val deadline = SystemClock.uptimeMillis() + 5000
        while (wheel(label) == null && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(40)
        val target = checkNotNull(wheel(label)) {
            "No enabled click action associated with wheel: $label\n${accessibilityDump()}"
        }
        check(target.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
            "Wheel ACTION_CLICK failed: $label; ${nodeSummary(target)}\n${accessibilityDump()}"
        }
    }

    private fun nodeSummary(node: AccessibilityNodeInfo): String {
        val bounds = Rect().also(node::getBoundsInScreen)
        return "class=${node.className} text=[${node.text}] description=[${node.contentDescription}] " +
            "visible=${node.isVisibleToUser} enabled=${node.isEnabled} clickable=${node.isClickable} " +
            "bounds=$bounds actions=${node.actionList.map { "${it.id}:${it.label}" }}"
    }

    private fun accessibilityDump(): String {
        if (android.os.Build.VERSION.SDK_INT >= 33) uiAutomation.clearCache()
        val root = uiAutomation.rootInActiveWindow ?: return "No active accessibility window"
        return buildString {
            var count = 0
            fun visit(node: AccessibilityNodeInfo, path: String) {
                if (count++ >= 512) return
                appendLine("$path ${nodeSummary(node)}")
                for (index in 0 until node.childCount) {
                    node.getChild(index)?.let { visit(it, "$path/$index") }
                }
            }
            visit(root, "0")
        }
    }

    private fun awaitAdjustmentWheels(labels: List<String>, visible: Boolean) {
        val deadline = SystemClock.uptimeMillis() + 5000
        fun matches() = labels.all { label ->
            val exists = find { it.contentDescription?.toString()?.startsWith("$label, ") == true } != null
            exists == visible
        }
        while (!matches() && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(40)
        check(matches()) { "Adjustment wheels did not become ${if (visible) "visible" else "hidden"}: $labels" }
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
