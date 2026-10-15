package com.ztransfer.ui.screen

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.presets.*
import com.ztransfer.protocol.BuiltInPictureControl
import com.ztransfer.protocol.builtInPictureControls
import com.ztransfer.ui.theme.AppTheme

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

/** Same folder header, categories and rows as monitor LUT; no camera operations here. */
@Composable
internal fun ColumnScope.PictureControlPresetChooser(
    folders: PictureControlFolderState, enabled: Boolean, browsingEnabled: Boolean,
    pending: String?, onFolder: () -> Unit, onFeedback: () -> Unit,
    onChoose: (PictureControlPresetChoice) -> Unit,
) {
    val context = LocalContext.current
    val colors = AppTheme.colors
    val presets = remember { runCatching { builtInPictureControls(context.assets) } }
    val uncategorized = stringResource(R.string.lut_uncategorized)
    val labels = remember(folders.files, uncategorized) { presetFileLabels(folders.files, uncategorized) }
    LaunchedEffect(folders) { folders.refresh() }
    LutChooserHeader(!folders.useFolder,
        stringResource(if (folders.folder == null) R.string.lut_choose_folder else R.string.lut_change_folder),
        enabled = browsingEnabled,
        onOff = { onFeedback(); folders.showBuiltIns() },
        onFolder = { onFeedback(); onFolder() },
        offLabel = stringResource(R.string.picture_control_built_in))
    if (folders.useFolder) {
        val guidance = when {
            folders.failure != null -> presetFolderMessage(folders.failure!!)
            folders.scanning && folders.files.isEmpty() -> R.string.lut_reading_folder
            folders.files.isEmpty() -> R.string.picture_control_folder_empty
            else -> null
        }
        if (guidance != null) Text(stringResource(guidance), color = colors.onSurfaceVariant,
            style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(12.dp))
        if (folders.failure != PresetFolderFailure.MISSING && folders.failure != PresetFolderFailure.DENIED &&
            folders.files.isNotEmpty()) {
            PresetCategoryList(folders.files, null, browsingEnabled,
                Modifier.weight(1f, fill = false).fillMaxWidth()) { file ->
                val choice = PictureControlPresetChoice.Document(file)
                RemotePresetChoice(labels[file.uri] ?: file.label, false, pending == choice.key,
                    enabled && !folders.scanning) { onChoose(choice) }
            }
        }
    } else {
        LazyColumn(Modifier.weight(1f, fill = false).fillMaxWidth()) {
            items(presets.getOrDefault(emptyList()), key = { it.assetPath }) { preset ->
                val choice = PictureControlPresetChoice.BuiltIn(preset)
                RemotePresetChoice(preset.name, false, pending == choice.key, enabled) { onChoose(choice) }
            }
        }
        if (presets.isFailure) Text(stringResource(R.string.picture_control_files_failed),
            color = colors.onSurfaceVariant, modifier = Modifier.padding(12.dp))
    }
}
