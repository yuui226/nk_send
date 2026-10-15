package com.ztransfer.ui.screen

import android.content.ClipData
import android.content.Intent
import android.widget.Toast
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
import androidx.compose.material.icons.filled.Refresh
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
    data class Restore(override val slot: Int) : SlotAction
}

/** Slot list -> explicit destination editor -> shared preset chooser. No slot is chosen implicitly. */
@Composable
internal fun RemotePictureControlPanel(
    camera: NikonCamera?, anchor: Rect?, landscape: Boolean, closeRequested: Boolean,
    canWrite: Boolean, movie: Boolean, report: String,
    folders: PictureControlFolderState,
    editingSlot: Int?, onEditingSlot: (Int?) -> Unit, onFolder: (Int) -> Unit,
    isCurrentCamera: () -> Boolean, onReport: (String) -> Unit,
    onDismiss: () -> Unit, onFeedback: () -> Unit,
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
    var message by remember { mutableStateOf<String?>(null) }
    var saveFailed by remember { mutableStateOf(false) }
    val currentCamera by rememberUpdatedState(isCurrentCamera)
    val updateReport by rememberUpdatedState(onReport)
    val allowed by rememberUpdatedState(canWrite)
    val busyChange by rememberUpdatedState(onWriteBusyChanged)

    suspend fun refresh() {
        if (camera == null || !currentCamera()) { loadFailed = true; loading = false; return }
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
    }
    LaunchedEffect(camera, movie) { refresh() }

    val act: (SlotAction) -> Unit = action@ { action ->
        if (camera == null || !allowed || !currentCamera() || pending != null || loading || loadFailed) return@action
        val state = overview ?: return@action
        val target = state.slots.singleOrNull { it.slot == action.slot } ?: return@action
        val permitted = when (action) {
            is SlotAction.Activate -> state.canActivate && target.availability == PictureControlSlotAvailability.OCCUPIED
            is SlotAction.Write -> state.canEdit && target.readable
            is SlotAction.Clear -> state.canEdit && target.availability == PictureControlSlotAvailability.OCCUPIED
            is SlotAction.Restore -> state.canEdit && target.hasOriginal
        }
        if (!permitted || !busyChange(true)) return@action
        onFeedback()
        pending = action
        message = null
        saveFailed = false
        confirmClear = false
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            val text = StringBuilder()
            var journal: File? = null
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
                        is SlotAction.Restore -> PictureControlChange.Restore.also { log("action=restore original") }
                    }
                    camera.changePictureControl(context.filesDir, action.slot, change, movie, { currentCamera() }, ::log)
                }
                message = context.getString(when (action) {
                    is SlotAction.Write, is SlotAction.Activate -> R.string.picture_control_slot_applied
                    is SlotAction.Clear -> R.string.picture_control_slot_cleared
                    is SlotAction.Restore -> R.string.picture_control_slot_restored
                }, action.slot - 200)
                onEditingSlot(null)
                refresh() // A failed refresh is separate from a successfully verified mutation.
            } catch (error: CancellationException) {
                withContext(Dispatchers.IO + NonCancellable) { log("UI cancelled; started mutation completed verification/rollback before releasing camera gate") }
                throw error
            } catch (error: Exception) {
                val resource = when (error) {
                    is PictureControlReplacementException -> if (error.originalRestored)
                        R.string.picture_control_failed_restored else R.string.picture_control_restore_needed
                    is PictureControlImportException -> when (error.reason) {
                        PictureControlImportFailure.READ -> R.string.picture_control_file_read_failed
                        PictureControlImportFailure.INVALID -> R.string.picture_control_file_invalid
                        PictureControlImportFailure.UNSUPPORTED -> R.string.picture_control_file_unsupported
                        PictureControlImportFailure.TIMEOUT -> R.string.picture_control_read_timeout
                    }
                    else -> R.string.picture_control_write_failed
                }
                message = context.getString(resource, action.slot - 200)
                withContext(Dispatchers.IO + NonCancellable) {
                    log("FAILED: ${error.javaClass.simpleName}: ${error.message}; cause=${error.cause?.message}")
                }
                refresh()
            } finally {
                updateReport(text.toString())
                pending = null
                busyChange(false)
            }
        }
    }
    fun back() {
        if (pending != null) return
        if (confirmClear) confirmClear = false else onEditingSlot(null)
        message = null
    }
    val editor = overview?.slots?.singleOrNull { it.slot == editingSlot }
    val goBack: (() -> Unit)? = if (editingSlot != null) ({ back() }) else null
    RemoteChoicePopup(anchor, landscape, 320.dp, closeRequested, onDismiss, onBack = goBack) { _, closing ->
        val idle = !closing && pending == null && !loading
        val enabled = idle && canWrite && !loadFailed
        Column(Modifier.weight(1f, fill = false).fillMaxWidth().padding(horizontal = 10.dp, vertical = 6.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                if (editingSlot != null) IconButton(onClick = { onFeedback(); back() }, enabled = idle,
                    modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Default.ArrowBack, stringResource(R.string.picture_control_back),
                        tint = colors.onSurfaceVariant, modifier = Modifier.size(18.dp))
                }
                Text(if (editingSlot == null) stringResource(R.string.picture_control_slots_title)
                    else stringResource(R.string.picture_control_edit_slot, editingSlot - 200),
                    color = colors.onBackground, style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier.weight(1f).padding(horizontal = 8.dp))
                IconButton(onClick = { onFeedback(); scope.launch(start = CoroutineStart.UNDISPATCHED) { refresh() } },
                    enabled = idle && camera != null, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Default.Refresh, stringResource(R.string.picture_control_refresh),
                        tint = colors.onSurfaceVariant, modifier = Modifier.size(18.dp))
                }
            }
            val guidance = when {
                pending != null -> context.getString(R.string.picture_control_slot_busy, pending!!.slot - 200)
                loading -> context.getString(R.string.picture_control_loading)
                loadFailed -> context.getString(R.string.picture_control_slots_read_failed)
                message != null -> message
                !canWrite -> context.getString(R.string.picture_control_connect_hint)
                else -> null
            }
            if (guidance != null) Text(guidance, color = colors.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp))
            when {
                editingSlot == null -> {
                    val slots = overview?.slots ?: NIKON_PICTURE_CONTROL_SLOTS.map {
                        PictureControlSlotInfo(it, PictureControlSlotAvailability.UNREADABLE)
                    }
                    LazyColumn(Modifier.weight(1f, fill = false).fillMaxWidth()) {
                        items(slots, key = { it.slot }) { slot ->
                            PictureControlSlotRow(slot, overview?.selected == slot.slot,
                                pending?.slot == slot.slot,
                                canActivate = enabled && overview?.canActivate == true,
                                canEdit = enabled && overview?.canEdit == true,
                                onActivate = { act(SlotAction.Activate(slot.slot)) },
                                onEdit = { onFeedback(); message = null; onEditingSlot(slot.slot) })
                        }
                    }
                }
                confirmClear -> {
                    Column(Modifier.weight(1f, fill = false).fillMaxWidth().verticalScroll(rememberScrollState())) {
                        Text(stringResource(R.string.picture_control_clear_confirm, editingSlot - 200),
                            color = colors.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.padding(12.dp))
                        RemotePresetChoice(stringResource(R.string.picture_control_clear_slot, editingSlot - 200),
                            false, false, enabled && overview?.canEdit == true &&
                                editor?.availability == PictureControlSlotAvailability.OCCUPIED) {
                            act(SlotAction.Clear(editingSlot))
                        }
                        RemotePresetChoice(stringResource(R.string.picture_control_cancel), false, false, idle) {
                            onFeedback(); confirmClear = false
                        }
                    }
                }
                else -> {
                    PictureControlPresetChooser(folders,
                        enabled = enabled && overview?.canEdit == true && editor?.readable == true,
                        browsingEnabled = idle, pending = (pending as? SlotAction.Write)?.choice?.key,
                        onFolder = { onFolder(editingSlot) }, onFeedback = onFeedback,
                        onChoose = { act(SlotAction.Write(editingSlot, it)) })
                    // Keep slot actions compact so a short landscape popup still has room for presets.
                    Row(Modifier.fillMaxWidth()) {
                        if (editor?.availability == PictureControlSlotAvailability.OCCUPIED) Box(Modifier.weight(1f)) {
                            RemotePresetChoice(stringResource(R.string.picture_control_clear_slot, editingSlot - 200),
                                false, false, enabled && overview?.canEdit == true) {
                                onFeedback(); message = null; confirmClear = true
                            }
                        }
                        if (editor?.hasOriginal == true) Box(Modifier.weight(1f)) {
                            RemotePresetChoice(stringResource(R.string.picture_control_restore_original, editingSlot - 200),
                                false, pending is SlotAction.Restore, enabled && overview?.canEdit == true) {
                                act(SlotAction.Restore(editingSlot))
                            }
                        }
                    }
                }
            }
            if (BuildConfig.DEBUG && saveFailed) Text(stringResource(R.string.picture_control_report_save_failed),
                color = colors.onSurfaceVariant, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(12.dp))
            if (BuildConfig.DEBUG && report.isNotBlank()) Text(stringResource(R.string.picture_control_share_report),
                color = colors.accentBlue, style = MaterialTheme.typography.labelLarge,
                modifier = Modifier.fillMaxWidth().clickable(enabled = pending == null && !closing) {
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
                            context.startActivity(Intent.createChooser(intent, context.getString(R.string.picture_control_share_report)))
                            onFeedback()
                        } catch (error: CancellationException) { throw error }
                        catch (_: Exception) { Toast.makeText(context, R.string.picture_control_report_share_failed, Toast.LENGTH_LONG).show() }
                    }
                }.padding(12.dp))
        }
    }
}

@Composable
private fun PictureControlSlotRow(
    info: PictureControlSlotInfo, selected: Boolean, pending: Boolean,
    canActivate: Boolean, canEdit: Boolean, onActivate: () -> Unit, onEdit: () -> Unit,
) {
    val colors = AppTheme.colors
    val editable = canEdit && (info.readable || info.hasOriginal)
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
                else canActivate && info.availability == PictureControlSlotAvailability.OCCUPIED) {
                if (info.availability == PictureControlSlotAvailability.EMPTY) onEdit() else onActivate()
            }
        }
        IconButton(onClick = onEdit, enabled = editable, modifier = Modifier.size(36.dp)) {
            Icon(Icons.Default.Edit, stringResource(R.string.picture_control_edit_slot, info.number),
                tint = colors.onSurfaceVariant.copy(alpha = if (editable) 1f else .35f), modifier = Modifier.size(18.dp))
        }
    }
}
