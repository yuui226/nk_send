package com.ztransfer.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.screen.*
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.catalog.*
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.util.rememberHaptics
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.withContext
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay

/** Temporary original-file coordinator around the original grid, not a replacement product UI. */
@Composable
internal fun NativeOriginalFilesPage(
    model: NativeFilesPageModel, text: NativeFilesPageText, queueText: NativeQueuePageText,
    filterText: NativeFilterText,
    thumbnails: ThumbnailGridImageSource, onBack: () -> Unit,
    previewText: PreviewSessionText,
    settingsText: NativeSettingsPageText,
    openPreview: (List<CameraFileInfo>) -> NativePreviewPageSource?,
    queuePage: @Composable (onBack: () -> Unit) -> Unit,
) {
    val state by model.state.collectAsState()
    val originals by model.originals.collectAsState()
    val criteria by model.filters.collectAsState()
    val layout by model.layout.collectAsState()
    val previewOptions by model.previewOptions.collectAsState()
    val preferencesFailed by model.preferencesFailed.collectAsState()
    val tasks by model.queue.state.collectAsState()
    val connected by model.queue.connected.collectAsState()
    val colors = AppTheme.colors
    val scope = rememberCoroutineScope()
    var showQueue by remember { mutableStateOf(false) }
    var preview by remember(model) { mutableStateOf<NativeFilesPreview?>(null) }
    var previewBuildJob by remember(model) { mutableStateOf<Job?>(null) }
    var returnHandle by remember(model) { mutableStateOf<Int?>(null) }
    var returnNonce by remember(model) { mutableIntStateOf(0) }
    var queueBounds by remember(model) { mutableStateOf<Rect?>(null) }
    var settingsAnchor by remember(model) { mutableStateOf<Rect?>(null) }
    var openedSettingsAnchor by remember(model) { mutableStateOf<Rect?>(null) }
    val haptics = rememberHaptics(true)
    val density = LocalDensity.current
    DisposableEffect(model) {
        onDispose { previewBuildJob?.cancel(); preview?.source?.close() }
    }
    fun closePreview() {
        previewBuildJob?.cancel(); previewBuildJob = null
        preview?.source?.close(); preview = null
    }
    val columns = layout.columns
    val collapseBursts = layout.collapseBursts
    val dates = remember(model) { mutableStateMapOf<String, Boolean>() }
    LaunchedEffect(state.files) {
        val validDates = state.files.mapTo(HashSet()) { it.captureDate?.take(8) ?: UNKNOWN_CAPTURE_DATE_GROUP_KEY }
        dates.keys.filterNot { it in validDates }.forEach(dates::remove)
    }
    val expanded = remember(model) { mutableStateMapOf<String, Boolean>() }
    val previousBursts = remember(model) { arrayOf(state.bursts) }
    LaunchedEffect(collapseBursts, state.bursts) {
        val retained = if (collapseBursts) {
            reconciledExpandedBurstIds(previousBursts[0], state.bursts, expanded.keys.toSet())
        } else emptySet()
        expanded.keys.filterNot { it in retained }.forEach(expanded::remove)
        retained.filterNot { expanded[it] == true }.forEach { expanded[it] = true }
        previousBursts[0] = state.bursts
    }
    val bounds = remember(model) { HashMap<Int, Rect>() }
    val burstBounds = remember(model) { HashMap<String, Rect>() }
    val burstIDs = remember(state.bursts) { state.bursts.flatMap { b -> b.files.map { it.handle to b.id } }.toMap() }
    val taskIndex = remember(tasks.tasks) { buildLatestTaskIndexByHandle(tasks.tasks) }
    val grid = rememberLazyGridState()
    var filterAnchor by remember(model) { mutableStateOf<Rect?>(null) }
    var openedFilterAnchor by remember(model) { mutableStateOf<Rect?>(null) }
    var filterRevealTick by remember(model) { mutableIntStateOf(0) }
    var filterRevealWindow by remember(model) { mutableStateOf(false) }
    LaunchedEffect(filterRevealTick) {
        if (filterRevealTick > 0) { delay(600); filterRevealWindow = false }
    }
    if (showQueue) { queuePage { showQueue = false }; return }
    val filterCalendar = remember(model) { NativeFilterCalendar(model::currentDayKey) }
    val availableExts = remember(state.files) { state.files.map { it.extension }.distinct().sorted() }
    val storageSlots = remember(state.storageIds) { storageFilterSlots(storageIdsBySlot(state.storageIds).keys) }
    val suggestedDate = remember(state.files) { latestCaptureDayKey(state.files.asSequence().map { it.captureDate }) }
    val filterActive = criteria != SharedPhotoFilterCriteria<CaptureDayRange>()
    val exportedHandles = remember(state.files, originals.revision, criteria.untransferredOnly) { model.transferredHandlesForFilter() }
    val exportExit = rememberExportExitState(tasks.tasks, criteria.untransferredOnly && originals.ready, exportedHandles)
    val groups = remember(state.groups, state.files, state.storageIds, criteria, burstIDs, exportExit.filteredHandles) {
        if (!filterActive) state.groups else groupCameraFilesByDate(nativeFilteredCameraFiles(state.files, state.storageIds, criteria,
            burstIDs.keys, exportExit.filteredHandles)).map { FileGroup(it.date, it.files) }
    }
    val expandedIds = expanded.keys.toSet()
    val previewIdentity = remember(groups, burstIDs, collapseBursts, expandedIds) { Any() }
    val currentPreviewIdentity by rememberUpdatedState(previewIdentity)
    val latestOpenPreview by rememberUpdatedState(openPreview)
    val burstContent = remember(thumbnails, text) { NativePreviewBurstContent(thumbnails, text) }
    fun requestPreview(file: CameraFileInfo, rect: Rect, expandBurst: String? = null) {
        haptics.longPress()
        val identity = previewIdentity
        val expansion = if (expandBurst == null) expandedIds else expandedIds + expandBurst
        previewBuildJob?.cancel()
        previewBuildJob = scope.launch {
            val snapshot = withContext(Dispatchers.Default) {
                nativePreviewItems(groups, burstIDs, collapseBursts, expansion)
            }
            val index = snapshot.indexOfFirst { it is PhotoPreviewItem.Photo && it.file.handle == file.handle }
            if (index >= 0 && currentPreviewIdentity === identity) {
                val files = snapshotPreviewSessionSources(snapshot) { it }.values.filterNotNull()
                val source = latestOpenPreview(files)
                if (source == null) model.previewPending()
                else {
                    preview?.source?.close()
                    preview = NativeFilesPreview(snapshot, index, rect, identity, source)
                }
            }
        }
    }
    val prepareDismiss: suspend (CameraFileInfo) -> Rect? = prepare@{ file ->
        val groupsSnapshot = groups
        if (!withContext(Dispatchers.Default) { groupsSnapshot.any { group -> group.files.any { it.handle == file.handle } } }) {
            return@prepare null // E.g. Pending filtered the completed original out; never scroll or expand for it.
        }
        val burst = burstIDs[file.handle]
        if (collapseBursts && burst != null && expanded[burst] != true) {
            expanded[burst] = true
            withFrameNanos { }
        }
        if (grid.layoutInfo.visibleItemsInfo.none { it.key == file.handle }) {
            val collapsedDates = dates.filterValues { it }.keys
            val expandedSnapshot = expanded.keys.toSet()
            val target = withContext(Dispatchers.Default) {
                nativePreviewGridIndex(file.handle, groupsSnapshot, burstIDs, collapseBursts, expandedSnapshot, collapsedDates)
            } ?: return@prepare null
            nativePreviewScrollApproach(target, grid.firstVisibleItemIndex, columns)?.let { nearby ->
                grid.scrollToItem(nearby)
                withFrameNanos { }
            }
            grid.animateScrollToItem(target, -with(density) { 88.dp.roundToPx() })
            withFrameNanos { }
        }
        withFrameNanos { }
        bounds[file.handle]
    }
    fun clearFilters() {
        openedFilterAnchor = null // Destroy any date draft together with all current criteria.
        model.changeFilters(SharedPhotoFilterCriteria())
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val screenWidth = maxWidth
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                GlassButton(onClick = { closePreview(); onBack() }, contentPadding = PaddingValues(8.dp)) {
                    Icon(Icons.Default.ArrowBack, queueText.back, Modifier.size(20.dp))
                }
                SharedSignalPill(text = queueText.signal, onOpenWifiSettings = model.queue::showConnectionHelp,
                    allowUnknownRssi = true, rssi = null, connected = connected, staMode = model.queue.stationMode,
                    onStaDisconnectedClick = model.queue::showConnectionHelp)
                Spacer(Modifier.weight(1f))
                GlassButton(onClick = model::refresh, enabled = connected && !state.scanning && !state.enqueueing) { Text(text.refresh) }
                GlassButton(onClick = { closePreview(); showQueue = true },
                    modifier = Modifier.onGloballyPositioned { queueBounds = it.boundsInRoot() }) { Text(text.queue) }
            }
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                GlassButton(onClick = { closePreview(); openedSettingsAnchor = settingsAnchor },
                    modifier = Modifier.onGloballyPositioned { settingsAnchor = it.boundsInRoot() }) {
                    Text(settingsText.title)
                }
                GlassButton(onClick = { openedFilterAnchor = filterAnchor }, enabled = state.hasSnapshot, active = filterActive,
                    modifier = Modifier.onGloballyPositioned { filterAnchor = it.boundsInRoot() }) {
                    FilterMark(Modifier.size(18.dp), color = colors.accentBlue)
                    Spacer(Modifier.width(6.dp))
                    Text(filterText.label(FilterTextKey.filter_title))
                }
                if (filterActive) GlassButton(onClick = ::clearFilters) { Text(text.clearFilters) }
            }
            Text(text.integrationStatus, color = colors.onSurfaceVariant, style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
            text.notice(state.notice)?.let { Text(it, color = colors.accentOrange, style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp)) }
            if (originals.failed) Text(text.indexFailed, color = colors.accentOrange, style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
            if (preferencesFailed) Text(text.preferencesFailed, color = colors.accentOrange, style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
            if (!originals.ready) Text(text.indexPending, color = colors.onSurfaceVariant, style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
            if (criteria.untransferredOnly && !originals.ready) {
                // A restored Pending filter must never briefly classify every original as missing.
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    Text(text.indexPending, color = colors.onSurfaceVariant)
                }
            } else if (groups.isEmpty()) {
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(when {
                            state.files.isNotEmpty() -> text.noMatches
                            state.scanning -> text.loadingFiles
                            state.hasSnapshot -> text.empty
                            else -> text.refresh
                        }, color = colors.onSurfaceVariant)
                        if (filterActive) {
                            Spacer(Modifier.height(18.dp))
                            GlassButton(onClick = ::clearFilters) { Text(text.clearFilters) }
                        }
                    }
                }
            } else {
                SharedThumbnailGrid(
                    groups = groups, tasks = tasks.tasks, queuedIndexByHandle = taskIndex,
                    activeProgress = { model.queue.activeProgress.collectAsState().value },
                    columns = columns, isLoading = state.scanning, transfersBusy = tasks.isTransferring,
                    allowRemoteThumbnails = connected && preview == null, collapsedDates = dates, thumbnails = thumbnails, text = text,
                    // Current original-only defaults save in the root bucket; future date preferences must share this rule.
                    isTransferred = { file -> remember(file, originals.revision) { model.isTransferred(file) } },
                    onTransferGroup = { files, _ -> scope.launch(start = CoroutineStart.UNDISPATCHED) { model.enqueue(files) } },
                    onTapFile = { file -> scope.launch(start = CoroutineStart.UNDISPATCHED) { model.enqueue(listOf(file)) } },
                    onPreview = { file, rect -> requestPreview(file, rect) },
                    onPreviewBurst = { id, files, rect -> files.firstOrNull()?.let { requestPreview(it, rect, id) } },
                    tapToPreview = layout.tapToPreview, cellBoundsRegistry = bounds, burstBoundsRegistry = burstBounds,
                    burstHandles = burstIDs.keys, burstIdByHandle = burstIDs, collapseBurstPhotos = collapseBursts,
                    expandedBursts = expanded, contentPadding = PaddingValues(start = 12.dp, end = 12.dp, bottom = 32.dp),
                    gridState = grid, modifier = Modifier.weight(1f).fillMaxWidth(),
                    filterRevealTick = filterRevealTick, filterRevealWindow = filterRevealWindow,
                    exitingExportHandles = exportExit.exitingHandles, exportReflowActive = exportExit.reflowActive,
                    onExportExitFinished = exportExit.onExitFinished,
                    returnFocusHandle = returnHandle, returnFocusNonce = returnNonce,
                )
            }
        }
        preview?.let { opening ->
            key(opening) {
                SharedPhotoPreviewOverlay(
                    items = opening.items, initialIndex = opening.index,
                    anchorRect = opening.anchor.takeIf { opening.identity === previewIdentity },
                    session = opening.source, text = previewText, burstContent = burstContent,
                    backHandler = { _, _ -> }, // iOS has no Android hardware Back; original tap/gesture close remains.
                    hapticsEnabled = true, transfersBusy = tasks.isTransferring,
                    initialRotationQuarterTurns = previewOptions.rotationQuarterTurns,
                    histogramVisible = previewOptions.histogramEnabled, burstHandles = burstIDs.keys,
                    queueTaskFor = { file -> taskIndex[file.handle]?.let(tasks.tasks::getOrNull)?.takeIf { it.file.handle == file.handle } },
                    isTransferred = model::isTransferred, localOriginalUriFor = opening.source::localSource,
                    activeProgress = { model.queue.activeProgress.collectAsState().value },
                    queueTargetBounds = queueBounds, onTransferAsync = model::enqueue,
                    onBurstExpandedChange = { id, value -> if (value) expanded[id] = true else expanded.remove(id) },
                    onRotationChanged = model::setPreviewRotationQuarterTurns,
                    onHistogramVisibleChanged = model::setPreviewHistogramEnabled,
                    prepareDismissTarget = prepareDismiss,
                    onDismiss = { file ->
                        closePreview()
                        if (file != null) {
                            returnHandle = file.handle
                            val nonce = ++returnNonce
                            scope.launch {
                                delay(760)
                                if (returnNonce == nonce) returnHandle = null
                            }
                        }
                    },
                )
            }
        }
        openedSettingsAnchor?.let { frozenAnchor ->
            NativePhotoSettingsOverlay(model, layout, settingsText, frozenAnchor) { openedSettingsAnchor = null }
        }
        openedFilterAnchor?.let { frozenAnchor ->
            SharedFilterOverlay(
                anchorBounds = frozenAnchor, calendar = filterCalendar, text = filterText, screenWidth = screenWidth,
                availableExts = availableExts, current = criteria, storageSlots = storageSlots,
                suggestedDate = suggestedDate, hapticsEnabled = true,
                untransferredEnabled = originals.ready,
                onChange = { next ->
                    if (model.changeFilters(next)) {
                        filterRevealTick++
                        filterRevealWindow = true // Set synchronously with the criteria, before the next layout frame.
                    }
                },
                onDismiss = { openedFilterAnchor = null },
            )
        }
    }
}

private class NativeFilesPreview(val items: List<PhotoPreviewItem>, val index: Int, val anchor: Rect,
    val identity: Any, val source: NativePreviewPageSource)

private class NativePreviewBurstContent(private val thumbnails: ThumbnailGridImageSource, private val text: ThumbnailGridText) : PreviewBurstContent {
    @Composable override fun accessibility(count: Int): String = text.burstAccessibility(count)
    @Composable override fun Photo(file: CameraFileInfo, loadEnabled: Boolean, showPlaceholderIcon: Boolean, modifier: Modifier) {
        SharedBurstStackPhoto(file, thumbnails, transfersBusy = false, loadEnabled = loadEnabled,
            showPlaceholderIcon = showPlaceholderIcon, modifier = modifier)
    }
    @Composable override fun Badge(count: Int, iconSize: Dp, modifier: Modifier) {
        SharedBurstCollectionBadge(text, count, modifier, iconSize)
    }
}
