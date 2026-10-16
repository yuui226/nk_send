package com.ztransfer.ui.screen

import android.content.ClipData
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.core.content.FileProvider
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.presets.*
import com.ztransfer.protocol.*
import com.ztransfer.ui.theme.AppTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

private sealed interface SlotAction {
    val slot: Int
    data class Write(override val slot: Int, val choice: PictureControlPresetChoice) : SlotAction
    data class Activate(override val slot: Int) : SlotAction
    data class Clear(override val slot: Int) : SlotAction
}

/** Slot list -> explicit destination editor -> shared preset chooser. No slot is chosen implicitly. */
@Composable
internal fun RemotePictureControlPanel(
    camera: NikonCamera?, anchor: Rect?, landscape: Boolean, closeRequested: Boolean,
    canWrite: Boolean, movie: Boolean, report: String,
    folders: PictureControlFolderState,
    presets: Result<List<BuiltInPictureControl>>?, onLoadingChanged: (Boolean) -> Unit,
    editingSlot: Int?, onEditingSlot: (Int?) -> Unit, onFolder: (Int) -> Unit,
    isCurrentCamera: () -> Boolean, onReport: (String) -> Unit,
    onDismiss: () -> Unit, onFeedback: () -> Unit, onNotice: (String) -> Unit,
    onWriteBusyChanged: (Boolean) -> Boolean,
) {
    val context = LocalContext.current
    val colors = AppTheme.colors
    val scope = rememberCoroutineScope()
    var overview by remember { mutableStateOf<PictureControlOverview?>(null) }
    var loading by remember { mutableStateOf(camera != null) }
    var loadFailed by remember { mutableStateOf(false) }
    var pending by remember { mutableStateOf<SlotAction?>(null) }
    var confirmClear by remember(editingSlot) { mutableStateOf(false) }
    var confirmFolder by remember(editingSlot) { mutableStateOf(false) }
    val currentCamera by rememberUpdatedState(isCurrentCamera)
    val updateReport by rememberUpdatedState(onReport)
    val notice by rememberUpdatedState(onNotice)
    val allowed by rememberUpdatedState(canWrite)
    val busyChange by rememberUpdatedState(onWriteBusyChanged)
    val dismiss by rememberUpdatedState(onDismiss)
    val opening = overview == null || presets == null
    LaunchedEffect(opening) { onLoadingChanged(opening) }
    LaunchedEffect(closeRequested) { if (closeRequested && opening) dismiss() }
    if (opening) BackHandler { dismiss() }

    suspend fun refresh(notifyFailure: Boolean = true) {
        if (camera == null || !currentCamera()) {
            loadFailed = true
            loading = false
            if (notifyFailure) notice(context.getString(R.string.picture_control_slots_read_failed))
            return
        }
        loading = true
        try {
            val result = withContext(Dispatchers.IO) {
                camera.readPictureControlOverview(context.filesDir, movie) { currentCamera() }
            }
            if (currentCamera()) { overview = result; loadFailed = false }
            else loadFailed = true
        } catch (error: CancellationException) { throw error }
        catch (_: Exception) { loadFailed = true }
        finally { loading = false }
        if (loadFailed && notifyFailure) notice(context.getString(R.string.picture_control_slots_read_failed))
    }
    LaunchedEffect(camera, movie) {
        refresh()
        if (loadFailed) dismiss()
    }

    val act: (SlotAction) -> Unit = action@ { action ->
        if (camera == null || !allowed || !currentCamera() || pending != null || loading || loadFailed) return@action
        val state = overview ?: return@action
        val target = state.slots.singleOrNull { it.slot == action.slot } ?: return@action
        val permitted = when (action) {
            is SlotAction.Activate -> state.canActivate && target.availability == PictureControlSlotAvailability.OCCUPIED
            is SlotAction.Write -> state.canEdit && target.readable
            is SlotAction.Clear -> state.canEdit && target.availability == PictureControlSlotAvailability.OCCUPIED
        }
        if (!permitted || !busyChange(true)) return@action
        onFeedback()
        pending = action
        confirmClear = false
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            val text = StringBuilder()
            var journal: File? = null
            var saveFailed = false
            var operationFailed = false
            fun log(line: String) {
                if (!BuildConfig.DEBUG) return
                text.appendLine(line)
                try { journal?.appendText(line + "\n", Charsets.UTF_8) }
                catch (_: Exception) { saveFailed = true }
            }
            try {
                withContext(Dispatchers.IO) {
                    if (BuildConfig.DEBUG) {
                        try { journal = PictureControlReports.create(context.filesDir) }
                        catch (_: Exception) { saveFailed = true }
                    }
                    log("Picture Control slots v6 ${java.time.OffsetDateTime.now()} app=${BuildConfig.VERSION_NAME}(${BuildConfig.VERSION_CODE}) movie=$movie target=C${action.slot - 200}")
                    val change = when (action) {
                        is SlotAction.Write -> {
                            val file = when (val choice = action.choice) {
                                is PictureControlPresetChoice.BuiltIn -> choice.preset.read(context.assets)
                                is PictureControlPresetChoice.Document -> folders.read(choice.file)
                            }
                            log("action=write preset=${file.name} NP3=${file.version} bytes=${file.bytes().size} sha256=${file.sha256}")
                            PictureControlChange.Write(file)
                        }
                        is SlotAction.Activate -> PictureControlChange.Activate.also { log("action=activate") }
                        is SlotAction.Clear -> PictureControlChange.Clear.also { log("action=clear") }
                    }
                    camera.changePictureControl(context.filesDir, action.slot, change, movie, { currentCamera() }, ::log)
                }
                onEditingSlot(null)
                refresh() // A failed refresh is separate from a successfully verified mutation.
            } catch (error: CancellationException) {
                withContext(Dispatchers.IO + NonCancellable) { log("UI cancelled; started mutation completed verification/rollback before releasing camera gate") }
                throw error
            } catch (error: Exception) {
                operationFailed = true
                val resource = when (error) {
                    is PictureControlReplacementException -> if (error.originalRestored)
                        R.string.picture_control_failed_restored else R.string.picture_control_check_slot
                    is PictureControlImportException -> when (error.reason) {
                        PictureControlImportFailure.READ -> R.string.picture_control_file_read_failed
                        PictureControlImportFailure.INVALID -> R.string.picture_control_file_invalid
                        PictureControlImportFailure.UNSUPPORTED -> R.string.picture_control_file_unsupported
                        PictureControlImportFailure.TIMEOUT -> R.string.picture_control_read_timeout
                    }
                    else -> R.string.picture_control_write_failed
                }
                withContext(Dispatchers.IO + NonCancellable) {
                    log("FAILED: ${error.javaClass.simpleName}: ${error.message}; cause=${error.cause?.message}")
                }
                // Report the operation failure once, rather than replacing it with a refresh error.
                refresh(notifyFailure = false)
                notice(context.getString(resource, action.slot - 200))
            } finally {
                updateReport(text.toString())
                pending = null
                busyChange(false)
                if (BuildConfig.DEBUG && saveFailed && !operationFailed) {
                    notice(context.getString(R.string.picture_control_report_save_failed))
                }
            }
        }
    }
    fun back() {
        if (pending != null) return
        when {
            confirmFolder -> confirmFolder = false
            confirmClear -> confirmClear = false
            else -> onEditingSlot(null)
        }
    }
    val editor = overview?.slots?.singleOrNull { it.slot == editingSlot }
    val goBack: (() -> Unit)? = if (editingSlot != null) ({ back() }) else null
    // Match camera-tool menus: start the popup animation with real content, never error placeholders.
    val loadedOverview = overview ?: return
    val loadedPresets = presets ?: return
    RemoteChoicePopup(anchor, landscape, 260.dp, closeRequested, onDismiss, onBack = goBack) { _, closing ->
        val idle = !closing && pending == null && !loading
        val enabled = idle && canWrite && !loadFailed
        // The popup shell contributes 4dp vertically, giving an even 8dp content inset.
        Column(Modifier.weight(1f, fill = false).fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp)) {
            if (editingSlot != null) Row(Modifier.fillMaxWidth().padding(bottom = 4.dp).heightIn(min = 32.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { onFeedback(); back() }, enabled = idle,
                    modifier = Modifier.size(32.dp).presetActionOutline(idle)) {
                    Icon(Icons.Default.ArrowBack, stringResource(R.string.picture_control_back),
                        tint = colors.onSurfaceVariant, modifier = Modifier.size(18.dp))
                }
                Text("C${editingSlot - 200}",
                    color = colors.onBackground, style = MaterialTheme.typography.labelLarge,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(horizontal = 6.dp))
                if (!confirmClear && !confirmFolder && editor?.availability == PictureControlSlotAvailability.OCCUPIED) {
                    PictureControlClearButton(stringResource(R.string.picture_control_clear_slot),
                        enabled && overview?.canEdit == true,
                        compact = true) {
                        onFeedback(); confirmClear = true
                    }
                }
                Spacer(Modifier.weight(1f))
                if (!confirmClear && !confirmFolder) {
                    PresetFolderButton(
                        stringResource(R.string.picture_control_folder),
                        idle, Modifier.widthIn(max = 112.dp),
                    ) {
                        onFeedback()
                        if (folders.folder == null) confirmFolder = true else onFolder(editingSlot)
                    }
                }
            }
            when {
                editingSlot == null -> {
                    val slots = loadedOverview.slots
                    LazyColumn(Modifier.weight(1f, fill = false).fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        items(slots, key = { it.slot }) { slot ->
                            PictureControlSlotRow(slot, overview?.selected == slot.slot,
                                pending?.slot == slot.slot,
                                canActivate = enabled && overview?.canActivate == true,
                                canEdit = enabled && overview?.canEdit == true,
                                onActivate = { act(SlotAction.Activate(slot.slot)) },
                                onEdit = { onFeedback(); onEditingSlot(slot.slot) })
                        }
                        if (BuildConfig.DEBUG) item(key = "test-log") {
                            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
                                PictureControlTestLogButton(report, pending == null && !closing, onFeedback, onNotice)
                            }
                        }
                    }
                }
                confirmFolder -> {
                    Column(Modifier.weight(1f, fill = false).fillMaxWidth().verticalScroll(rememberScrollState())) {
                        Text(stringResource(R.string.picture_control_choose_folder_hint),
                            color = colors.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.padding(12.dp))
                        RemotePresetChoice(stringResource(R.string.picture_control_confirm), false, false, idle) {
                            onFeedback()
                            confirmFolder = false
                            onFolder(editingSlot)
                        }
                        RemotePresetChoice(stringResource(R.string.picture_control_cancel), false, false, idle) {
                            onFeedback(); confirmFolder = false
                        }
                    }
                }
                confirmClear -> {
                    Column(Modifier.weight(1f, fill = false).fillMaxWidth().verticalScroll(rememberScrollState())) {
                        Text(stringResource(R.string.picture_control_clear_confirm, editingSlot - 200),
                            color = colors.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.padding(12.dp))
                        PictureControlClearButton(stringResource(R.string.picture_control_confirm),
                            enabled && overview?.canEdit == true &&
                            editor?.availability == PictureControlSlotAvailability.OCCUPIED,
                            modifier = Modifier.fillMaxWidth()) {
                            act(SlotAction.Clear(editingSlot))
                        }
                        RemotePresetChoice(stringResource(R.string.picture_control_cancel), false, false, idle) {
                            onFeedback(); confirmClear = false
                        }
                    }
                }
                else -> {
                    PictureControlPresetChooser(folders,
                        presets = loadedPresets,
                        enabled = enabled && overview?.canEdit == true && editor?.readable == true,
                        browsingEnabled = idle, pending = (pending as? SlotAction.Write)?.choice?.key,
                        onNotice = onNotice,
                        onChoose = { act(SlotAction.Write(editingSlot, it)) })
                }
            }
        }
    }
}

@Composable
private fun PictureControlClearButton(
    text: String, enabled: Boolean, modifier: Modifier = Modifier, compact: Boolean = false, onClick: () -> Unit,
) {
    Box(modifier.presetActionOutline(enabled, AppTheme.colors.statusError)
        .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
        .heightIn(min = 32.dp)
        .padding(horizontal = if (compact) 8.dp else 12.dp, vertical = if (compact) 5.dp else 8.dp),
        contentAlignment = Alignment.Center) {
        Text(text,
            color = AppTheme.colors.statusError.copy(alpha = if (enabled) 1f else .35f),
            style = if (compact) MaterialTheme.typography.labelMedium else MaterialTheme.typography.labelLarge,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun PictureControlTestLogButton(report: String, enabled: Boolean, onFeedback: () -> Unit, onNotice: (String) -> Unit) {
    val context = LocalContext.current
    val colors = AppTheme.colors
    val scope = rememberCoroutineScope()
    val canShare = enabled && report.isNotBlank()
    Text(stringResource(R.string.picture_control_test_log), maxLines = 1,
        color = if (canShare) colors.accentBlue else colors.onSurfaceVariant.copy(alpha = .35f),
        style = MaterialTheme.typography.labelLarge,
        modifier = Modifier.presetActionOutline(canShare).clickable(enabled = canShare, role = Role.Button) {
            onFeedback()
            scope.launch {
                try {
                    val file = withContext(Dispatchers.IO) { PictureControlReports.shareSnapshot(context.filesDir, report) }
                    val uri = FileProvider.getUriForFile(context, "${context.packageName}.update-files", file)
                    val intent = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_STREAM, uri)
                        clipData = ClipData.newRawUri("Picture Control", uri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    context.startActivity(Intent.createChooser(intent, context.getString(R.string.picture_control_test_log)))
                } catch (error: CancellationException) { throw error }
                catch (_: Exception) { onNotice(context.getString(R.string.picture_control_report_share_failed)) }
            }
        }.padding(horizontal = 8.dp, vertical = 8.dp))
}

@Composable
private fun PictureControlSlotRow(
    info: PictureControlSlotInfo, selected: Boolean, pending: Boolean,
    canActivate: Boolean, canEdit: Boolean, onActivate: () -> Unit, onEdit: () -> Unit,
) {
    val colors = AppTheme.colors
    val editable = canEdit && info.readable
    val label = when (info.availability) {
        PictureControlSlotAvailability.OCCUPIED -> info.name.orEmpty()
        PictureControlSlotAvailability.EMPTY -> stringResource(R.string.picture_control_slot_empty)
        PictureControlSlotAvailability.UNREADABLE -> stringResource(R.string.picture_control_slot_unreadable)
        PictureControlSlotAvailability.UNSUPPORTED -> stringResource(R.string.picture_control_slot_unsupported)
    }
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp))
        .background(if (selected) colors.accentBlue.copy(alpha = .08f) else androidx.compose.ui.graphics.Color.Transparent),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.weight(1f)) {
            RemotePresetChoice("C${info.number} · $label", selected, pending,
                if (info.availability == PictureControlSlotAvailability.EMPTY) editable
                else canActivate && info.availability == PictureControlSlotAvailability.OCCUPIED,
                // The row owns selection; the label keeps its blue text without a second wash.
                showSelectionBackground = false) {
                if (info.availability == PictureControlSlotAvailability.EMPTY) onEdit() else onActivate()
            }
        }
        val editColor = if (selected && editable) colors.accentBlue else colors.onSurfaceVariant
        IconButton(onClick = onEdit, enabled = editable,
            modifier = Modifier.size(36.dp).presetActionOutline(editable, editColor)
                .background(colors.surface)) {
            Icon(Icons.Default.Edit, stringResource(R.string.picture_control_edit_slot, info.number),
                tint = editColor.copy(alpha = if (editable) 1f else .35f), modifier = Modifier.size(18.dp))
        }
    }
}
