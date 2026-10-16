package com.ztransfer.ui.screen

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.ztransfer.R
import com.ztransfer.presets.*
import com.ztransfer.protocol.BuiltInPictureControl
import kotlinx.coroutines.awaitCancellation

/** A choice has exactly one source; the destination slot belongs to the editing screen. */
internal sealed interface PictureControlPresetChoice {
    val key: String
    data class BuiltIn(val preset: BuiltInPictureControl) : PictureControlPresetChoice {
        override val key get() = preset.assetPath
    }
    data class Document(val file: PresetFile) : PictureControlPresetChoice {
        override val key get() = file.uri.toString()
    }
}

/** Same categories and rows as monitor LUT; folder actions belong to the popup header. */
@Composable
internal fun ColumnScope.PictureControlPresetChooser(
    folders: PictureControlFolderState, enabled: Boolean, browsingEnabled: Boolean,
    presets: Result<List<BuiltInPictureControl>>,
    pending: String?, onNotice: (String) -> Unit,
    onChoose: (PictureControlPresetChoice) -> Unit,
) {
    val context = LocalContext.current
    val uncategorized = stringResource(R.string.lut_uncategorized)
    val labels = remember(folders.files, uncategorized) { presetFileLabels(folders.files, uncategorized) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(folders, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            // Also pick up file-manager edits when returning to an already open chooser.
            folders.refresh()
            awaitCancellation()
        }
    }
    val guidance = when {
        folders.scanning -> null
        folders.failure != null -> presetFolderMessage(folders.failure!!)
        folders.hasSnapshot && folders.folder != null && folders.files.isEmpty() -> R.string.picture_control_folder_empty
        presets.isFailure -> R.string.picture_control_files_failed
        else -> null
    }
    LaunchedEffect(guidance) { guidance?.let { onNotice(context.getString(it)) } }
    val accessible = folders.failure != PresetFolderFailure.MISSING && folders.failure != PresetFolderFailure.DENIED
    val builtInLabel = stringResource(R.string.picture_control_built_in)
    val categories = remember(presets, folders.files, accessible, builtInLabel, uncategorized) {
        pictureControlPresetCategories(presets.getOrDefault(emptyList()),
            if (accessible) folders.files else emptyList(), builtInLabel, uncategorized)
    }
    PresetCategoryBrowser(categories, null, { it.key }, browsingEnabled,
        Modifier.weight(1f, fill = false).fillMaxWidth()) { choice ->
        val label = when (choice) {
            is PictureControlPresetChoice.BuiltIn -> choice.preset.name
            is PictureControlPresetChoice.Document -> labels[choice.file.uri] ?: choice.file.label
        }
        RemotePresetChoice(label, false, pending == choice.key,
            enabled && (choice is PictureControlPresetChoice.BuiltIn || !folders.scanning)) { onChoose(choice) }
    }
}

/** Built-ins always lead the same category list; a folder never replaces them. */
internal fun pictureControlPresetCategories(
    builtIns: List<BuiltInPictureControl>, files: List<PresetFile>, builtInLabel: String, uncategorized: String,
): List<PresetCategory<PictureControlPresetChoice>> =
    listOf(PresetCategory<PictureControlPresetChoice>("built-in", builtInLabel,
        builtIns.map { PictureControlPresetChoice.BuiltIn(it) })) +
        presetFileCategories(files, uncategorized).map { category ->
            PresetCategory<PictureControlPresetChoice>(category.key, category.label,
                category.options.map { PictureControlPresetChoice.Document(it) })
        }
