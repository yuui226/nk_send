package com.ztransfer.ui.screen

import android.content.ClipData
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.updateTransition
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.core.content.FileProvider
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.rememberTextMeasurer
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

private sealed interface SlotAction {
    val slot: Int
    data class Write(override val slot: Int, val choice: PictureControlPresetChoice) : SlotAction
    data class Activate(override val slot: Int) : SlotAction
    data class Clear(override val slot: Int) : SlotAction
}

private enum class PictureControlConfirmation { CLEAR, FOLDER }

private data class PictureControlPage(
    val slot: Int?,
    val confirmation: PictureControlConfirmation?,
)

/** Slot list -> explicit destination editor -> shared preset chooser. No slot is chosen implicitly. */
@Composable
internal fun RemotePictureControlPanel(
    camera: NikonCamera?, anchor: Rect?, landscape: Boolean, closeRequested: Boolean,
    canWrite: Boolean, movie: Boolean, report: String,
    folders: PictureControlFolderState,
    presets: Result<List<BuiltInPictureControl>>?, onLoadingChanged: (Boolean) -> Unit,
    editingSlot: Int?, onEditingSlot: (Int?) -> Unit, onFolder: (Int) -> Unit,
    isCurrentCamera: () -> Boolean,
    onStartReport: (PictureControlReports.Kind) -> PictureControlReports.Ticket,
    onReport: (PictureControlReports.Ticket, String) -> Unit,
    onDismiss: () -> Unit, onFeedback: () -> Unit, onNotice: (String) -> Unit,
    onWriteBusyChanged: (Boolean) -> Boolean,
) {
    val context = LocalContext.current
    val colors = AppTheme.colors
    val scope = rememberCoroutineScope()
    var overview by remember { mutableStateOf<PictureControlOverview?>(null) }
    var loading by remember { mutableStateOf(camera != null) }
    var loadFailed by remember { mutableStateOf(false) }
    var loadFailureResource by remember { mutableIntStateOf(R.string.picture_control_slots_read_failed) }
    var initialLoadFinished by remember { mutableStateOf(false) }
    var pending by remember { mutableStateOf<SlotAction?>(null) }
    var confirmation by remember(editingSlot) { mutableStateOf<PictureControlConfirmation?>(null) }
    val currentCamera by rememberUpdatedState(isCurrentCamera)
    val startReport by rememberUpdatedState(onStartReport)
    val updateReport by rememberUpdatedState(onReport)
    val notice by rememberUpdatedState(onNotice)
    val allowed by rememberUpdatedState(canWrite)
    val busyChange by rememberUpdatedState(onWriteBusyChanged)
    val dismiss by rememberUpdatedState(onDismiss)
    val opening = !initialLoadFinished || presets == null
    LaunchedEffect(opening) { onLoadingChanged(opening) }
    LaunchedEffect(closeRequested) { if (closeRequested && opening) dismiss() }
    if (opening) BackHandler { dismiss() }

    suspend fun refresh(notifyFailure: Boolean = true, log: ((String) -> Unit)? = null) {
        loading = true
        try {
            val result = withContext(Dispatchers.IO) {
                check(camera != null && currentCamera()) { "Camera session unavailable" }
                camera.readPictureControlOverview(context.filesDir, movie, log) { currentCamera() }
            }
            check(currentCamera()) { "Camera session changed after reading slots" }
            overview = result
            loadFailed = false
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) {
            loadFailed = true
            loadFailureResource = if (error is PictureControlMovieBankUnsupportedException)
                R.string.picture_control_movie_bank_unsupported else R.string.picture_control_slots_read_failed
            withContext(Dispatchers.IO) {
                log?.invoke("READ FAILED: ${error.javaClass.simpleName}: ${error.message}; cause=${error.cause?.message}")
            }
        }
        finally { loading = false }
        if (loadFailed && notifyFailure) notice(context.getString(loadFailureResource))
    }
    LaunchedEffect(camera, movie) {
        val reportId = if (BuildConfig.DEBUG) startReport(PictureControlReports.Kind.OVERVIEW) else null
        var journal: PictureControlReports.Journal? = null
        try {
            if (BuildConfig.DEBUG) withContext(Dispatchers.IO) {
                journal = PictureControlReports.Journal(context.filesDir, PictureControlReports.Kind.OVERVIEW).also {
                    it.append("Picture Control overview v1 ${java.time.OffsetDateTime.now()} app=${BuildConfig.VERSION_NAME}(${BuildConfig.VERSION_CODE}) camera=${camera?.cachedDeviceInfo?.model ?: "unknown"} movie=$movie")
                }
            }
            refresh(notifyFailure = !BuildConfig.DEBUG, log = journal?.let { it::append })
        } catch (error: CancellationException) {
            withContext(Dispatchers.IO + NonCancellable) { journal?.append("READ CANCELLED: panel closed or camera changed") }
            throw error
        } finally {
            journal?.let { updateReport(checkNotNull(reportId), it.report()) }
            initialLoadFinished = true
        }
        if (loadFailed && !BuildConfig.DEBUG) dismiss()
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
        confirmation = null
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            val reportId = if (BuildConfig.DEBUG) startReport(PictureControlReports.Kind.OPERATION) else null
            var journal: PictureControlReports.Journal? = null
            var operationFailed = false
            fun log(line: String) { journal?.append(line) }
            val readLog: ((String) -> Unit)? = if (BuildConfig.DEBUG) ::log else null
            try {
                withContext(Dispatchers.IO) {
                    if (BuildConfig.DEBUG) {
                        journal = PictureControlReports.Journal(context.filesDir, PictureControlReports.Kind.OPERATION)
                    }
                    log("Picture Control slots v6 ${java.time.OffsetDateTime.now()} app=${BuildConfig.VERSION_NAME}(${BuildConfig.VERSION_CODE}) camera=${camera.cachedDeviceInfo?.model ?: "unknown"} movie=$movie target=C${action.slot - 200}")
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
                    camera.changePictureControl(context.filesDir, action.slot, change, movie, { currentCamera() }, readLog)
                }
                refresh(log = readLog) // Keep this read in the operation's report, including failures.
                // Return with the final names/width, rather than resizing again after the transition.
                onEditingSlot(null)
            } catch (error: CancellationException) {
                withContext(Dispatchers.IO + NonCancellable) { log("UI cancelled; started mutation completed verification/rollback before releasing camera gate") }
                throw error
            } catch (error: Exception) {
                operationFailed = true
                val resource = when (error) {
                    is PictureControlExposureModeException -> R.string.picture_control_exposure_mode_required
                    is PictureControlPresetUnsupportedException -> R.string.picture_control_camera_preset_unsupported
                    is PictureControlMovieBankUnsupportedException -> R.string.picture_control_movie_bank_unsupported
                    is PictureControlReplacementException -> if (error.originalRestored)
                        R.string.picture_control_failed_restored else R.string.picture_control_check_slot
                    is PictureControlImportException -> when (error.reason) {
                        PictureControlImportFailure.READ -> R.string.picture_control_file_read_failed
                        PictureControlImportFailure.INVALID -> R.string.picture_control_file_invalid
                        PictureControlImportFailure.FLEXIBLE_COLOR -> R.string.picture_control_flexible_color_unsupported
                        PictureControlImportFailure.UNSUPPORTED -> R.string.picture_control_file_unsupported
                        PictureControlImportFailure.TIMEOUT -> R.string.picture_control_read_timeout
                    }
                    else -> R.string.picture_control_write_failed
                }
                withContext(Dispatchers.IO + NonCancellable) {
                    log("FAILED: ${error.javaClass.simpleName}: ${error.message}; cause=${error.cause?.message}")
                }
                // Report the operation failure once, rather than replacing it with a refresh error.
                refresh(notifyFailure = false, log = readLog)
                notice(context.getString(resource, action.slot - 200))
            } finally {
                journal?.let { updateReport(checkNotNull(reportId), it.report()) }
                pending = null
                busyChange(false)
                if (BuildConfig.DEBUG && journal?.saveFailed == true && !operationFailed) {
                    notice(context.getString(R.string.picture_control_report_save_failed))
                }
            }
        }
    }
    fun back() {
        if (pending != null) return
        if (confirmation != null) confirmation = null else onEditingSlot(null)
    }
    val goBack: (() -> Unit)? = if (editingSlot != null) ({ back() }) else null
    // Match camera-tool menus: start the popup animation with real content, never error placeholders.
    if (opening) return
    if (BuildConfig.DEBUG && overview == null && loadFailed) {
        RemoteChoicePopup(anchor, landscape, 220.dp, closeRequested, onDismiss) { _, closing ->
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(if (loadFailureResource == R.string.picture_control_movie_bank_unsupported)
                    loadFailureResource else R.string.picture_control_slot_unreadable),
                    color = colors.onSurfaceVariant, style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier.weight(1f))
                PictureControlTestLogButton(report, !closing, onFeedback, onNotice)
            }
        }
        return
    }
    val loadedOverview = overview ?: return
    val loadedPresets = presets ?: return
    val density = LocalDensity.current
    val slotLabels = loadedOverview.slots.map { pictureControlSlotLabel(it) }
    val slotTextStyle = MaterialTheme.typography.labelLarge
    val textMeasurer = rememberTextMeasurer(cacheSize = slotLabels.size)
    // Monitor state updates frequently. Names only need measuring again when their content,
    // font or density changes; selection/busy/frame updates must not remeasure all nine rows.
    val overviewWidth = remember(slotLabels, slotTextStyle, density, textMeasurer) {
        val labelWidth = slotLabels.maxOfOrNull { label ->
            with(density) {
                textMeasurer.measure(label, slotTextStyle,
                    softWrap = false, maxLines = 1).size.width.toDp()
            }
        } ?: 60.dp
        // Label padding + compact edit target + trailing inset. The shell also caps to the screen.
        (labelWidth + 24.dp + 32.dp + 3.dp).coerceAtMost(320.dp)
    }
    val page = PictureControlPage(editingSlot, confirmation)
    RemoteChoicePopup(anchor, landscape, maxOf(overviewWidth, 260.dp), closeRequested, onDismiss, onBack = goBack,
        verticalContentPadding = 0.dp, wrapContentWidth = true) { _, closing ->
        val pageTransition = updateTransition(page, label = "pictureControlPage")
        pageTransition.AnimatedContent(
            modifier = Modifier.weight(1f, fill = false),
            contentAlignment = Alignment.TopStart,
            transitionSpec = {
                (fadeIn(tween(180, delayMillis = 40)) togetherWith fadeOut(tween(140)))
                    .using(SizeTransform { _, _ ->
                        spring(dampingRatio = .85f, stiffness = Spring.StiffnessMediumLow)
                    })
            },
        ) { displayedPage ->
            // Keep outgoing content intact during the fade, but never let it dispatch another action.
            val slotNumber = displayedPage.slot
            val editor = loadedOverview.slots.singleOrNull { it.slot == slotNumber }
            // A second tap must not select a preset while its page is still fading/resizing.
            val settled = !pageTransition.isRunning && pageTransition.currentState == pageTransition.targetState
            val idle = settled && displayedPage == page && !closing && pending == null && !loading
            val enabled = idle && canWrite && !loadFailed
            // Slot highlights meet the shell's clipped edges; only the editor keeps content insets.
            Column(Modifier.width(if (slotNumber == null) overviewWidth else 260.dp)
                .padding(horizontal = if (slotNumber == null) 0.dp else 8.dp)
                .padding(top = if (slotNumber == null) 0.dp else 4.dp,
                    bottom = if (slotNumber == null) 0.dp else 8.dp)) {
                if (slotNumber != null) Row(Modifier.fillMaxWidth().padding(bottom = 2.dp).heightIn(min = 32.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(32.dp).clickable(enabled = idle, role = Role.Button) { onFeedback(); back() },
                        contentAlignment = Alignment.Center) {
                        Icon(Icons.Default.ArrowBack, stringResource(R.string.picture_control_back),
                            tint = colors.onSurfaceVariant, modifier = Modifier.size(18.dp))
                    }
                    Text("C${slotNumber - 200}",
                        color = colors.onBackground, style = MaterialTheme.typography.titleMedium,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(horizontal = 6.dp))
                    if (displayedPage.confirmation == null && editor?.availability == PictureControlSlotAvailability.OCCUPIED) {
                        PictureControlClearButton(stringResource(R.string.picture_control_clear_slot),
                            enabled && overview?.canEdit == true,
                            modifier = Modifier.padding(start = 6.dp),
                            compact = true) {
                            onFeedback(); confirmation = PictureControlConfirmation.CLEAR
                        }
                    }
                    Spacer(Modifier.weight(1f))
                    if (displayedPage.confirmation == null) {
                        PresetFolderButton(
                            stringResource(R.string.picture_control_folder),
                            idle, Modifier.widthIn(max = 112.dp), compact = true,
                        ) {
                            onFeedback()
                            if (folders.folder == null) confirmation = PictureControlConfirmation.FOLDER else onFolder(slotNumber)
                        }
                    }
                }
                when {
                    slotNumber == null -> {
                        val slots = loadedOverview.slots
                        // Always nine small rows: compose them once instead of subcomposing
                        // a lazy list while the popup is preparing its opening frame.
                        Column(Modifier.weight(1f, fill = false).fillMaxWidth()
                            .verticalScroll(rememberScrollState())) {
                            slots.forEachIndexed { index, slot ->
                                PictureControlSlotRow(slot, slotLabels[index], overview?.selected == slot.slot,
                                    pending?.slot == slot.slot,
                                    canActivate = enabled && overview?.canActivate == true,
                                    canEdit = enabled && overview?.canEdit == true,
                                    onActivate = { act(SlotAction.Activate(slot.slot)) },
                                    onEdit = { onFeedback(); onEditingSlot(slot.slot) })
                            }
                            if (BuildConfig.DEBUG) {
                                Box(Modifier.fillMaxWidth().padding(horizontal = 8.dp), contentAlignment = Alignment.CenterEnd) {
                                    PictureControlTestLogButton(report, idle, onFeedback, onNotice)
                                }
                            }
                        }
                    }
                    displayedPage.confirmation == PictureControlConfirmation.FOLDER -> {
                        Column(Modifier.weight(1f, fill = false).fillMaxWidth().verticalScroll(rememberScrollState())) {
                            Text(stringResource(R.string.picture_control_choose_folder_hint),
                                color = colors.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium,
                                modifier = Modifier.padding(12.dp))
                            RemotePresetChoice(stringResource(R.string.picture_control_confirm), false, false, idle) {
                                onFeedback()
                                confirmation = null
                                onFolder(slotNumber)
                            }
                            RemotePresetChoice(stringResource(R.string.picture_control_cancel), false, false, idle) {
                                onFeedback(); confirmation = null
                            }
                        }
                    }
                    displayedPage.confirmation == PictureControlConfirmation.CLEAR -> {
                        Column(Modifier.weight(1f, fill = false).fillMaxWidth().verticalScroll(rememberScrollState())) {
                            Text(stringResource(R.string.picture_control_clear_confirm, slotNumber - 200),
                                color = colors.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium,
                                textAlign = TextAlign.Center,
                                modifier = Modifier.fillMaxWidth().padding(12.dp))
                            PictureControlClearButton(stringResource(R.string.picture_control_confirm),
                                enabled && overview?.canEdit == true &&
                                editor?.availability == PictureControlSlotAvailability.OCCUPIED,
                                modifier = Modifier.fillMaxWidth()) {
                                act(SlotAction.Clear(slotNumber))
                            }
                            RemotePresetChoice(stringResource(R.string.picture_control_cancel), false, false, idle,
                                textAlign = TextAlign.Center) {
                                onFeedback(); confirmation = null
                            }
                        }
                    }
                    else -> {
                        PictureControlPresetChooser(folders,
                            presets = loadedPresets,
                            enabled = enabled && overview?.canEdit == true && editor?.readable == true,
                            browsingEnabled = idle, pending = (pending as? SlotAction.Write)?.choice?.key,
                            onNotice = onNotice,
                            active = displayedPage == page && !closing,
                            onChoose = { act(SlotAction.Write(slotNumber, it)) })
                    }
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
        .heightIn(min = if (compact) 28.dp else 32.dp)
        .padding(horizontal = if (compact) 8.dp else 12.dp, vertical = if (compact) 3.dp else 8.dp),
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
private fun pictureControlSlotLabel(info: PictureControlSlotInfo): String {
    val label = when (info.availability) {
        PictureControlSlotAvailability.OCCUPIED -> info.name.orEmpty()
        PictureControlSlotAvailability.EMPTY -> stringResource(R.string.picture_control_slot_empty)
        PictureControlSlotAvailability.UNREADABLE -> stringResource(R.string.picture_control_slot_unreadable)
        PictureControlSlotAvailability.UNSUPPORTED -> stringResource(R.string.picture_control_slot_unsupported)
    }
    return "C${info.number} · $label"
}

@Composable
private fun PictureControlSlotRow(
    info: PictureControlSlotInfo, label: String, selected: Boolean, pending: Boolean,
    canActivate: Boolean, canEdit: Boolean, onActivate: () -> Unit, onEdit: () -> Unit,
) {
    val colors = AppTheme.colors
    val editable = canEdit && info.readable
    val empty = info.availability == PictureControlSlotAvailability.EMPTY
    val activatable = if (empty) editable
        else canActivate && info.availability == PictureControlSlotAvailability.OCCUPIED
    Row(Modifier.fillMaxWidth()
        .background(if (selected) colors.accentBlue.copy(alpha = .08f) else androidx.compose.ui.graphics.Color.Transparent)
        .clickable(enabled = activatable, role = Role.Button) {
            if (empty) onEdit() else onActivate()
        },
        verticalAlignment = Alignment.CenterVertically) {
        RemotePresetChoice(label, selected, pending, activatable,
            // The row owns selection and ripple; the label only renders text/pending feedback.
            showSelectionBackground = false, verticalPadding = 4.dp,
            modifier = Modifier.weight(1f), onClick = null)
        val editColor = if (selected && editable) colors.accentBlue else colors.onSurfaceVariant
        // 7dp inside the target + 3dp outside keeps the icon about 10dp from the edge.
        Box(Modifier.padding(end = 3.dp).size(32.dp)
            .clickable(enabled = editable, role = Role.Button, onClick = onEdit),
            contentAlignment = Alignment.Center) {
            Icon(Icons.Default.Edit, stringResource(R.string.picture_control_edit_slot, info.number),
                tint = editColor.copy(alpha = if (editable) 1f else .35f), modifier = Modifier.size(18.dp))
        }
    }
}
