package com.ztransfer.ui

import androidx.compose.foundation.layout.*
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
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

/** Product original-file coordinator reusing the original grid, preview and queue workspace. */
@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
internal fun NativeOriginalFilesPage(
    model: NativeFilesPageModel, text: NativeFilesPageText, queueText: NativeQueuePageText,
    filterText: NativeFilterText,
    thumbnails: ThumbnailGridImageSource, onBack: () -> Unit,
    previewText: PreviewSessionText,
    settingsText: NativeSettingsPageText,
    appearance: NativeAppearanceModel,
    cachedThumbnail: (CameraFileInfo) -> ImageBitmap?,
    openPreview: (List<CameraFileInfo>) -> NativePreviewPageSource?,
    queuePage: @Composable (topOnly: Boolean, onBack: () -> Unit) -> Unit,
) {
    val state by model.state.collectAsState()
    val memoryRevision by model.memoryRevision.collectAsState()
    val originals by model.originals.collectAsState()
    val criteria by model.filters.collectAsState()
    val layout by model.layout.collectAsState()
    val previewOptions by model.previewOptions.collectAsState()
    val preferencesFailed by model.preferencesFailed.collectAsState()
    val transferPreferences by model.transferPreferences.collectAsState()
    val transferPreferencesFailed by model.transferPreferencesFailed.collectAsState()
    // Invalid/missing capture dates use today's bucket. Re-evaluate even across an idle midnight.
    val lookupDayKey by produceState(0, model, transferPreferences.organizeByDate) {
        if (transferPreferences.organizeByDate) while (true) {
            value = model.currentDayKey()
            delay(60_000)
        }
    }
    val appearanceState by appearance.state.collectAsState()
    val tasks by model.queue.state.collectAsState()
    val arrivals by model.arrivals.collectAsState()
    val connected by model.queue.connected.collectAsState()
    val colors = AppTheme.colors
    val scope = rememberCoroutineScope()
    val flights = remember(model) { mutableStateListOf<QueueFlight>() }
    var nextFlight by remember(model) { mutableLongStateOf(0) }
    var caught by remember(model) { mutableLongStateOf(0) }
    val catchScale = remember(model) { Animatable(1f) }
    LaunchedEffect(caught) {
        if (caught > 0) {
            catchScale.animateTo(1.18f, tween(110, easing = FastOutSlowInEasing))
            catchScale.animateTo(1f, com.ztransfer.ui.theme.Motion.bouncy())
        }
    }
    var showQueue by remember { mutableStateOf(false) }
    var originalActionItems by remember(model) { mutableStateOf<List<NativeOriginalActionItem>?>(null) }
    var preview by remember(model) { mutableStateOf<NativeFilesPreview?>(null) }
    var previewBuildJob by remember(model) { mutableStateOf<Job?>(null) }
    var returnHandle by remember(model) { mutableStateOf<Int?>(null) }
    var returnNonce by remember(model) { mutableIntStateOf(0) }
    var queueBounds by remember(model) { mutableStateOf<Rect?>(null) }
    var signalBounds by remember(model) { mutableStateOf<Rect?>(null) }
    var settingsAnchor by remember(model) { mutableStateOf<Rect?>(null) }
    var openedSettingsAnchor by remember(model) { mutableStateOf<Rect?>(null) }
    val haptics = rememberHaptics(appearanceState.hapticsEnabled)
    val density = LocalDensity.current
    DisposableEffect(model) {
        onDispose { previewBuildJob?.cancel(); preview?.source?.close() }
    }
    fun closePreview() {
        previewBuildJob?.cancel(); previewBuildJob = null
        preview?.source?.close(); preview = null
    }
    LaunchedEffect(memoryRevision) { if (memoryRevision > 0L) { closePreview(); flights.clear() } }
    val columns = layout.columns
    val collapseBursts = layout.collapseBursts
    val dates = remember(model) { model.browseSession.collapsedDates }
    LaunchedEffect(state.files, state.hasSnapshot, state.scanning) {
        val validDates = state.files.mapTo(HashSet()) { it.captureDate?.take(8) ?: UNKNOWN_CAPTURE_DATE_GROUP_KEY }
        if (state.hasSnapshot && !state.scanning) dates.keys.filterNot { it in validDates }.forEach(dates::remove)
    }
    val expanded = remember(model) { model.browseSession.expandedBursts }
    val previousBursts = remember(model) { arrayOf(state.bursts) }
    LaunchedEffect(collapseBursts, state.bursts, state.hasSnapshot, state.scanning) {
        if (!state.hasSnapshot || state.scanning) return@LaunchedEffect
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
    val grid = rememberLazyGridState(model.browseSession.firstVisibleIndex, model.browseSession.firstVisibleOffset)
    val openingScroll = remember(model) { Triple(model.browseSession.anchorHandle,
        model.browseSession.firstVisibleIndex, model.browseSession.firstVisibleOffset) }
    LaunchedEffect(model, grid) {
        snapshotFlow { Triple(grid.firstVisibleItemIndex, grid.firstVisibleItemScrollOffset,
            grid.layoutInfo.visibleItemsInfo.firstNotNullOfOrNull { it.key as? Int }) }.collect { value ->
            if (grid.layoutInfo.totalItemsCount > 0) {
                model.browseSession.firstVisibleIndex = value.first
                model.browseSession.firstVisibleOffset = value.second
                model.browseSession.anchorHandle = value.third
            }
        }
    }
    var filterAnchor by remember(model) { mutableStateOf<Rect?>(null) }
    var openedFilterAnchor by remember(model) { mutableStateOf<Rect?>(null) }
    var filterRevealTick by remember(model) { mutableIntStateOf(0) }
    var filterRevealWindow by remember(model) { mutableStateOf(false) }
    LaunchedEffect(filterRevealTick) {
        if (filterRevealTick > 0) { delay(600); filterRevealWindow = false }
    }
    val filterCalendar = remember(model) { NativeFilterCalendar(model::currentDayKey) }
    val availableExts = remember(state.files) { state.files.map { it.extension }.distinct().sorted() }
    val storageSlots = remember(state.storageIds) { storageFilterSlots(storageIdsBySlot(state.storageIds).keys) }
    val suggestedDate = remember(state.files) { latestCaptureDayKey(state.files.asSequence().map { it.captureDate }) }
    val filterActive = criteria != SharedPhotoFilterCriteria<CaptureDayRange>()
    val exportedHandles = remember(state.files, originals.revision, criteria.untransferredOnly, transferPreferences.organizeByDate, lookupDayKey) { model.transferredHandlesForFilter() }
    val exportExit = rememberExportExitState(tasks.tasks, criteria.untransferredOnly && originals.ready, exportedHandles)
    val groups = remember(state.groups, state.files, state.storageIds, criteria, burstIDs, exportExit.filteredHandles) {
        if (!filterActive) state.groups else groupCameraFilesByDate(nativeFilteredCameraFiles(state.files, state.storageIds, criteria,
            burstIDs.keys, exportExit.filteredHandles)).map { FileGroup(it.date, it.files) }
    }
    val expandedIds = expanded.keys.toSet()
    var restoredScroll by remember(model) { mutableStateOf(false) }
    LaunchedEffect(state.hasSnapshot, state.scanning) {
        if (!restoredScroll && state.hasSnapshot && !state.scanning) {
            restoredScroll = true
            val target = openingScroll.first?.let {
                nativePreviewGridIndex(it, groups, burstIDs, collapseBursts, expandedIds, dates.filterValues { v -> v }.keys)
            } ?: openingScroll.second
            if (target > 0 || openingScroll.third > 0) grid.scrollToItem(target.coerceAtLeast(0), openingScroll.third.coerceAtLeast(0))
        }
    }
    val previewIdentity = remember(groups, burstIDs, collapseBursts, expandedIds) { Any() }
    val currentPreviewIdentity by rememberUpdatedState(previewIdentity)
    val latestOpenPreview by rememberUpdatedState(openPreview)
    LaunchedEffect(arrivals.revision) {
        if (arrivals.revision > 0 && !showQueue && preview == null && arrivals.files.isNotEmpty()) {
            val from = bounds[arrivals.files.first().handle] ?: signalBounds
            if (from != null && queueBounds != null && flights.none { it.from == from }) {
                flights += QueueFlight(++nextFlight, from, emptyList(), arrivals.files.size,
                    cachedThumbnail(arrivals.files.first()))
            }
        }
    }
    fun enqueueFromGrid(files: List<CameraFileInfo>, from: Rect?, group: Boolean) {
        if (files.isEmpty()) return
        val visible = grid.layoutInfo.visibleItemsInfo.mapNotNullTo(HashSet()) { it.key as? Int }
        val cells = if (group) files.filter { it.handle in visible }.mapNotNull { file ->
            bounds[file.handle]?.let { PackSoul(it, cachedThumbnail(file)) }
        } else emptyList()
        val packs = if (cells.size <= MAX_PACK_GHOSTS) cells else List(MAX_PACK_GHOSTS) { cells[it * cells.size / MAX_PACK_GHOSTS] }
        val thumb = cachedThumbnail(files.first())
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            if (model.enqueue(files) == files.size) {
                haptics.tick()
                if (!showQueue && from != null && flights.none { it.from == from }) {
                    flights += QueueFlight(++nextFlight, from, packs, files.size, thumb)
                }
            }
        }
    }
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
    SharedFilesQueueWorkspace(queueVisible = showQueue, onFilesSettledChanged = {},
        filesContent = {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val screenWidth = maxWidth
        Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                GlassButton(onClick = { closePreview(); onBack() }, contentPadding = PaddingValues(8.dp)) {
                    Icon(Icons.Default.ArrowBack, queueText.back, Modifier.size(20.dp))
                }
                Box(Modifier.onGloballyPositioned { signalBounds = it.boundsInRoot() }) {
                SharedSignalPill(text = queueText.signal, onOpenWifiSettings = model.queue::showConnectionHelp,
                    allowUnknownRssi = true, rssi = null, connected = connected, staMode = model.queue.stationMode,
                    onStaDisconnectedClick = model.queue::showConnectionHelp)
                }
                Spacer(Modifier.weight(1f))
                Box(Modifier.onGloballyPositioned { queueBounds = it.boundsInRoot() }
                    .graphicsLayer { scaleX = catchScale.value; scaleY = catchScale.value }) {
                    SharedQueuePill(tasks.tasks, tasks.isTransferring,
                        liveProgressSource = { model.queue.activeProgress.collectAsState().value },
                        haptics = haptics, onClick = { closePreview(); flights.clear(); showQueue = true },
                        heldCount = flights.filter { it.holdsQueueCount }.sumOf { it.count },
                        formatSpeed = { com.ztransfer.format.formatTransferSpeedText(it, model.queue::fixed) },
                        transferDescription = text.queue, generatingLabel = "")
                }
            }
            FlowRow(Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                GlassButton(onClick = model::refresh, enabled = connected && !state.scanning && !state.enqueueing) { Text(text.refresh) }

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
                GlassButton(enabled = originals.ready, onClick = {
                    originalActionItems = model.originalActionItems(groups.flatMap { it.files })
                }) { Text(nativeActionText(appearanceState.resolvedLanguage, "已存原片", "Saved")) }
            }
            text.notice(state.notice)?.let { Text(it, color = colors.accentOrange, style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp)) }
            if (originals.failed) Text(text.indexFailed, color = colors.accentOrange, style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
            if (preferencesFailed || transferPreferencesFailed || appearanceState.preferencesFailed) Text(text.preferencesFailed, color = colors.accentOrange, style = MaterialTheme.typography.bodySmall,
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
                    allowRemoteThumbnails = connected && preview == null && !showQueue, collapsedDates = dates, thumbnails = thumbnails, text = text,
                    // Current original-only defaults save in the root bucket; future date preferences must share this rule.
                    isTransferred = { file -> remember(file, originals.revision, transferPreferences.organizeByDate, lookupDayKey) { model.isTransferred(file) } },
                    onTransferGroup = { files, from -> enqueueFromGrid(files, from, true) },
                    onTapFile = { file -> enqueueFromGrid(listOf(file), bounds[file.handle], false) },
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
        flights.toList().forEach { flight ->
            key(flight.id) { QueueFlightGhost(flight, queueBounds) { flights.remove(flight); caught++ } }
        }
        preview?.let { opening ->
            key(opening) {
                SharedPhotoPreviewOverlay(
                    items = opening.items, initialIndex = opening.index,
                    anchorRect = opening.anchor.takeIf { opening.identity === previewIdentity },
                    session = opening.source, text = previewText, burstContent = burstContent,
                    backHandler = { _, _ -> }, // iOS has no Android hardware Back; original tap/gesture close remains.
                    hapticsEnabled = appearanceState.hapticsEnabled, transfersBusy = tasks.isTransferring,
                    initialRotationQuarterTurns = previewOptions.rotationQuarterTurns,
                    histogramVisible = previewOptions.histogramEnabled, burstHandles = burstIDs.keys,
                    queueTaskFor = { file -> taskIndex[file.handle]?.let(tasks.tasks::getOrNull)?.takeIf { it.file.handle == file.handle } },
                    isTransferred = model::isTransferred, localOriginalUriFor = opening.source::localSource,
                    activeProgress = { model.queue.activeProgress.collectAsState().value },
                    queueTargetBounds = queueBounds, onTransferAsync = model::enqueue,
                    onQueueFlightCaught = { caught++ },
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
            NativePhotoSettingsOverlay(model, layout, settingsText, frozenAnchor, appearance) { openedSettingsAnchor = null }
        }
        originalActionItems?.let { frozen ->
            NativeOriginalActionsDialog(model.originalActions, frozen, appearanceState.resolvedLanguage) { originalActionItems = null }
        }
        openedFilterAnchor?.let { frozenAnchor ->
            SharedFilterOverlay(
                anchorBounds = frozenAnchor, calendar = filterCalendar, text = filterText, screenWidth = screenWidth,
                availableExts = availableExts, current = criteria, storageSlots = storageSlots,
                suggestedDate = suggestedDate, hapticsEnabled = appearanceState.hapticsEnabled,
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
        }, queueContent = { queuePage(false) { showQueue = false } },
        queueTopContent = { queuePage(true) { showQueue = false } })
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
