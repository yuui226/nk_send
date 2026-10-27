package com.ztransfer.ui.screen

import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.LineBreak
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.ztransfer.R
import com.ztransfer.effects.FavoritePhotoFilter
import com.ztransfer.filter.BuiltInPhotoFilters
import com.ztransfer.filter.DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT
import com.ztransfer.filter.PhotoFilterCategory
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.filter.PhotoNp3EditorState
import com.ztransfer.filter.category
import com.ztransfer.filter.normalizePhotoFilterIntensity
import com.ztransfer.filter.photoFilterCatalogKey
import com.ztransfer.presets.PresetFile
import com.ztransfer.presets.PresetFolderFailure
import com.ztransfer.presets.presetFileLabels
import com.ztransfer.presets.presetFolderMessage
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.util.rememberHaptics
import kotlinx.coroutines.awaitCancellation

@Composable
internal fun rememberPhotoNp3Draft(
    role: String,
    initialPreset: PhotoFilterPreset?,
    onSelected: (PhotoFilterPreset, Boolean) -> Unit,
    onUnavailable: () -> Unit,
    selectionAllowed: () -> Boolean = { true },
): PhotoNp3EditorState {
    val localizedContext by rememberUpdatedState(LocalContext.current)
    val context = localizedContext.applicationContext
    val scope = rememberCoroutineScope()
    val selected by rememberUpdatedState(onSelected)
    val unavailable by rememberUpdatedState(onUnavailable)
    val allowed by rememberUpdatedState(selectionAllowed)
    val state = remember(context, role) {
        PhotoNp3EditorState(context, role, initialPreset, scope,
            onSelected = { preset, explicit -> selected(preset, explicit) },
            onUnavailable = { unavailable() },
            selectionAllowed = { allowed() },
            notice = { Toast.makeText(context, localizedContext.getString(it), Toast.LENGTH_SHORT).show() })
    }
    DisposableEffect(state) { onDispose { state.close() } }
    return state
}

/** A source row remains URI-addressed so selecting it always checks the file's current contents. */
private sealed interface PhotoFilterEditorChoice {
    val key: String
    val presetId: String?
    val catalogKey: String?
    data class Preset(val preset: PhotoFilterPreset) : PhotoFilterEditorChoice {
        override val key = "preset:${preset.id}"
        override val presetId get() = preset.id
        override val catalogKey = photoFilterCatalogKey(preset.id)
    }
    data class Document(val file: PresetFile, override val presetId: String?) : PhotoFilterEditorChoice {
        override val key = "document:${file.uri}"
        override val catalogKey = presetId?.let(::photoFilterCatalogKey)
    }
}

private fun orderPhotoFilterChoices(
    choices: List<PhotoFilterEditorChoice>,
    favoriteRanks: Map<String, Int>,
): List<PhotoFilterEditorChoice> = if (favoriteRanks.isEmpty()) choices else
    choices.sortedBy { favoriteRanks[it.catalogKey] ?: Int.MAX_VALUE }

@Composable
internal fun PhotoFilterEditor(
    filters: List<PhotoFilterPreset>,
    favoriteFilters: List<FavoritePhotoFilter>,
    rememberedIntensities: Map<String, Int>,
    selectedId: String?,
    enabled: Boolean,
    intensityPercent: Int,
    onDisabled: () -> Unit,
    onSelected: (String) -> Unit,
    onIntensityChanged: (String, Int) -> Unit,
    onFavoriteToggled: (String) -> Unit,
    hapticsEnabled: Boolean,
    np3: PhotoNp3EditorState,
    active: Boolean = true,
) {
    val context = LocalContext.current
    val configuration = LocalConfiguration.current
    val localeKey = configuration.locales.toLanguageTags()
    val colors = AppTheme.colors
    val filterAccent = colors.accentBlue
    val favoritePalette = rememberPhotoEffectFavoriteButtonPalette()
    val haptics = rememberHaptics(hapticsEnabled)
    var showChooser by remember { mutableStateOf(false) }
    var showFolderHint by remember { mutableStateOf(false) }
    var skipPickerResume by remember { mutableStateOf(false) }
    val currentActive by rememberUpdatedState(active)
    val folderPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        // Cancellation does not start a scan or change the existing folder/selection.
        if (uri != null && currentActive) np3.folderPicked(uri)
    }
    val launchFolderPicker: () -> Unit = {
        np3.cancelPending()
        showFolderHint = false
        showChooser = false
        skipPickerResume = true
        try { folderPicker.launch(np3.folder) }
        catch (_: Exception) {
            skipPickerResume = false
            Toast.makeText(context, context.getString(R.string.lut_folder_denied), Toast.LENGTH_SHORT).show()
        }
    }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(np3, lifecycle, active) {
        if (!active) {
            np3.cancelPending()
            showChooser = false
            showFolderHint = false
            return@LaunchedEffect
        }
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            if (skipPickerResume) skipPickerResume = false else np3.refresh()
            awaitCancellation()
        }
    }
    DisposableEffect(np3) { onDispose { np3.cancelPending() } }

    val draftPreset = np3.selectedPreset
    val draftUri = np3.selectedUri
    val selected = remember(filters, selectedId, draftPreset) {
        filters.firstOrNull { it.id == selectedId } ?: draftPreset?.takeIf { it.id == selectedId }
    }
    val favorites = remember(favoriteFilters) { favoriteFilters.map { it.catalogKey } }
    val favoriteSet = remember(favorites) { favorites.toSet() }
    val favoriteRanks = remember(favorites) { favorites.withIndex().associate { it.value to it.index } }
    val uncategorized = stringResource(R.string.lut_uncategorized)
    val accessible = np3.failure != PresetFolderFailure.MISSING && np3.failure != PresetFolderFailure.DENIED
    val files = if (accessible) np3.files else emptyList()
    val fileLabels = remember(files, uncategorized) { presetFileLabels(files, uncategorized) }
    val builtIns = remember { BuiltInPhotoFilters.all.map { PhotoFilterEditorChoice.Preset(it) } }
    // External files do not enter a composable stringResource loop. Only the fixed built-in
    // catalogue needs localized resource names, and it changes only with the resource locale.
    val builtInLabels = remember(context, localeKey, builtIns) {
        builtIns.associate { choice -> choice.key to
            (BuiltInPhotoFilters.nameResId(choice.preset.id)?.let(context::getString) ?: choice.preset.name) }
    }
    // knownPresetId reads the state's observable hint map. Reading it inside derivedStateOf
    // invalidates rows after a scan/read updates identity, without remapping 10,000 files on a
    // strength detent or a preview recomposition. The saved source supplies its initial hint.
    val documents by remember(np3, files) {
        derivedStateOf {
            val sourceUri = np3.selectedUri
            val sourceId = np3.selectedPreset?.id
            files.map { file -> PhotoFilterEditorChoice.Document(file,
                np3.knownPresetId(file.uri) ?: sourceId?.takeIf { sourceUri == file.uri }) }
        }
    }
    val documentsByUri = remember(documents) { documents.associateBy { it.file.uri } }
    val currentDocument = remember(documentsByUri, draftUri, draftPreset?.id, selectedId) {
        documentsByUri[draftUri]?.takeIf { draftPreset?.id == selectedId }
    }
    // VM may retain previously used presets for queued exports. They are not directory entries.
    val offlineSnapshot = remember(selected, currentDocument) {
        selected?.takeIf { preset ->
            BuiltInPhotoFilters.catalogKey(preset.id) == null && currentDocument == null
        }?.let { PhotoFilterEditorChoice.Preset(it) }
    }
    val choices = remember(builtIns, documents, offlineSnapshot, favoriteRanks) {
        orderPhotoFilterChoices(builtIns + documents + listOfNotNull(offlineSnapshot), favoriteRanks)
    }
    val byKey = remember(choices) { choices.associateBy { it.key } }
    // Labels depend on directory metadata/locale, not favorite order, strength, or loading state.
    val labels = remember(builtInLabels, fileLabels, offlineSnapshot) {
        buildMap {
            putAll(builtInLabels)
            fileLabels.forEach { (uri, label) -> put("document:$uri", label) }
            offlineSnapshot?.let { put(it.key, it.preset.name) }
        }
    }
    val pendingKey = documentsByUri[np3.pendingUri]?.key
    val currentKey = remember(currentDocument, byKey, selectedId, enabled) {
        // Pixel identity can be shared by a built-in and several files. Highlight the source
        // actually chosen, never whichever same-content document happens to sort first.
        (currentDocument?.key ?: "preset:$selectedId".takeIf { it in byKey }).takeIf { enabled }
    }
    val options: List<String?> = remember(choices) { listOf(null) + choices.map { it.key } }
    val fileCategories by remember(files, uncategorized) {
        derivedStateOf { presetFileCategories(files, uncategorized) }
    }
    val offLabel = stringResource(R.string.photo_filter_off_option)
    fun rememberedIntensity(id: String): Int = photoFilterCatalogKey(id)?.let(rememberedIntensities::get)
        ?: DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT
    fun disable() { np3.cancelPending(); onDisabled() }
    fun choose(choice: PhotoFilterEditorChoice) {
        if (!active) return
        when (choice) {
            is PhotoFilterEditorChoice.Document -> np3.choose(choice.file)
            is PhotoFilterEditorChoice.Preset -> {
                if (BuiltInPhotoFilters.catalogKey(choice.preset.id) != null) np3.off()
                np3.resetSelection(choice.preset)
                onSelected(choice.preset.id)
                onIntensityChanged(choice.preset.id, rememberedIntensity(choice.preset.id))
            }
        }
    }
    val loadingAlpha = if (np3.loadingSelection) {
        val transition = rememberInfiniteTransition(label = "photoNp3Loading")
        transition.animateFloat(.04f, .14f, infiniteRepeatable(tween(600), RepeatMode.Reverse), label = "photoNp3LoadingAlpha")
    } else null
    val controlsEnabled = active && enabled && selected != null && !np3.loading
    SettingsCard(borderColor = filterAccent.copy(alpha = .24f), tintColor = filterAccent) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ReleaseCommitWheel(
                options = options,
                selected = pendingKey ?: currentKey,
                optionLabel = { key -> if (key == null) offLabel else labels[key].orEmpty() },
                favoriteOption = { key -> byKey[key]?.catalogKey in favoriteSet },
                favoriteIconColor = favoritePalette.activeIcon,
                onValueCommitted = { key -> if (key == null) disable() else byKey[key]?.let(::choose) },
                onDetent = haptics::tick,
                label = stringResource(R.string.photo_filter),
                wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                accentColor = filterAccent,
                modifier = Modifier.weight(PHOTO_COLOR_NAME_WEIGHT),
                optionRowHeight = 30.dp, optionMaxLines = 2,
                optionTextStyle = MaterialTheme.typography.labelMedium.copy(lineBreak = LineBreak.Heading),
                optionFontSizeFor = { if ((labels[it] ?: offLabel).length > 24) 11.sp else 13.sp },
                onLongClick = { showFolderHint = false; showChooser = true; np3.refresh() },
                readOnly = !active || np3.loading,
                ambientEffectColor = filterAccent, ambientEffectAlpha = loadingAlpha,
            )
            ReleaseCommitWheel(
                options = remember { (100 downTo 2 step 2).toList() },
                selected = normalizePhotoFilterIntensity(intensityPercent),
                optionLabel = { "$it%" },
                onValueCommitted = { intensity -> if (controlsEnabled) selected?.let { onIntensityChanged(it.id, intensity) } },
                onDetent = haptics::tick,
                label = stringResource(R.string.photo_filter_intensity), enabled = controlsEnabled,
                wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT, accentColor = filterAccent,
                modifier = Modifier.weight(PHOTO_COLOR_INTENSITY_WEIGHT),
            )
            FavoriteToggleButton(
                favorite = enabled && selected?.id?.let(::photoFilterCatalogKey) in favoriteSet,
                enabled = controlsEnabled,
                onClick = { selected?.let { haptics.tick(); onFavoriteToggled(it.id) } },
            )
        }
    }

    if (showChooser) {
        val categoryLabels = remember(context, localeKey) {
            PhotoFilterCategory.entries.associateWith { context.getString(it.labelResource()) }
        }
        val categories = remember(choices, builtIns, documentsByUri, fileCategories,
            favoriteRanks, favoriteSet, categoryLabels) {
            PhotoFilterCategory.entries.map { category ->
                val members = when (category) {
                    PhotoFilterCategory.ALL -> choices
                    PhotoFilterCategory.FAVORITES -> choices.filter { it.catalogKey in favoriteSet }
                    else -> orderPhotoFilterChoices(builtIns.filter { it.preset.category() == category }, favoriteRanks)
                }
                PresetCategory("builtin:${category.name}", categoryLabels.getValue(category), members)
            } + fileCategories.map { category ->
                // Resolve each file once across all groups instead of filtering the complete
                // document list once per category (quadratic for many one-file subfolders).
                PresetCategory("directory:${category.key}", category.label,
                    orderPhotoFilterChoices(category.options.mapNotNull { documentsByUri[it.uri] }, favoriteRanks))
            }
        }
        val maxHeight = (configuration.screenHeightDp - 120).coerceIn(120, 440).dp
        Dialog(onDismissRequest = { showChooser = false; showFolderHint = false },
            properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Surface(
                modifier = Modifier.padding(horizontal = 24.dp).width(320.dp),
                shape = RoundedCornerShape(18.dp),
                color = colors.glassSurface.copy(alpha = .92f),
                border = BorderStroke(1.dp, colors.glassPanelBorder), shadowElevation = 6.dp,
            ) {
                Column(Modifier.padding(10.dp).heightIn(max = maxHeight)) {
                    if (showFolderHint) {
                        Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState())) {
                            Text(stringResource(R.string.photo_filter_folder_hint),
                                style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant,
                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 10.dp))
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                PresetFolderButton(stringResource(R.string.cancel), true, Modifier.weight(1f)) {
                                    haptics.tick(); showFolderHint = false
                                }
                                PresetFolderButton(stringResource(R.string.photo_filter_folder), true, Modifier.weight(1f)) {
                                    haptics.tick(); launchFolderPicker()
                                }
                            }
                        }
                    } else {
                        LutChooserHeader(off = !enabled, folderLabel = stringResource(R.string.photo_filter_folder),
                            offLabel = stringResource(R.string.photo_filter_turn_off),
                            onOff = { haptics.tick(); disable(); showChooser = false },
                            onFolder = {
                                haptics.tick()
                                if (np3.folder == null) { np3.cancelPending(); showFolderHint = true }
                                else launchFolderPicker()
                            })
                        val guidance = when {
                            np3.loading -> R.string.lut_reading_folder
                            np3.failure != null -> presetFolderMessage(np3.failure!!)
                            np3.folder != null && files.isEmpty() -> R.string.photo_filter_folder_empty
                            else -> null
                        }
                        guidance?.let { Text(stringResource(it), style = MaterialTheme.typography.labelSmall,
                            color = colors.onSurfaceVariant, modifier = Modifier.padding(horizontal = 4.dp, vertical = 5.dp)) }
                        PresetCategoryBrowser(categories, pendingKey ?: currentKey, { it.key },
                            modifier = Modifier.weight(1f, fill = false).fillMaxWidth()) { choice ->
                            val isSelected = choice.key == currentKey
                            val isFavorite = choice.catalogKey in favoriteSet
                            Surface(onClick = { haptics.tick(); choose(choice); showChooser = false },
                                enabled = choice is PhotoFilterEditorChoice.Preset || !np3.loading,
                                shape = RoundedCornerShape(8.dp),
                                color = if (isSelected) filterAccent.copy(alpha = .18f) else Color.Transparent,
                                modifier = Modifier.fillMaxWidth()) {
                                Text(labels[choice.key].orEmpty(), maxLines = 2, overflow = TextOverflow.Ellipsis,
                                    color = when {
                                        isFavorite -> colors.accentYellow
                                        isSelected -> filterAccent
                                        else -> colors.onBackground
                                    }, style = MaterialTheme.typography.labelLarge,
                                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp))
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun PhotoFilterCategory.labelResource(): Int = when (this) {
    PhotoFilterCategory.ALL -> R.string.photo_filter_category_all
    PhotoFilterCategory.FAVORITES -> R.string.photo_filter_category_favorites
    PhotoFilterCategory.LANDSCAPE -> R.string.photo_filter_category_landscape
    PhotoFilterCategory.PORTRAIT -> R.string.photo_filter_category_portrait
    PhotoFilterCategory.MONOCHROME -> R.string.photo_filter_category_monochrome
    PhotoFilterCategory.FILM -> R.string.photo_filter_category_film
    PhotoFilterCategory.CINEMATIC -> R.string.photo_filter_category_cinematic
    PhotoFilterCategory.COLOR -> R.string.photo_filter_category_color
}
