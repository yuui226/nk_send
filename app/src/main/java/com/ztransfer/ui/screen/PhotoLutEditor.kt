package com.ztransfer.ui.screen

import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.animation.core.*
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.runtime.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.text.style.LineBreak
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ztransfer.R
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.lut.*
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.util.rememberHaptics

@Composable
internal fun rememberPhotoLutDraft(role: String, initial: PhotoFilterSelection?, onSelected: () -> Unit): PhotoLutEditorState {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val selected by rememberUpdatedState(onSelected)
    val store = remember { PhotoLutStore(context) }
    val state = remember {
        PhotoLutEditorState(store, LutFolderRepository(context.applicationContext.contentResolver) { uri ->
            val monitorFolders = LutPreferences(context.getSharedPreferences("monitor_lut", android.content.Context.MODE_PRIVATE))
            (monitorFolders.folder == uri).also { shared -> if (shared) monitorFolders.markFolderGrantOwned() }
        }, scope,
            initial, store.uri(role), { selected() }, { Toast.makeText(context, context.getString(it), Toast.LENGTH_SHORT).show() })
    }
    DisposableEffect(state) { onDispose { state.close() } }
    return state
}

@Composable
internal fun PhotoLutEditor(state: PhotoLutEditorState, hapticsEnabled: Boolean) {
    val context = LocalContext.current
    var showChooser by remember { mutableStateOf(false) }
    var lutSettingsExpanded by remember { mutableStateOf(false) }
    val colors = AppTheme.colors
    val lutAccent = lerp(colors.statusConnected, colors.accentBlue, .35f)
    val haptics = rememberHaptics(hapticsEnabled)
    val folderPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null) state.folderPicked(uri) else state.refresh()
    }
    val openFolder: () -> Unit = {
        haptics.tick()
        state.cancelPending()
        try { folderPicker.launch(state.folder) }
        catch (_: Exception) { Toast.makeText(context, context.getString(R.string.lut_folder_denied), Toast.LENGTH_SHORT).show() }
    }
    LaunchedEffect(state) { state.refresh() }
    DisposableEffect(state) { onDispose { state.cancelPending() } }
    val loadingAlpha = if (state.loadingSelection) {
        val transition = rememberInfiniteTransition(label = "photoLutLoading")
        transition.animateFloat(.04f, .14f, infiniteRepeatable(tween(600), RepeatMode.Reverse), label = "photoLutLoadingAlpha")
    } else null
    val off = stringResource(R.string.lut_off)
    val emptyLabel = when {
        state.folder == null -> stringResource(R.string.photo_lut_set_folder)
        state.failure != null -> stringResource(folderMessage(state.failure!!))
        state.loading && state.files.isEmpty() -> stringResource(R.string.lut_reading_folder)
        else -> stringResource(R.string.lut_folder_empty)
    }
    val ordered = remember(state.files, state.favorites) {
        state.files.sortedBy { if (it.uri.toString() in state.favorites) 0 else 1 }
    }
    val current = state.selectedUri.takeIf { state.selection != null }
    // A restored private snapshot remains usable when a provider cannot be enumerated.
    // Keep its name and the Off option visible until a successful scan resolves membership.
    val uncategorized = stringResource(R.string.lut_uncategorized)
    val names = remember(state.files, current, state.selection?.preset?.name, uncategorized) {
        lutFileLabels(state.files, uncategorized).toMutableMap().apply {
            if (current != null) putIfAbsent(current, state.selection!!.preset.name)
        }
    }
    val options: List<Uri?> = remember(ordered, current) {
        listOf(null) + ordered.map { it.uri } + listOfNotNull(current).filter { uri -> ordered.none { it.uri == uri } }
    }
    val empty = options.size == 1
    val active = state.selection != null && !state.loading
    val lutSettingsLabel = stringResource(R.string.photo_lut_settings)
    SettingsCard(tintColor = lutAccent, borderColor = lutAccent.copy(alpha = .24f)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ReleaseCommitWheel(options, (state.pendingUri ?: current).takeIf { it in options },
                optionLabel = { if (it == null) { if (empty) emptyLabel else off } else names[it].orEmpty() },
                onValueCommitted = state::choose,
                label = "LUT", modifier = Modifier.weight(PHOTO_COLOR_NAME_WEIGHT), wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                optionRowHeight = 30.dp, optionMaxLines = 2,
                optionTextStyle = MaterialTheme.typography.labelMedium.copy(lineBreak = LineBreak.Heading),
                optionFontSizeFor = { if ((names[it] ?: emptyLabel).length > 24) 11.sp else 13.sp },
                onDetent = haptics::tick, onActivated = if (empty) openFolder else null,
                onLongClick = { showChooser = true; state.refresh() },
                readOnly = state.loading,
                accentColor = lutAccent, ambientEffectColor = lutAccent, ambientEffectAlpha = loadingAlpha)
            ReleaseCommitWheel(
                options = listOf(Unit),
                selected = Unit,
                optionLabel = { lutSettingsLabel },
                onValueCommitted = {},
                onActivated = { haptics.tick(); lutSettingsExpanded = !lutSettingsExpanded },
                modifier = Modifier.weight(PHOTO_COLOR_INTENSITY_WEIGHT),
                wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                accentColor = lutAccent, enabled = active,
                emphasized = lutSettingsExpanded, showDragHint = false)
            FavoriteToggleButton(current?.toString() in state.favorites, active,
                { haptics.tick(); state.favorite() })
        }
        PhotoColorEffectGroup(visible = lutSettingsExpanded && state.selection != null, spacing = 0.dp) {
            val adjustments = state.selection?.lutAdjustments ?: com.ztransfer.filter.LutAdjustments()
            val values = remember { (-100..100 step 5).toList() }
            key(state.selection?.preset?.id, state.selection?.normalizedIntensityPercent, adjustments) {
                Column(
                    Modifier.fillMaxWidth().padding(top = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    ReleaseCommitWheel(
                        remember { (100 downTo 2 step 2).toList() },
                        state.selection?.normalizedIntensityPercent ?: 80,
                        optionLabel = { "$it%" }, onValueCommitted = state::strength,
                        modifier = Modifier.fillMaxWidth(), label = stringResource(R.string.photo_lut_concentration),
                        wheelHeight = 34.dp, cornerRadius = 10.dp, optionRowHeight = 16.dp,
                        optionFontSize = 13.sp, accentColor = lutAccent, enabled = active, onDetent = haptics::tick,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        ReleaseCommitWheel(
                            values, adjustments.contrast,
                            optionLabel = { it.toString() }, onValueCommitted = {
                                state.adjustments(adjustments.copy(contrast = it))
                            }, modifier = Modifier.weight(1f), label = stringResource(R.string.photo_lut_contrast),
                            wheelHeight = 34.dp, cornerRadius = 10.dp, optionRowHeight = 16.dp,
                            optionFontSize = 13.sp, accentColor = lutAccent, enabled = active, onDetent = haptics::tick,
                        )
                        ReleaseCommitWheel(
                            values, adjustments.saturation,
                            optionLabel = { it.toString() }, onValueCommitted = {
                                state.adjustments(adjustments.copy(saturation = it))
                            }, modifier = Modifier.weight(1f), label = stringResource(R.string.photo_lut_saturation),
                            wheelHeight = 34.dp, cornerRadius = 10.dp, optionRowHeight = 16.dp,
                            optionFontSize = 13.sp, accentColor = lutAccent, enabled = active, onDetent = haptics::tick,
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        ReleaseCommitWheel(
                            values, adjustments.highlights,
                            optionLabel = { it.toString() }, onValueCommitted = {
                                state.adjustments(adjustments.copy(highlights = it))
                            }, modifier = Modifier.weight(1f), label = stringResource(R.string.photo_lut_highlights),
                            wheelHeight = 34.dp, cornerRadius = 10.dp, optionRowHeight = 16.dp,
                            optionFontSize = 13.sp, accentColor = lutAccent, enabled = active, onDetent = haptics::tick,
                        )
                        ReleaseCommitWheel(
                            values, adjustments.shadows,
                            optionLabel = { it.toString() }, onValueCommitted = {
                                state.adjustments(adjustments.copy(shadows = it))
                            }, modifier = Modifier.weight(1f), label = stringResource(R.string.photo_lut_shadows),
                            wheelHeight = 34.dp, cornerRadius = 10.dp, optionRowHeight = 16.dp,
                            optionFontSize = 13.sp, accentColor = lutAccent, enabled = active, onDetent = haptics::tick,
                        )
                    }
                }
            }
        }
    }
    if (showChooser) {
        val maxHeight = (LocalConfiguration.current.screenHeightDp - 120).coerceIn(120, 440).dp
        Dialog(onDismissRequest = { showChooser = false },
            properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Surface(
                modifier = Modifier.padding(horizontal = 24.dp).width(320.dp),
                shape = RoundedCornerShape(18.dp),
                color = colors.glassSurface.copy(alpha = .92f),
                border = BorderStroke(1.dp, colors.glassPanelBorder),
                shadowElevation = 6.dp,
            ) {
                Column(Modifier.padding(10.dp).heightIn(max = maxHeight)) {
                    LutChooserHeader(current == null, stringResource(R.string.lut_change_folder),
                        onOff = { haptics.tick(); state.choose(null); showChooser = false },
                        onFolder = { showChooser = false; openFolder() })
                    LutCategoryList(ordered, current, modifier = Modifier.weight(1f, fill = false).fillMaxWidth()) { file ->
                        Surface(
                            onClick = { haptics.tick(); state.choose(file.uri); showChooser = false },
                            shape = RoundedCornerShape(8.dp),
                            color = if (file.uri == current) lutAccent.copy(alpha = .18f) else Color.Transparent,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(file.label, maxLines = 2, overflow = TextOverflow.Ellipsis,
                                color = when {
                                    file.uri.toString() in state.favorites -> colors.accentYellow
                                    file.uri == current -> lutAccent
                                    else -> colors.onBackground
                                },
                                style = MaterialTheme.typography.labelLarge,
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp))
                        }
                    }

                }
            }
        }
    }
}

/** Plain holder: retaining exit content does not schedule another composition or allocate a bitmap. */
private class RetainedPhotoEffectContent(var content: @Composable () -> Unit)

/** One layout transition owns both the section and its spacing, including its outgoing contents. */
@Composable
internal fun PhotoColorEffectGroup(visible: Boolean, spacing: androidx.compose.ui.unit.Dp = 10.dp, content: @Composable () -> Unit) {
    val retained = remember { RetainedPhotoEffectContent(content) }
    if (visible) SideEffect { retained.content = content }
    val displayedContent = if (visible) content else retained.content
    AnimatedVisibility(
        visible = visible,
        enter = expandVertically(
            animationSpec = tween(240, easing = FastOutSlowInEasing),
            expandFrom = Alignment.Top,
        ) + fadeIn(tween(200)),
        exit = fadeOut(tween(200)) + shrinkVertically(
            animationSpec = tween(240, easing = FastOutSlowInEasing),
            shrinkTowards = Alignment.Top,
        ),
    ) {
        Column {
            displayedContent()
            Spacer(Modifier.height(spacing))
        }
    }
}
