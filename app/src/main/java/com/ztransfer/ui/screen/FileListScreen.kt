package com.ztransfer.ui.screen

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.graphics.Bitmap
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ztransfer.R
import com.ztransfer.gps.NikonGpsService
import com.ztransfer.license.LicenseManager
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.ui.theme.*
import com.ztransfer.ui.util.Haptics
import com.ztransfer.ui.util.formatSpeed
import com.ztransfer.ui.util.rememberHaptics
import com.ztransfer.viewmodel.ActiveTransferProgress
import com.ztransfer.viewmodel.CameraState
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.ExportedOriginalIndex
import com.ztransfer.viewmodel.PhotoExif
import com.ztransfer.viewmodel.PhotoFilterCriteria
import com.ztransfer.viewmodel.PhotoDateRange
import com.ztransfer.catalog.CameraFileFilter
import com.ztransfer.catalog.UNKNOWN_CAPTURE_DATE_GROUP_KEY
import com.ztransfer.catalog.detectCameraBurstGroups
import com.ztransfer.catalog.filterCameraFiles
import com.ztransfer.catalog.groupCameraFilesByDate
import com.ztransfer.catalog.isStorageSlotSelected
import com.ztransfer.catalog.normalizeStorageSlotFilter
import com.ztransfer.catalog.storageFilterSlots
import com.ztransfer.catalog.storageIdsBySlot
import com.ztransfer.catalog.toggleStorageSlotSelection
import com.ztransfer.viewmodel.TransferState
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import com.ztransfer.viewmodel.TransferViewModel
import com.ztransfer.viewmodel.compactDateRangeLabel
import com.ztransfer.viewmodel.isTransferredOriginal
import com.ztransfer.viewmodel.latestCaptureLocalDate
import com.ztransfer.viewmodel.transferredOriginalUri
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlinx.coroutines.Job
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.YearMonth

data class FileGroup(
    val date: String,
    val files: List<NikonCamera.FileInfo>
)

/** 已由自动传输入口接纳、等待照片页播放一次入队反馈的文件批次。 */
data class AutoQueueFlightRequest(
    val id: Long,
    val camera: NikonCamera,
    val files: List<NikonCamera.FileInfo>,
)

internal fun burstCollectionGridKey(id: String): String = "burst_collection_$id"

/** 只从当前真实可见的普通格位或折叠合集格位选择自动入队动画起点。 */
internal fun resolveAutoQueueFlightSource(
    files: List<NikonCamera.FileInfo>,
    visibleKeys: Set<Any>,
    cellBoundsByHandle: Map<Int, Rect>,
    burstBoundsById: Map<String, Rect>,
    burstIdByHandle: Map<Int, String>,
): Rect? = files.firstNotNullOfOrNull { file ->
    cellBoundsByHandle[file.handle]?.takeIf { file.handle in visibleKeys }
        ?: burstIdByHandle[file.handle]?.let { burstId ->
            burstBoundsById[burstId]?.takeIf {
                burstCollectionGridKey(burstId) in visibleKeys
            }
        }
}

/** 照片页正文只观察会改变其内容或交互的相机状态，避免 RSSI 等顶栏更新重组网格。 */
internal data class FileListCameraUiState(
    val isConnectedToCamera: Boolean,
    val connectionType: CameraConnectionType?,
    val isStaConnection: Boolean,
    val files: List<NikonCamera.FileInfo>,
    val storageIds: List<Int>,
    val isLoadingFiles: Boolean,
    val hasCompletedFileScan: Boolean,
    val effectPreviewBitmap: Bitmap?,
    val cameraManufacturer: String?,
    val cameraModel: String?,
    val effectPreviewExif: PhotoExif?,
)

internal fun CameraState.toFileListCameraUiState(): FileListCameraUiState =
    FileListCameraUiState(
        isConnectedToCamera = isConnectedToCamera,
        connectionType = connectionType,
        isStaConnection = isStaConnection,
        files = files,
        storageIds = storageIds,
        isLoadingFiles = isLoadingFiles,
        hasCompletedFileScan = hasCompletedFileScan,
        effectPreviewBitmap = effectPreviewBitmap,
        cameraManufacturer = cameraManufacturer,
        cameraModel = cameraModel,
        effectPreviewExif = effectPreviewExif,
    )

/** 与网格和预览直接相关的传输状态；高频下载进度仍走独立的 activeProgress 流。 */
internal data class FileListTransferUiState(
    val tasks: List<TransferTask>,
    val taskStructureRevision: Long,
    val isTransferring: Boolean,
    val transferDirUri: String?,
    val existingExportIndex: ExportedOriginalIndex,
    val existingExportRevision: Long,
    val thumbnailColumns: Int,
    val collapseBurstPhotos: Boolean,
    val tapToPreview: Boolean,
    val hapticsEnabled: Boolean,
    val organizeTransfersByDate: Boolean,
    val filterExtensions: Set<String>?,
    val filterProtectedOnly: Boolean,
    val filterBurstOnly: Boolean,
    val filterUntransferredOnly: Boolean,
    val filterStorageSlot: Int?,
    val filterDateRange: PhotoDateRange?,
    val previewRotationQuarterTurns: Int,
    val previewHistogramEnabled: Boolean,
)

internal fun TransferState.toFileListTransferUiState(): FileListTransferUiState =
    FileListTransferUiState(
        tasks = tasks,
        taskStructureRevision = taskStructureRevision,
        isTransferring = isTransferring,
        transferDirUri = transferDirUri,
        existingExportIndex = existingExportIndex,
        existingExportRevision = existingExportRevision,
        thumbnailColumns = thumbnailColumns,
        collapseBurstPhotos = collapseBurstPhotos,
        tapToPreview = tapToPreview,
        hapticsEnabled = hapticsEnabled,
        organizeTransfersByDate = organizeTransfersByDate,
        filterExtensions = filterExtensions,
        filterProtectedOnly = filterProtectedOnly,
        filterBurstOnly = filterBurstOnly,
        filterUntransferredOnly = filterUntransferredOnly,
        filterStorageSlot = filterStorageSlot,
        filterDateRange = filterDateRange,
        previewRotationQuarterTurns = previewRotationQuarterTurns,
        previewHistogramEnabled = previewHistogramEnabled,
    )

internal data class FileListSignalUiState(
    val rssi: Int?,
    val connected: Boolean,
    val connectionType: CameraConnectionType?,
    val staMode: Boolean,
)

internal fun CameraState.toFileListSignalUiState(): FileListSignalUiState =
    FileListSignalUiState(
        rssi = wifiRssi,
        connected = isConnectedToCamera,
        connectionType = connectionType,
        staMode = isStaConnection,
    )

/** 一段真实连拍。它只描述检测结果；是否折成虚拟卡位由列表设置决定。 */
internal data class BurstPhotoGroup(
    val id: String,
    val files: List<NikonCamera.FileInfo>
)

/** LazyGrid 的展示层条目；合集卡不是相机文件，使用独立类型避免混入照片语义。 */
internal sealed interface ThumbnailGridItem {
    val key: Any

    data class Photo(
        val file: NikonCamera.FileInfo,
        val burstId: String? = null
    ) : ThumbnailGridItem {
        override val key: Any = file.handle
    }

    data class BurstCollection(
        val id: String,
        val files: List<NikonCamera.FileInfo>
    ) : ThumbnailGridItem {
        override val key: Any = burstCollectionGridKey(id)
    }
}

internal val ThumbnailGridItem.reuseContentType: String
    get() = when (this) {
        is ThumbnailGridItem.Photo -> "photo"
        is ThumbnailGridItem.BurstCollection -> "burst_collection"
    }

internal fun buildLatestTaskIndexByHandle(tasks: List<TransferTask>): Map<Int, Int> = buildMap {
    tasks.forEachIndexed { index, task -> put(task.file.handle, index) }
}

internal fun exportedHandlesForUntransferredFilter(
    files: List<NikonCamera.FileInfo>,
    index: ExportedOriginalIndex,
    organizeTransfersByDate: Boolean,
    enabled: Boolean,
): Set<Int> = if (enabled) {
    files.asSequence()
        .filter { file ->
            isTransferredOriginal(file, index, organizeTransfersByDate)
        }
        .mapTo(HashSet()) { it.handle }
} else {
    emptySet()
}

/** 展开后的队列胶囊内容；入口图标由主题按钮独立绘制。 */
internal enum class PillMode { DONE, PAUSED, GENERATING, COUNTING }

/** Right-bottom queue control and the compact paused pill deliberately share one vector. */
internal val TransferQueuePauseIcon = Icons.Default.Pause

internal fun queuePillMode(
    downloadRemaining: Int,
    generationRemaining: Int,
    paused: Boolean = false,
): PillMode = when {
    paused && downloadRemaining > 0 -> PillMode.PAUSED
    downloadRemaining > 0 -> PillMode.COUNTING
    generationRemaining > 0 -> PillMode.GENERATING
    else -> PillMode.DONE
}

/**
 * 队列胶囊可安全共用宽度的文本类别。同单位、同整数位数的速度在 tnum 下等宽；
 * 单位、速度整数位数或计数位数变化时必须重新测量，不能沿用此前的最大宽度。
 */
internal data class QueuePillWidthKey(
    val mode: PillMode,
    val speedUnit: String?,
    val speedIntegerDigits: Int,
    val countDigits: Int,
)

internal fun queuePillWidthKey(
    mode: PillMode,
    speedText: String?,
    count: Int,
): QueuePillWidthKey {
    if (mode != PillMode.COUNTING && mode != PillMode.PAUSED) {
        return QueuePillWidthKey(mode, speedUnit = null, speedIntegerDigits = 0, countDigits = 0)
    }
    val numericPart = speedText?.substringBefore(' ')
    return QueuePillWidthKey(
        mode = mode,
        speedUnit = speedText?.substringAfter(' ', missingDelimiterValue = ""),
        speedIntegerDigits = numericPart?.substringBefore('.')?.length ?: 0,
        countDigits = count.coerceAtLeast(0).toString().length,
    )
}

internal fun queuePillDisplayRemaining(actualRemaining: Int, heldCount: Int): Int {
    val actual = actualRemaining.coerceAtLeast(0)
    // The real queue is updated as soon as a card is tapped, while heldCount represents cards
    // that have not reached the queue pill yet. Keep displaying the number that has actually
    // landed, including zero. Falling back to the real count at zero makes overlapping flights
    // jump 2 -> 1 -> 2 as the first and second holds are released independently.
    return (actual - heldCount.coerceAtLeast(0)).coerceAtLeast(0)
}

internal fun queuePillAllRemainingTasksAreInFlight(
    actualRemaining: Int,
    heldCount: Int,
): Boolean = actualRemaining > 0 &&
    heldCount > 0 &&
    queuePillDisplayRemaining(actualRemaining, heldCount) == 0

internal enum class QueueExecutionControl { START, PAUSE }

internal fun queueExecutionControl(
    isTransferring: Boolean,
    waitingCount: Int,
): QueueExecutionControl? = when {
    isTransferring -> QueueExecutionControl.PAUSE
    waitingCount > 0 -> QueueExecutionControl.START
    else -> null
}

@Composable
private fun AnimatedQueuePillCount(
    count: Int,
    color: Color,
    label: String,
    modifier: Modifier = Modifier,
) {
    AnimatedContent(
        modifier = modifier,
        targetState = count,
        transitionSpec = {
            val dir = if (targetState < initialState) 1 else -1
            (slideInVertically { it / 2 * dir } + fadeIn(tween(160)))
                .togetherWith(
                    slideOutVertically { -it / 2 * dir } + fadeOut(tween(120)),
                )
                .using(SizeTransform(clip = true, sizeAnimationSpec = { _, _ -> snap() }))
        },
        label = label,
    ) { value ->
        Text(
            text = "$value",
            style = MaterialTheme.typography.labelLarge.copy(fontFeatureSettings = "tnum"),
            color = color,
            fontWeight = FontWeight.Bold,
        )
    }
}

/** 队列入口收起为普通按钮时使用固定材质种子，保证木纹/金属微纹在重组后保持一致。 */
private const val QUEUE_ENTRY_BUTTON_TEXTURE_SEED = 0x2A71E001
private const val REMOTE_BUSY_VISUAL_DELAY_MS = 180L
private val THUMBNAIL_THEME_BORDER_WIDTH = 0.75.dp
private val TOP_BAR_COMPACT_BUTTON_MIN_WIDTH = 40.dp

// 缩略图后台填充没有任何窗口/视口参数：未传输=从新到旧全量填充；传输中=完全停止。
// 填充逻辑住在 CameraViewModel.startThumbnailFill（与页面无关）。

// 主筛选与日期编辑共用固定宽度，切页时不横向重排面板。
// 筛选内容包含五列类型按钮和三列日期波轮：手机上尽量利用横向空间，宽屏则封顶，
// 避免固定窄面板挤压标签，也避免平板上横向铺得过散。
private val FILTER_PANEL_MAX_WIDTH = 360.dp
private val FILTER_PANEL_SCREEN_MARGIN = 12.dp
private val DATE_FILTER_WHEEL_HEIGHT = 50.dp

// 有彩色角标底（白字）的类型：其余走灰底灰字。提到顶层，避免每个格子每次重组都新建集合。
private val TYPE_BADGE_COLORED_EXTS = setOf(".jpg", ".nef", ".mov", ".mp4")

// 无拍摄日期文件的分组键（非显示文案，显示时映射到 R.string.unknown_date）。
// 以 "zzz" 开头保证按键降序排序时排在所有 "yyyyMMdd" 日期之前，与原行为一致。
private const val UNKNOWN_DATE_KEY = UNKNOWN_CAPTURE_DATE_GROUP_KEY

// 回到顶部：翻过多少条目（含分组头）才算"够深"；点击回顶时先瞬移到该位置再动画收尾。
private const val BACK_TO_TOP_MIN_INDEX = 30
private const val BACK_TO_TOP_SNAP_INDEX = 24

/** 正在播放收合动画的分组：[date] + 保留参与动画的前 [keep] 个格子（收起瞬间可见的那部分）。 */
private data class CollapsingGroup(val date: String, val keep: Int)

private const val BURST_REFLOW_DURATION_MS = 300
private const val BURST_MEMBER_ENTER_DURATION_MS = 180
private const val BURST_MEMBER_EXIT_DURATION_MS = 150
private const val CAMERA_REMOVAL_REFLOW_DURATION_MS = 280
private const val CAMERA_REMOVAL_ENTER_DURATION_MS = 180
private const val CAMERA_REMOVAL_EXIT_DURATION_MS = 160

/**
 * 手风琴收合：按 [progress]（1→0）缩减条目报告给布局的高度（内容顶部对齐、超出裁掉），
 * 绘制时同步淡出。高度变化是逐帧真实布局，下方内容随之连续上移——不经过条目位移
 * 动画器，不存在"移出屏幕的条目在边缘悬停"的框架问题。
 * 列表页分组收合与队列页卡片移除共用（包内共享）。
 */
internal fun Modifier.collapseHeight(progress: () -> Float): Modifier =
    clipToBounds().layout { measurable, constraints ->
        val placeable = measurable.measure(constraints)
        val p = progress().coerceIn(0f, 1f)
        layout(placeable.width, (placeable.height * p).roundToInt()) {
            placeable.placeRelativeWithLayer(0, 0) { alpha = p }
        }
    }

/** 从 Compose 的 Context 逐层向上找到宿主 Activity（用于返回键退出应用等窗口操作）。 */
internal fun Context.findActivity(): Activity? {
    var ctx: Context? = this
    while (ctx is ContextWrapper) {
        if (ctx is Activity) return ctx
        ctx = ctx.baseContext
    }
    return null
}

fun groupFilesByDate(files: List<NikonCamera.FileInfo>): List<FileGroup> {
    return groupCameraFilesByDate(files).map { group ->
        FileGroup(date = group.date, files = group.files)
    }
}

private data class PublishedCameraFileIdentity(
    val fileName: String,
    val size: Long,
    val captureDate: String?,
)

private fun NikonCamera.FileInfo.publishedIdentity() = PublishedCameraFileIdentity(
    fileName = fileName,
    size = size,
    captureDate = captureDate,
)

/** Dates whose logical camera photos disappeared in the latest authoritative update. */
internal fun publishedCameraRemovalDates(
    previous: List<NikonCamera.FileInfo>,
    current: List<NikonCamera.FileInfo>,
): Set<String> {
    if (previous.isEmpty()) return emptySet()
    val currentHandles = current.asSequence().mapTo(HashSet(current.size)) { it.handle }
    val missingHandles = previous.filter { it.handle !in currentHandles }
    if (missingHandles.isEmpty()) return emptySet()
    // A dual-card backup can keep the same logical photo under its surviving alias handle. That is
    // a session identity switch, not a visible deletion, and must not arm a grid exit animation.
    val currentIdentities = current.asSequence()
        .mapTo(HashSet(current.size)) { it.publishedIdentity() }
    return missingHandles.asSequence()
        .filter { it.publishedIdentity() !in currentIdentities }
        .mapTo(LinkedHashSet()) { it.captureDate?.take(8) ?: UNKNOWN_DATE_KEY }
}

// `.value` only seeds the mapped flows; ongoing updates are collected immediately below.
@SuppressLint("StateFlowValueCalledInComposition")
@Composable
fun FileListScreen(
    cameraViewModel: CameraViewModel,
    transferViewModel: TransferViewModel,
    queueTargetBounds: Rect?,
    onQueueFlightStarted: (Int) -> Unit,
    onQueueFlightFinished: (Int) -> Unit,
    onQueueFlightsCancelled: (Int) -> Unit,
    onQueueFlightCaught: () -> Unit,
    autoQueueFlightRequest: AutoQueueFlightRequest? = null,
    onAutoQueueFlightConsumed: (Long) -> Unit = {},
    onPreviewVisibilityChanged: (Boolean) -> Unit,
    backHandlerEnabled: Boolean,
    onRequestExitConfirmation: () -> Unit,
    onNavigateToRemote: () -> Unit
) {
    val state by remember(cameraViewModel) {
        cameraViewModel.state
            .map(CameraState::toFileListCameraUiState)
            .distinctUntilChanged()
    }.collectAsStateWithLifecycle(
        initialValue = cameraViewModel.state.value.toFileListCameraUiState(),
    )
    val transferState by remember(transferViewModel) {
        transferViewModel.state
            .map(TransferState::toFileListTransferUiState)
            .distinctUntilChanged()
    }.collectAsStateWithLifecycle(
        initialValue = transferViewModel.state.value.toFileListTransferUiState(),
    )
    val gpsContext = LocalContext.current
    val gpsBlockedByAp = state.isConnectedToCamera &&
        state.connectionType == CameraConnectionType.WIFI &&
        !state.isStaConnection
    LaunchedEffect(gpsBlockedByAp) {
        NikonGpsService.setApModeBlocked(gpsContext, gpsBlockedByAp)
    }
    // CameraState publishes authoritative removals immediately. The grid keeps its previous model
    // for one frame only, so every existing animateItem node can arm before the new derived date /
    // burst structure is submitted. No bitmap is copied and additions remain immediate.
    var presentedCameraFiles by remember { mutableStateOf(state.files) }
    var cameraRemovalReflowActive by remember { mutableStateOf(false) }
    var cameraRemovalAffectedDates by remember { mutableStateOf<Set<String>>(emptySet()) }
    val cameraRemovalScope = rememberCoroutineScope()
    val cameraRemovalEndJob = remember { arrayOfNulls<Job>(1) }
    LaunchedEffect(
        state.files,
        state.isConnectedToCamera,
        state.isLoadingFiles,
        state.hasCompletedFileScan,
    ) {
        val target = state.files
        val canAnimateRemoval = state.isConnectedToCamera &&
            state.hasCompletedFileScan && !state.isLoadingFiles
        val removedDates = if (canAnimateRemoval) {
            publishedCameraRemovalDates(presentedCameraFiles, target)
        } else {
            emptySet()
        }
        if (removedDates.isNotEmpty()) {
            cameraRemovalAffectedDates = cameraRemovalAffectedDates + removedDates
            cameraRemovalReflowActive = true
            // A newer removal owns the animation window immediately. Cancel the previous end timer
            // before yielding a frame so it cannot clear the flags between arming and submission.
            cameraRemovalEndJob[0]?.cancel()
            cameraRemovalEndJob[0] = null
            // The old keys must observe the exit/placement specs before the model drops them.
            withFrameNanos { }
            presentedCameraFiles = target
            cameraRemovalEndJob[0] = cameraRemovalScope.launch {
                delay((CAMERA_REMOVAL_REFLOW_DURATION_MS + 48).toLong())
                cameraRemovalReflowActive = false
                cameraRemovalAffectedDates = emptySet()
                cameraRemovalEndJob[0] = null
            }
        } else {
            presentedCameraFiles = target
            if (!canAnimateRemoval) {
                cameraRemovalEndJob[0]?.cancel()
                cameraRemovalEndJob[0] = null
                cameraRemovalReflowActive = false
                cameraRemovalAffectedDates = emptySet()
            }
        }
    }
    val colors = AppTheme.colors
    // 设置以轻量面板呈现（点击左上角 "Z传" 打开），不再跳转独立页面。
    var showSettings by remember { mutableStateOf(false) }
    var transferDirectoryAttention by remember { mutableStateOf(false) }
    // 双 Z 标按钮在根坐标系中的边界：设置面板贴其下缘展开（下拉弹窗），并以其中心为动画原点。
    var zAnchor by remember { mutableStateOf<Rect?>(null) }
    // 高级版烟花彩蛋：设置面板里的"高级版"徽标点击时在本页放烟花（与连接页共用实现）。
    val fireworks = rememberFireworksState()
    // "整组吸入"动画：飞行中的卡片摞可并发多摞；终点、押扣和胶囊接住回弹
    // 由照片页与传输页共同的顶部队列控件持有，切页不会重建胶囊。
    val queueFlights = remember { mutableStateListOf<QueueFlight>() }
    var nextFlightId by remember { mutableStateOf(0L) }
    // 根坐标每次布局直接写普通容器；只有首次可用时发布一次状态，避免页面滑动转场期间
    // boundsInRoot 的位置变化反复重组整张照片页。
    val pageBoundsRef = remember { arrayOfNulls<Rect>(1) }
    var pageLayoutReady by remember { mutableStateOf(false) }
    val latestQueueFlightsCancelled by rememberUpdatedState(onQueueFlightsCancelled)
    DisposableEffect(queueFlights) {
        onDispose {
            val abandonedCount = queueFlights.sumOf { flight ->
                if (flight.holdsQueueCount) flight.count else 0
            }
            if (abandonedCount > 0) latestQueueFlightsCancelled(abandonedCount)
        }
    }
    // 每个格子在根坐标系的精确 bounds(格子本就为长按预览挂了 onGloballyPositioned,
    // 顺手写进注册表,零额外监听)。普通 HashMap 而非快照状态:只在点击瞬间读取,
    // 滚动期间的高频写入不触发任何重组；格子离开组合时主动删除，容量只随组合项数量增长。
    val cellBoundsRegistry = remember { HashMap<Int, Rect>() }
    // 折叠连拍是虚拟格位，没有单个 handle 的 ThumbnailCell；单独按稳定 burst id 记录，
    // 自动传输才能在合集确实可见时从合集本身起飞，而不是误用“屏外新增”的顶部起点。
    val burstBoundsRegistry = remember { HashMap<String, Rect>() }
    // 类型筛选下拉：开关 + 筛选按钮在根坐标系中的边界（面板贴其下缘展开）。
    var showFilter by remember { mutableStateOf(false) }
    var filterAnchor by remember { mutableStateOf<Rect?>(null) }
    // 弹出时冻结点击瞬间的有效坐标；顶栏随后因信号胶囊等重排也不再拖着面板跳动。
    var openedFilterAnchor by remember { mutableStateOf<Rect?>(null) }
    // 网格滚动状态提升到页面层供回顶按钮使用，但不能跨“列表被连接流程清空”保留。
    // 用空/非空作为状态槽身份：新连接的第一批照片会自然拿到全新的 0 位置状态；
    // 普通重组、继续分批加载以及离开子页面再返回都仍复用当前状态。
    val gridState = key(presentedCameraFiles.isEmpty() && !cameraRemovalReflowActive) {
        rememberLazyGridState()
    }
    val scrollScope = rememberCoroutineScope()
    val previewDensity = LocalDensity.current
    // 提升到页面层：关闭预览前需要用同一份折叠状态定位照片所在的真实 LazyGrid 下标。
    val collapsedDates = remember { mutableStateMapOf<String, Boolean>() }
    val atTop by remember {
        derivedStateOf {
            gridState.firstVisibleItemIndex == 0 && gridState.firstVisibleItemScrollOffset < 8
        }
    }
    // 监看入口离开顶部后缩进左侧；用户点开后保持完整，继续滚动或回到顶部时重置手动状态。
    var remoteExpandedAwayFromTop by remember { mutableStateOf(false) }
    // 同一照片列表导航实例只尝试一次；跨启动累计播放六次后永久停止自动展开。
    val remoteIntroEligible = remember(transferViewModel) {
        transferViewModel.shouldShowRemoteEntryIntro()
    }
    var remoteIntroHandledForEntry by rememberSaveable { mutableStateOf(false) }
    var remoteIntroExpanded by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        if (!remoteIntroHandledForEntry && remoteIntroEligible) {
            // 避开页面自身的入场首帧，让入口像随后自然舒展开，而不是同时抢动画焦点。
            delay(160)
            // 用户已经开始浏览照片时不再强行展开，避免引导态覆盖“离开顶部即收起”的规则。
            if (!atTop) return@LaunchedEffect
            // 真正开始展开时再记次数；此前离页既不消耗次数，回来也仍有机会看到提示。
            remoteIntroHandledForEntry = true
            transferViewModel.recordRemoteEntryIntroPlayed()
            remoteIntroExpanded = true
            delay(2200)
            remoteIntroExpanded = false
        }
    }
    LaunchedEffect(atTop) {
        if (atTop) remoteExpandedAwayFromTop = false
    }
    LaunchedEffect(atTop, gridState.isScrollInProgress) {
        if (!atTop && gridState.isScrollInProgress) {
            // 首次提示也必须服从真实滚动：一旦离开顶部，立即恢复贴边收起态。
            remoteIntroExpanded = false
            remoteExpandedAwayFromTop = false
        }
    }
    // 回到顶部按钮的可见性：翻得够深 + 正向顶部方向滚动才出现；往深处翻/接近顶部
    // 立即隐藏；停止滚动一段时间后自动隐藏——静止画面上没有按钮，误触窗口极小。
    var showBackTop by remember { mutableStateOf(false) }
    // 点击回顶后的程序化滚动本身也是"向顶部移动"，会把按钮再次触发出来闪一下——
    // 返回期间抑制显示。
    var returningToTop by remember { mutableStateOf(false) }
    LaunchedEffect(gridState) {
        var lastIndex = gridState.firstVisibleItemIndex
        var lastOffset = gridState.firstVisibleItemScrollOffset
        snapshotFlow { gridState.firstVisibleItemIndex to gridState.firstVisibleItemScrollOffset }
            .collect { (index, offset) ->
                val towardTop = index < lastIndex ||
                        (index == lastIndex && offset < lastOffset - 4)
                val towardBottom = index > lastIndex ||
                        (index == lastIndex && offset > lastOffset + 4)
                val deep = index >= BACK_TO_TOP_MIN_INDEX
                when {
                    towardTop && deep && !returningToTop -> showBackTop = true
                    towardBottom || !deep -> showBackTop = false
                }
                if ((towardTop || towardBottom) && !(index == 0 && offset < 8)) {
                    remoteExpandedAwayFromTop = false
                }
                lastIndex = index
                lastOffset = offset
            }
    }
    LaunchedEffect(showBackTop, gridState.isScrollInProgress) {
        if (showBackTop && !gridState.isScrollInProgress) {
            delay(1800)
            showBackTop = false
        }
    }

    // 底部玻璃提示条（通用）：退出确认、"相机未连接"等复用，替代系统 Toast。
    // hintText 在淡出期间保留，避免退场动画里文字先消失；nonce 保证连续触发重启计时。
    var hintText by remember { mutableStateOf("") }
    var hintVisible by remember { mutableStateOf(false) }
    var hintNonce by remember { mutableStateOf(0) }
    val showHint: (String) -> Unit = { text ->
        hintText = text
        hintVisible = true
        hintNonce++
    }
    LaunchedEffect(hintNonce) {
        if (hintVisible) {
            delay(1800)
            hintVisible = false
        }
    }
    // 断开时点击缩略图/整组按钮：信号按钮放大缩回强调一下，配合提示条指向"病因"。
    var signalPulse by remember { mutableStateOf(0) }
    val notConnectedHint = stringResource(R.string.camera_not_connected)
    val transferDirectoryRequiredHint = stringResource(R.string.transfer_directory_required_hint)
    // 免费版监看时长用完的引导（指向设置里的"高级版"入口），轻提示不打断。
    val remoteEndedHint = stringResource(R.string.remote_trial_ended)
    // 带参数的文案组合期取不到,回调/协程里经 context.getString 现取;返回键退出也用它。
    val context = LocalContext.current
    val requestTransferDirectory: () -> Unit = {
        transferDirectoryAttention = true
        showSettings = true
        showHint(transferDirectoryRequiredHint)
    }

    // 监看时长归零自动退回本页:落地后弹提示气泡（监看页已消失，提示只能显示在这里）。
    // 本页在去监看页时离开组合、返回时重新进入，LaunchedEffect(Unit) 恰好每次落地都跑。
    LaunchedEffect(Unit) {
        if (RemoteTrialNotice.pending) {
            RemoteTrialNotice.pending = false
            showHint(remoteEndedHint)
        }
    }

    // 额度预警:订阅"传输完成计数"流,每完成一个(+1 之后)在临近上限时提示最新剩余——
    // 提示与计数同源,失败/跳过不触发。drop(1) 跳过订阅时的当前值,只对新完成反应。
    LaunchedEffect(Unit) {
        LicenseManager.quotaLeft.drop(1).collect { left ->
            if (left in 1..5) {
                showHint(
                    context.getString(
                        R.string.quota_left_hint,
                        left, LicenseManager.FREE_DAILY_TRANSFER_LIMIT
                    )
                )
            }
        }
    }

    // 照片列表是连接成功后的主工作页：系统返回不能走 NavHost 默认 popBackStack，
    // 否则会把用户带回连接页。这里必须保留页内拦截，并复用宿主的全局二次退出确认；
    // 队列页打开时交给 TransferScreen，筛选/预览等更深层的 BackHandler 仍优先消费。
    BackHandler(
        enabled = backHandlerEnabled,
        onBack = onRequestExitConfirmation,
    )
    // 筛选浮层的返回键收起由 FilterOverlay 内部（AnchorPopup 的 BackHandler）处理。

    val topInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val bottomInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    // 列表内容内边距：顶部让出状态栏 + 悬浮控件高度；底部让出导航栏。内容本身 edge-to-edge。
    val listPadding = PaddingValues(
        start = 12.dp,
        end = 12.dp,
        top = topInset + 60.dp,
        bottom = bottomInset + 12.dp
    )

    // 筛选（类型/保护/连拍/未传输/卡槽/日期）：纯前端过滤——原始 state.files 不动、不触发重新读取；
    // 预览翻页/分组/网格全部基于过滤后的数据，自然一致。
    //（曾有"横竖构图"筛选,已摘除:ObjectInfo 的宽高是传感器原生方向,竖拍的方向
    // 只在 EXIF Orientation 里且依赖机内"自动旋转图像"设置——ObjectInfo 这条路
    // 判不出构图。将来若做,走 EXIF 头懒采集 + 磁盘缓存,可顺带修显示旋转。）
    val filterExts = transferState.filterExtensions
    val filterProtected = transferState.filterProtectedOnly
    val filterBurst = transferState.filterBurstOnly
    val filterUntransferred = transferState.filterUntransferredOnly
    val filterStorageSlot = transferState.filterStorageSlot
    val filterDateRange = transferState.filterDateRange
    val storageIdBySlot = remember(state.storageIds) { storageIdsBySlot(state.storageIds) }
    val visibleStorageSlots = remember(storageIdBySlot) {
        storageFilterSlots(storageIdBySlot.keys)
    }
    val selectedStorageIds = filterStorageSlot?.let(storageIdBySlot::get)
    val filterCriteria = remember(
        filterExts,
        filterProtected,
        filterBurst,
        filterUntransferred,
        filterStorageSlot,
        filterDateRange,
    ) {
        PhotoFilterCriteria(
            extensions = filterExts,
            protectedOnly = filterProtected,
            burstOnly = filterBurst,
            untransferredOnly = filterUntransferred,
            storageSlot = filterStorageSlot,
            dateRange = filterDateRange,
        )
    }
    val filterActive = filterExts != null || filterProtected || filterBurst ||
        filterUntransferred || filterStorageSlot != null || filterDateRange != null

    // 扫描途中保留当前选择；完整扫描后只有确认存在双卡才允许卡槽筛选。
    // 单卡时筛选没有意义，归回“全部”也能保证入口按钮不会卡在激活状态。
    LaunchedEffect(state.hasCompletedFileScan, visibleStorageSlots, filterStorageSlot) {
        val normalized = normalizeStorageSlotFilter(
            selectedSlot = filterStorageSlot,
            availableSlots = visibleStorageSlots,
            hasCompletedFileScan = state.hasCompletedFileScan,
        )
        if (normalized != filterStorageSlot) {
            transferViewModel.setFilters(filterCriteria.copy(storageSlot = normalized))
        }
    }
    // 筛选确定后的级联入场（复用分组展开的入场动画）：tick 每次确定递增（重播存量格子）,
    // window 开 600ms（窗口内组成的格子播入场,之后滚动进入的不播——与 recentlyExpanded 同构）。
    var filterRevealTick by remember { mutableStateOf(0) }
    var filterRevealWindow by remember { mutableStateOf(false) }
    LaunchedEffect(filterRevealTick) {
        if (filterRevealTick > 0) {
            delay(600)
            filterRevealWindow = false
        }
    }
    // 设备上实际存在的类型（从未过滤的原始列表提取，供下拉选项自动生成）。
    val availableExts = remember(presentedCameraFiles) {
        presentedCameraFiles.map { it.extension }.distinct().sorted()
    }
    val latestKnownDate = remember(presentedCameraFiles) {
        latestCaptureLocalDate(presentedCameraFiles.asSequence().map { it.captureDate })
    }
    // 连拍检测基于原始列表，只在文件列表变化时重算。角标、筛选和合集都共享这一份
    // 结果，避免三个功能对“哪些照片属于连拍”产生分歧。
    val burstGroups = remember(presentedCameraFiles) {
        computeBurstGroups(presentedCameraFiles)
    }
    val burstHandles = remember(burstGroups) {
        burstGroups.flatMapTo(HashSet()) { group -> group.files.map { it.handle } }
    }
    val burstIdByHandle = remember(burstGroups) {
        buildMap {
            burstGroups.forEach { group ->
                group.files.forEach { file -> put(file.handle, group.id) }
            }
        }
    }
    // 已传对号与“未传输”筛选必须共用这一个判定，避免界面同时出现
    // “带对号却仍在未传输列表”的自相矛盾。
    val exportedHandlesForFilter: Set<Int> = remember(
        presentedCameraFiles,
        transferState.existingExportRevision,
        transferState.organizeTransfersByDate,
        filterUntransferred,
    ) {
        exportedHandlesForUntransferredFilter(
            files = presentedCameraFiles,
            index = transferState.existingExportIndex,
            organizeTransfersByDate = transferState.organizeTransfersByDate,
            enabled = filterUntransferred,
        )
    }
    // “未传输”筛选下，本次队列刚完成的照片先留在网格中播放单格退场，再真正加入过滤集合。
    // 导出目录扫描发现的历史文件不需要动画，仍然同步过滤，避免列表初次加载时闪现旧照片。
    val animatedExportCandidates = remember(transferState.tasks, filterUntransferred) {
        if (filterUntransferred) {
            transferState.tasks.asSequence()
                .filter {
                    it.status == TransferStatus.WAITING ||
                        it.status == TransferStatus.TRANSFERING ||
                        it.status == TransferStatus.COMPLETED
                }
                .mapTo(HashSet()) { it.file.handle }
        } else {
            emptySet()
        }
    }
    var finishedExportExitHandles by remember(filterUntransferred) {
        mutableStateOf(exportedHandlesForFilter.intersect(animatedExportCandidates))
    }
    val exitingExportHandles = remember { mutableStateMapOf<Int, Unit>() }
    var exportReflowActive by remember { mutableStateOf(false) }
    var exportReflowTick by remember { mutableStateOf(0) }
    val filteredExportHandles = remember(
        exportedHandlesForFilter,
        animatedExportCandidates,
        finishedExportExitHandles
    ) {
        if (filterUntransferred) {
            (exportedHandlesForFilter - animatedExportCandidates) + finishedExportExitHandles
        } else {
            emptySet()
        }
    }

    LaunchedEffect(exportedHandlesForFilter, animatedExportCandidates, filterUntransferred) {
        finishedExportExitHandles = finishedExportExitHandles.intersect(exportedHandlesForFilter)
        exitingExportHandles.keys
            .filterNot { it in exportedHandlesForFilter }
            .forEach(exitingExportHandles::remove)

        if (!filterUntransferred) {
            // 筛选未开启时没有退场语义，也不保留任何已传 handle 集合。
            exitingExportHandles.clear()
            finishedExportExitHandles = emptySet()
            exportReflowActive = false
        } else {
            val newlyExported = exportedHandlesForFilter
                .intersect(animatedExportCandidates)
                .minus(finishedExportExitHandles)
                .minus(exitingExportHandles.keys)
            if (newlyExported.isNotEmpty()) {
                newlyExported.forEach { exitingExportHandles[it] = Unit }
                // 在条目真正移除前启用 placement modifier，让 LazyGrid 已经持有旧位置。
                exportReflowActive = true
            }
        }
    }
    LaunchedEffect(exportReflowTick) {
        if (exportReflowTick > 0) {
            delay(320)
            if (exitingExportHandles.isEmpty()) exportReflowActive = false
        }
    }
    // 分组 / 扁平列表（供长按预览翻页）/ 传输忙碌（缩略图让路）——提到顶层，供内容区与预览层共用。
    val groups = remember(
        presentedCameraFiles, filterExts, filterProtected, filterBurst, filterUntransferred,
        filterStorageSlot, selectedStorageIds, filterDateRange,
        burstHandles, filteredExportHandles
    ) {
        val files = filterCameraFiles(
            files = presentedCameraFiles,
            criteria = CameraFileFilter(
                extensions = filterExts,
                protectedOnly = filterProtected,
                burstOnly = filterBurst,
                untransferredOnly = filterUntransferred,
                selectedStorageIds = if (filterStorageSlot == null) {
                    null
                } else {
                    selectedStorageIds.orEmpty()
                },
                dateRange = filterDateRange?.captureDayRange,
            ),
            burstHandles = burstHandles,
            transferredHandles = filteredExportHandles,
        )
        groupFilesByDate(files)
    }
    LaunchedEffect(presentedCameraFiles) {
        // Filters temporarily hide complete date groups; that must not erase the user's collapsed
        // choices. Only camera rows actually disappearing make a remembered date stale.
        val validDates = presentedCameraFiles
            .mapTo(HashSet()) { it.captureDate?.take(8) ?: UNKNOWN_DATE_KEY }
        collapsedDates.keys
            .filterNot { it in validDates }
            .forEach(collapsedDates::remove)
    }
    // 列表与预览共享同一份“合集是否展开”状态。预览页主动展开后，关闭预览仍能看到
    // 底层列表已展开；反之亦然。合集关闭设置时，模型退化为原来的纯照片序列。
    val expandedBurstCollections = remember { mutableStateMapOf<String, Boolean>() }
    // Only burst-id reconciliation reads this history; a plain holder avoids a redundant
    // recomposition after recording the latest groups.
    val previousBurstGroups = remember { arrayOf(burstGroups) }
    val requestedExpandedBurstIds = expandedBurstCollections.keys.toSet()
    val expandedBurstIds = remember(
        transferState.collapseBurstPhotos,
        burstGroups,
        requestedExpandedBurstIds,
    ) {
        if (transferState.collapseBurstPhotos) {
            reconciledExpandedBurstIds(
                previousGroups = previousBurstGroups[0],
                currentGroups = burstGroups,
                expandedIds = requestedExpandedBurstIds,
            )
        } else {
            emptySet()
        }
    }
    LaunchedEffect(transferState.collapseBurstPhotos, burstGroups, expandedBurstIds) {
        expandedBurstCollections.keys
            .filterNot { it in expandedBurstIds }
            .forEach(expandedBurstCollections::remove)
        expandedBurstIds
            .filterNot { expandedBurstCollections[it] == true }
            .forEach { id -> expandedBurstCollections[id] = true }
        previousBurstGroups[0] = burstGroups
    }
    // 该状态表只保存 true，收起时直接 remove；无需再构造 filterValues 视图。
    // 只用一个轻量身份对象追踪“底层展示模型是否还是打开预览时那一版”；真正的预览
    // 分页列表仅在长按发生时构建，避免每次连拍展开都为尚未打开的预览额外扫描全表。
    val previewSourceIdentity = remember(
        groups, burstIdByHandle, transferState.collapseBurstPhotos, expandedBurstIds
    ) { Any() }
    val currentPreviewSourceIdentity by rememberUpdatedState(previewSourceIdentity)
    // 只有实际传输会占用相机通道；暂停后的 WAITING 队列不影响监看入口。
    val transfersBusy = transferState.isTransferring
    // 队列限制即时生效；视觉压暗稍后确认，过滤瞬时传输产生的单帧闪烁。
    var transfersBusyVisual by remember { mutableStateOf(false) }
    LaunchedEffect(transfersBusy) {
        if (transfersBusy) {
            delay(REMOTE_BUSY_VISUAL_DELAY_MS)
            transfersBusyVisual = true
        } else {
            transfersBusyVisual = false
        }
    }
    // 触感反馈（开关在设置里，默认开）。
    val haptics = rememberHaptics(transferState.hapticsEnabled)

    // 长按预览：全屏翻页 + 从被长按格子的位置放大展开。
    var previewIndex by remember { mutableStateOf<Int?>(null) }
    val latestPreviewVisibilityChanged by rememberUpdatedState(onPreviewVisibilityChanged)
    val updatePreviewIndex: (Int?) -> Unit = { nextIndex ->
        previewIndex = nextIndex
        latestPreviewVisibilityChanged(nextIndex != null)
    }
    DisposableEffect(Unit) {
        onDispose { latestPreviewVisibilityChanged(false) }
    }
    var previewAnchor by remember { mutableStateOf<Rect?>(null) }
    var previewSourceAtOpen by remember { mutableStateOf<Any?>(null) }
    var previewBuildJob by remember { mutableStateOf<Job?>(null) }
    var previewReturnHandle by remember { mutableStateOf<Int?>(null) }
    var previewReturnNonce by remember { mutableStateOf(0) }
    // 预览会话固定为打开瞬间的展示模型。“未传输”激活时，当前照片在
    // 后台传完会从网格派生列表移除；若预览仍直接引用实时模型，固定下标会
    // 突然指向下一张，末尾项还会直接让 overlay 消失。快照保证当次浏览稳定，
    // 关闭后底下列表已是最新筛选结果。
    var previewItems by remember { mutableStateOf<List<PhotoPreviewItem>>(emptyList()) }

    // 自动传输已经在共同宿主完成真实入队，这里只补视觉反馈：若新文件正在视口内，
    // 从它的真实格位起飞；否则从列表顶部边缘凝聚出来。绝不擅自滚回顶部，也不押扣
    // 已经实时变化的队列数字。预览或队列页挡在上层时请求留在宿主，等照片页可见再消费。
    LaunchedEffect(
        autoQueueFlightRequest?.id,
        previewIndex,
        queueTargetBounds,
        pageLayoutReady,
    ) {
        val request = autoQueueFlightRequest ?: return@LaunchedEffect
        if (cameraViewModel.getCamera() !== request.camera) {
            // 切换相机后旧批次仍留在真实队列，但不能伪装成从新相机的照片列表飞出。
            onAutoQueueFlightConsumed(request.id)
            return@LaunchedEffect
        }
        if (previewIndex != null || queueTargetBounds == null || !pageLayoutReady) {
            return@LaunchedEffect
        }
        // CameraViewModel 先发布文件列表再发新增事件；再让出两帧，给新格位完成测量。
        withFrameNanos { }
        withFrameNanos { }
        val visibleKeys = gridState.layoutInfo.visibleItemsInfo
            .mapTo(HashSet()) { it.key }
        val visibleSource = resolveAutoQueueFlightSource(
            files = request.files,
            visibleKeys = visibleKeys,
            cellBoundsByHandle = cellBoundsRegistry,
            burstBoundsById = burstBoundsRegistry,
            burstIdByHandle = burstIdByHandle,
        )
        val root = pageBoundsRef[0] ?: return@LaunchedEffect
        val originSize = with(previewDensity) { 44.dp.toPx() }
        val topEdgeSource = Rect(
            left = root.center.x - originSize / 2f,
            top = root.top + with(previewDensity) { (topInset + 62.dp).toPx() },
            right = root.center.x + originSize / 2f,
            bottom = root.top + with(previewDensity) { (topInset + 62.dp).toPx() } + originSize,
        )
        queueFlights += QueueFlight(
            id = nextFlightId++,
            from = visibleSource ?: topEdgeSource,
            packs = emptyList(),
            count = request.files.size,
            topThumb = request.files.firstNotNullOfOrNull { file ->
                cameraViewModel.cachedThumbnail(file.handle)
            },
            holdsQueueCount = false,
        )
        onAutoQueueFlightConsumed(request.id)
    }
    val buildPreviewSnapshot: (Set<String>) -> List<PhotoPreviewItem> = { expandedIds ->
        groups.flatMap { group ->
            buildThumbnailGridItems(
                files = group.files,
                burstIdByHandle = burstIdByHandle,
                collapseBurstPhotos = transferState.collapseBurstPhotos,
                expandedBurstIds = expandedIds
            ).map { item ->
                when (item) {
                    is ThumbnailGridItem.Photo ->
                        PhotoPreviewItem.Photo(item.file, item.burstId)
                    is ThumbnailGridItem.BurstCollection ->
                        PhotoPreviewItem.BurstCollection(item.id, item.files)
                }
            }
        }
    }
    val onPreview: (NikonCamera.FileInfo, Rect) -> Unit = { file, rect ->
        // 几千张照片时构建分页快照会产生一批临时集合；不要把这段 O(n) 工作塞在
        // 长按手势的主线程回调里，否则动画第一帧会被推迟甚至直接错过。
        haptics.longPress()
        val sourceAtOpen = previewSourceIdentity
        val expandedAtOpen = expandedBurstIds
        previewBuildJob?.cancel()
        previewBuildJob = scrollScope.launch {
            val snapshot = withContext(Dispatchers.Default) {
                buildPreviewSnapshot(expandedAtOpen)
            }
            val idx = snapshot.indexOfFirst {
                it is PhotoPreviewItem.Photo && it.file.handle == file.handle
            }
            if (idx >= 0 && currentPreviewSourceIdentity === sourceAtOpen) {
                previewItems = snapshot
                updatePreviewIndex(idx)
                previewAnchor = rect
                previewSourceAtOpen = sourceAtOpen
            }
        }
    }
    val onPreviewBurst: (String, List<NikonCamera.FileInfo>, Rect) -> Unit =
        onPreviewBurst@{ burstId, files, rect ->
            val first = files.firstOrNull() ?: return@onPreviewBurst
            // 快照直接包含目标成员并落到第一张；长按不提前改变底层网格，避免预览层
            // 挂载前露出合集重排/箭头旋转。退出成员预览时会在黑幕下无感展开底层合集。
            haptics.longPress()
            val sourceAtOpen = previewSourceIdentity
            val expandedAtOpen = expandedBurstIds + burstId
            previewBuildJob?.cancel()
            previewBuildJob = scrollScope.launch {
                val snapshot = withContext(Dispatchers.Default) {
                    buildPreviewSnapshot(expandedAtOpen)
                }
                val idx = snapshot.indexOfFirst {
                    it is PhotoPreviewItem.Photo && it.file.handle == first.handle
                }
                if (idx >= 0 && currentPreviewSourceIdentity === sourceAtOpen) {
                    previewItems = snapshot
                    updatePreviewIndex(idx)
                    previewAnchor = rect
                    previewSourceAtOpen = sourceAtOpen
                }
            }
        }

    // 任务状态变化只替换原列表元素，handle -> 下标结构不变；仅在增删/重试时重建一次。
    val queuedIndexByHandle = remember(
        transferViewModel,
        transferState.taskStructureRevision,
    ) {
        buildLatestTaskIndexByHandle(transferState.tasks)
    }
    val hasLocalOriginal: (NikonCamera.FileInfo) -> Boolean = { file ->
        isTransferredOriginal(
            file,
            transferState.existingExportIndex,
            transferState.organizeTransfersByDate,
        )
    }
    // 单文件入队共用同一套前置检查与任务创建；只有动画按操作来源分流：列表继续
    // QueueFlight，预览页由自己的上滑投递动画反馈，不能隔着遮罩再飞一次底层格子。
    val enqueueSingleFile: (NikonCamera.FileInfo, Boolean) -> Boolean =
        enqueueSingleFile@{ file, animateFromList ->
            if (transferState.transferDirUri == null) {
                // 预览层盖在设置面板之上，先关掉预览再弹设置，否则用户看不见。
                updatePreviewIndex(null)
                previewItems = emptyList()
                previewSourceAtOpen = null
                requestTransferDirectory()
                return@enqueueSingleFile false
            }
            if (!state.isConnectedToCamera && !hasLocalOriginal(file)) {
                signalPulse++
                showHint(notConnectedHint)
                false
            } else {
                haptics.tick()
                transferViewModel.addToQueue(listOf(file), cameraViewModel::getCamera)
                if (animateFromList) {
                    // 单张"吸入":缩略图从格子位置起飞(count=1 → 单卡无叠影),
                    // 同一条弧线进胶囊。预览来源明确不走这里。
                    val fromCell = cellBoundsRegistry[file.handle]
                    // 同源去重:同帧双击防重复残影。
                    if (fromCell != null && queueFlights.none { it.from == fromCell }) {
                        queueFlights += QueueFlight(
                            id = nextFlightId++, from = fromCell,
                            packs = emptyList(), count = 1,
                            topThumb = cameraViewModel.cachedThumbnail(file.handle)
                        )
                        onQueueFlightStarted(1)
                    }
                }
                true
            }
        }
    val onTapFile: (NikonCamera.FileInfo) -> Unit = { file ->
        enqueueSingleFile(file, true)
    }
    val onTransferFromPreview: (NikonCamera.FileInfo) -> Boolean = { file ->
        enqueueSingleFile(file, false)
    }

    val onTransferBurstPreview: (List<NikonCamera.FileInfo>) -> Boolean =
        onTransferBurstPreview@{ files ->
            val remaining = files
            if (remaining.isEmpty()) return@onTransferBurstPreview false
            if (transferState.transferDirUri == null) {
                updatePreviewIndex(null)
                previewItems = emptyList()
                previewSourceAtOpen = null
                requestTransferDirectory()
                return@onTransferBurstPreview false
            }
            if (!state.isConnectedToCamera && remaining.any { !hasLocalOriginal(it) }) {
                signalPulse++
                showHint(notConnectedHint)
                return@onTransferBurstPreview false
            }
            // 整组只震一次；返回 true 后由预览层复用当前合集叠片播放入队动画。
            haptics.tick()
            transferViewModel.addToQueue(remaining, cameraViewModel::getCamera)
            true
        }

    // 关闭预览前把当前照片放回视野。很远时先在全黑预览层后无感预定位到相邻几行，
    // 再走 LazyGrid 自身的短程平滑滚动；这样不会让框架为性能做的长距离跳段暴露出来。
    val preparePreviewDismissTarget: suspend (NikonCamera.FileInfo) -> Rect? =
        prepare@{ file ->
            val groupsSnapshot = groups
            val stillInCurrentResults = withContext(Dispatchers.Default) {
                groupsSnapshot.any { group ->
                    group.files.any { it.handle == file.handle }
                }
            }
            // 预览期间可能因“未传输”等筛选条件自动移出当前照片。此时既不乱滚，
            // 也不为了一个已不可见目标擅自展开连拍合集，直接使用原地淡出。
            if (!stillInCurrentResults) return@prepare null

            // 当前照片若来自折叠连拍，底层只有合集封面、没有 A 自己的格子。先在黑幕下
            // 展开该合集，确保后续缩回和双脉冲都落在 A，而不是误指合集封面。
            val returnBurstId = burstIdByHandle[file.handle]
            if (transferState.collapseBurstPhotos && returnBurstId != null &&
                expandedBurstCollections[returnBurstId] != true
            ) {
                expandedBurstCollections[returnBurstId] = true
                withFrameNanos { }
            }
            val alreadyVisible = gridState.layoutInfo.visibleItemsInfo.any {
                it.key == file.handle
            }
            if (!alreadyVisible) {
                // 只在关闭时计算一次，且把可能有几千项的纯模型扫描移出主线程。
                val collapsedSnapshot = collapsedDates.filterValues { it }.keys
                val burstIdsSnapshot = expandedBurstCollections.keys.toSet()
                val collapseBursts = transferState.collapseBurstPhotos
                val target = withContext(Dispatchers.Default) {
                    var lazyIndex = 0
                    var found: Int? = null
                    for (group in groupsSnapshot) {
                        lazyIndex += 1 // 日期标题
                        if (group.date in collapsedSnapshot) continue
                        val groupItems = buildThumbnailGridItems(
                            files = group.files,
                            burstIdByHandle = burstIdByHandle,
                            collapseBurstPhotos = collapseBursts,
                            expandedBurstIds = burstIdsSnapshot,
                        )
                        for (item in groupItems) {
                            if (item is ThumbnailGridItem.Photo && item.file.handle == file.handle) {
                                found = lazyIndex
                                break
                            }
                            lazyIndex += 1
                        }
                        if (found != null) break
                    }
                    found
                }
                target ?: return@prepare null
                val current = gridState.firstVisibleItemIndex
                val runway = transferState.thumbnailColumns.coerceIn(1, 4) * 3
                if (abs(target - current) > runway * 2) {
                    val nearby = if (target > current) {
                        (target - runway).coerceAtLeast(0)
                    } else {
                        target + runway
                    }
                    gridState.scrollToItem(nearby)
                    withFrameNanos { }
                }
                // 目标最终停在顶栏下方一段舒适留白处，而非生硬贴住屏幕顶边。
                gridState.animateScrollToItem(
                    index = target,
                    scrollOffset = -with(previewDensity) { 88.dp.roundToPx() },
                )
                withFrameNanos { }
            }
            // 等一帧让 onGloballyPositioned 注册最新根坐标；找不到就退化为原地淡出。
            withFrameNanos { }
            cellBoundsRegistry[file.handle]
        }

    // 根需不透明底色：与队列页左右滑动转场期间两页同屏层叠，透明根会让底层页面透出。
    // 与 Scaffold 共用全局背景刷（浅色纯色/深色微渐变）。
    // 遥控页入口是左下角圆钮（曾试过横滑手势进入，误触率高已去掉）。
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(rememberAppBackgroundBrush())
            .onGloballyPositioned {
                pageBoundsRef[0] = it.boundsInRoot()
                if (!pageLayoutReady) pageLayoutReady = true
            }
    ) {
        // ---------- 内容（铺满，延伸到系统栏后面）----------
        if (state.isLoadingFiles && presentedCameraFiles.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(color = colors.accentBlue)
                    Spacer(modifier = Modifier.height(16.dp))
                    Text(stringResource(R.string.loading_file_list), color = colors.onSurfaceVariant)
                }
            }
        }

        if (!state.isLoadingFiles && presentedCameraFiles.isEmpty() &&
            !cameraRemovalReflowActive &&
            (state.hasCompletedFileScan || !state.isConnectedToCamera)
        ) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.padding(horizontal = 32.dp)
                ) {
                    if (!state.isConnectedToCamera) {
                        // 兜底：断开且列表从未加载成功（掉线不再清列表，正常断开时网格保留、
                        // 由顶栏信号按钮指示状态，不会走到这里）。提示与本次会话的传输方式
                        // 绑定，避免 USB 相机关机时短暂闪出 Wi-Fi 文案和系统设置按钮。
                        val usbMode =
                            disconnectedConnectionType(state.connectionType) ==
                                CameraConnectionType.USB
                        if (usbMode) {
                            ClassicUsbIcon(
                                tint = colors.accentOrange,
                                modifier = Modifier.size(64.dp)
                            )
                        } else {
                            Icon(
                                Icons.Default.WifiOff,
                                contentDescription = null,
                                modifier = Modifier.size(64.dp),
                                tint = colors.accentOrange
                            )
                        }
                        Spacer(modifier = Modifier.height(16.dp))
                        Text(
                            stringResource(
                                if (usbMode) {
                                    R.string.usb_connection_lost
                                } else {
                                    R.string.connection_lost
                                }
                            ),
                            color = colors.onBackground,
                            style = MaterialTheme.typography.titleMedium
                        )
                        Spacer(modifier = Modifier.height(6.dp))
                        Text(
                            stringResource(
                                if (usbMode) {
                                    R.string.reconnect_camera_usb
                                } else {
                                    R.string.connect_camera_wifi
                                }
                            ),
                            color = colors.onSurfaceVariant,
                            style = MaterialTheme.typography.bodySmall,
                            textAlign = TextAlign.Center
                        )
                        // 一键直达系统 Wi-Fi 设置（与连接页同款按钮），不必退回连接页。
                        if (!usbMode) {
                            Spacer(modifier = Modifier.height(20.dp))
                            GlassButton(
                                onClick = {
                                    try {
                                        context.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                                    } catch (_: Exception) {}
                                }
                            ) {
                                Icon(Icons.Default.Wifi, contentDescription = null, tint = colors.accentBlue, modifier = Modifier.size(20.dp))
                                Text(
                                    stringResource(R.string.open_wifi_settings),
                                    style = MaterialTheme.typography.labelLarge,
                                    fontWeight = FontWeight.Medium,
                                    color = colors.onBackground
                                )
                            }
                        }
                    } else {
                        // 空态缓慢呼吸（与队列页空态同参数）：页面此时无其它动态，不至于死板。
                        val breathe = rememberInfiniteTransition(label = "emptyList")
                        val breatheAlpha by breathe.animateFloat(
                            initialValue = 0.35f, targetValue = 0.6f,
                            animationSpec = infiniteRepeatable(tween(1600), RepeatMode.Reverse),
                            label = "emptyListAlpha"
                        )
                        Icon(
                            Icons.Default.FolderOff, contentDescription = null,
                            modifier = Modifier.size(64.dp),
                            tint = colors.onSurfaceVariant.copy(alpha = breatheAlpha)
                        )
                        Spacer(modifier = Modifier.height(16.dp))
                        Text(stringResource(R.string.no_photos_on_camera), color = colors.onSurfaceVariant)
                        if (state.connectionType == CameraConnectionType.USB) {
                            Spacer(modifier = Modifier.height(6.dp))
                            Text(
                                stringResource(R.string.usb_turn_on_camera_hint),
                                color = colors.onSurfaceVariant,
                                style = MaterialTheme.typography.bodySmall
                            )
                        }
                    }
                }
            }
        }

        if (presentedCameraFiles.isNotEmpty() || cameraRemovalReflowActive) {
            // 分组批量传输。gating 用响应式的 isConnectedToCamera；
            // 队列内部经 provider 现取当前相机实例，中途重连后续传任务自动用新连接。
            // 单文件入队见外层 enqueueSingleFile；这里仅处理日期整组。
            val onTransferGroup: (List<NikonCamera.FileInfo>, Rect?) -> Unit = onTransferGroup@{ remaining, fromBounds ->
                if (transferState.transferDirUri == null) {
                    requestTransferDirectory()
                    return@onTransferGroup
                }
                if (!state.isConnectedToCamera && remaining.any { !hasLocalOriginal(it) }) {
                    // 未连接：信号按钮放大强调 + 提示，而不是静默无响应。
                    signalPulse++
                    showHint(notConnectedHint)
                } else if (remaining.isNotEmpty()) {
                    // 批量对免费版同样开放:额度按"传输完成"计数,超限的任务由队列
                    // 逐个标注"已达上限"卡片(见 TransferViewModel),入队本身不设卡。
                    haptics.tick()   // 整组入队只震一次
                    // 只加入队列、原地继续浏览，不跳转到队列页（想看进度可点右上角胶囊进入）。
                    transferViewModel.addToQueue(remaining, cameraViewModel::getCamera)
                    // 两幕动画:先"打包"(该组可见缩略图的残影错峰汇聚到 + 按钮),
                    // 再"吸入"(成摞飞向右上角队列胶囊)。真正的入队/传输已在上面发生,
                    // 动画纯叙事。可见格子坐标 = 网格根原点 + 视口内偏移;超过上限均匀抽样,
                    // 组收起时一张可见格子也没有,自动只播第二幕。
                    // 同源去重:同帧双击会穿过 remaining 的快照守卫(状态未及重组),
                    // addToQueue 会去重、押扣也对称,但会飞出两摞一样的残影——
                    // 同一起点已有在途飞行就不再放飞。
                    if (fromBounds != null && queueFlights.none { it.from == fromBounds }) {
                        // 起点取注册表里的真实格子 bounds(可见 key 过滤掉滚出屏幕的旧记录),
                        // 顺序即传输顺序——"灵魂"按将要传输的先后依次被吸走;
                        // 每个灵魂带自己格子的缩略图(缓存同步引用,未缓存回退半透明色块)。
                        val visibleKeys = gridState.layoutInfo.visibleItemsInfo
                            .mapNotNullTo(HashSet()) { it.key as? Int }
                        val cells = remaining
                            .filter { it.handle in visibleKeys }
                            .mapNotNull { f ->
                                cellBoundsRegistry[f.handle]?.let {
                                    PackSoul(it, cameraViewModel.cachedThumbnail(f.handle))
                                }
                            }
                        val sampled = if (cells.size <= MAX_PACK_GHOSTS) cells
                            else List(MAX_PACK_GHOSTS) { cells[it * cells.size / MAX_PACK_GHOSTS] }
                        queueFlights += QueueFlight(
                            id = nextFlightId++, from = fromBounds,
                            packs = sampled, count = remaining.size,
                            // 摞顶显示本次传输顺序第一张的缩略图(内存缓存同步引用,
                            // 未缓存则为 null,摞顶回退为纯色+图标)。
                            topThumb = cameraViewModel.cachedThumbnail(remaining.first().handle)
                        )
                        onQueueFlightStarted(remaining.size)
                    }
                }
            }

            // 筛选后无匹配：给出指认原因的空态（原始列表非空，只是被筛掉了）。
            if (filterActive && groups.isEmpty() && state.hasCompletedFileScan &&
                !cameraRemovalReflowActive
            ) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        // 空态缓慢呼吸（与其余空态同参数）。
                        val breathe = rememberInfiniteTransition(label = "emptyFilter")
                        val breatheAlpha by breathe.animateFloat(
                            initialValue = 0.35f, targetValue = 0.6f,
                            animationSpec = infiniteRepeatable(tween(1600), RepeatMode.Reverse),
                            label = "emptyFilterAlpha"
                        )
                        FilterMark(
                            modifier = Modifier.size(44.dp),
                            color = colors.onSurfaceVariant.copy(alpha = breatheAlpha)
                        )
                        Spacer(modifier = Modifier.height(12.dp))
                        Text(stringResource(R.string.no_photos_match_filter), color = colors.onSurfaceVariant)
                        Spacer(modifier = Modifier.height(18.dp))
                        GlassButton(
                            onClick = {
                                // 直接恢复整套默认筛选，不能只清当前可见项；同时丢弃可能
                                // 仍存活的筛选面板草稿，避免旧日期范围随后被再次提交。
                                showFilter = false
                                openedFilterAnchor = null
                                transferViewModel.clearFilters()
                            }
                        ) {
                            Text(
                                text = stringResource(R.string.clear_filters),
                                style = MaterialTheme.typography.labelLarge,
                                fontWeight = FontWeight.Medium,
                                color = colors.onBackground,
                            )
                        }
                    }
                }
            }

            ThumbnailGrid(
                groups = groups,
                tasks = transferState.tasks,
                queuedIndexByHandle = queuedIndexByHandle,
                existingExportIndex = transferState.existingExportIndex,
                existingExportRevision = transferState.existingExportRevision,
                organizeTransfersByDate = transferState.organizeTransfersByDate,
                activeProgressFlow = transferViewModel.activeTransferProgress,
                columns = transferState.thumbnailColumns,
                isLoading = state.isLoadingFiles,
                transfersBusy = transfersBusy,
                allowRemoteThumbnails = allowGridRemoteThumbnails(previewIndex != null),
                collapsedDates = collapsedDates,
                cameraViewModel = cameraViewModel,
                onTransferGroup = onTransferGroup,
                onTapFile = onTapFile,
                onPreview = onPreview,
                onPreviewBurst = onPreviewBurst,
                tapToPreview = transferState.tapToPreview,
                cellBoundsRegistry = cellBoundsRegistry,
                burstBoundsRegistry = burstBoundsRegistry,
                burstHandles = burstHandles,
                burstIdByHandle = burstIdByHandle,
                collapseBurstPhotos = transferState.collapseBurstPhotos,
                expandedBursts = expandedBurstCollections,
                contentPadding = listPadding,
                gridState = gridState,
                filterRevealTick = filterRevealTick,
                filterRevealWindow = filterRevealWindow,
                exitingExportHandles = exitingExportHandles.keys,
                exportReflowActive = exportReflowActive,
                cameraRemovalReflowActive = cameraRemovalReflowActive,
                cameraRemovalAffectedDates = cameraRemovalAffectedDates,
                returnFocusHandle = previewReturnHandle,
                returnFocusNonce = previewReturnNonce,
                onExportExitFinished = { handle ->
                    if (handle in exitingExportHandles) {
                        finishedExportExitHandles = finishedExportExitHandles + handle
                        exitingExportHandles.remove(handle)
                        exportReflowTick++
                    }
                },
                modifier = Modifier.fillMaxSize()
            )
        }

        // ---------- 监看入口（左下角毛玻璃相机钮） ----------
        // 顶部完整显示；离开顶部后沿一条轻微上拱的路径缩进左边，只露出约半颗。
        // 收起态第一次点击只展开，第二次点击才进入监看，避免浏览照片时误触跳页。
        // 传输进行中禁止进入监看：监看要独占相机通道（LV 取帧连续占锁），与下载抢锁会两败俱伤。
        // 图标压暗示意不可用，点击给出提示而非静默无响应。
        val remoteBlockedHint = stringResource(R.string.remote_blocked_transfer)
        val remoteEntryDescription = stringResource(R.string.cd_remote_entry)
        val remoteExpanded = atTop || remoteExpandedAwayFromTop || remoteIntroExpanded
        val remoteReveal = animateFloatAsState(
            targetValue = if (remoteExpanded) 1f else 0f,
            animationSpec = spring(dampingRatio = 0.58f, stiffness = 360f),
            label = "remoteEntryReveal"
        )
        val remotePeekInteraction = remember { MutableInteractionSource() }
        val density = LocalDensity.current
        val hiddenTravelPx = with(density) { 48.dp.toPx() }
        val playfulLiftPx = with(density) { 6.dp.toPx() }
        val remoteButtonWidth by animateDpAsState(
            targetValue = if (remoteIntroExpanded) 108.dp else 52.dp,
            animationSpec = if (remoteIntroExpanded) {
                Motion.bouncy()
            } else {
                tween(300, easing = FastOutSlowInEasing)
            },
            label = "remoteEntryWidth",
        )
        val openRemote: () -> Unit = {
            // 端侧录制与照片传输共用同一个 SAF 保存目录。与加入传输队列的
            // 拦截顺序一致：目录未设置时先引导设置，不进入监看后再让用户返工。
            if (transferState.transferDirUri == null) requestTransferDirectory()
            else if (transfersBusy) showHint(remoteBlockedHint)
            // 免费版当日监看时长已用完:入口处直接提示,不进页再弹回。
            else if (LicenseManager.remoteTimeLeftMs() <= 0L) showHint(remoteEndedHint)
            else {
                remoteIntroExpanded = false
                remoteExpandedAwayFromTop = false
                onNavigateToRemote()
            }
        }
        Box(
            modifier = Modifier
                .align(Alignment.BottomStart)
                .navigationBarsPadding()
                .padding(bottom = 40.dp)
                .size(width = 140.dp, height = 56.dp),
            contentAlignment = Alignment.CenterStart
        ) {
            GlassButton(
                onClick = {
                    if (remoteExpanded) {
                        openRemote()
                    } else {
                        haptics.tick()
                        remoteExpandedAwayFromTop = true
                    }
                },
                modifier = Modifier
                    .offset(x = 20.dp)
                    .width(remoteButtonWidth)
                    .height(52.dp)
                    .graphicsLayer {
                        // 弹簧允许轻微越界；路径中段上抬，收起时带一点俏皮歪头。
                        val progress = remoteReveal.value.coerceIn(-0.12f, 1.12f)
                        val pathProgress = progress.coerceIn(0f, 1f)
                        val arc = sin(pathProgress * Math.PI).toFloat()
                        translationX = -hiddenTravelPx * (1f - progress)
                        translationY = -playfulLiftPx * arc
                        val scale = 0.88f + 0.12f * progress
                        scaleX = scale
                        scaleY = scale
                        rotationZ = -3.5f * (1f - pathProgress) + arc * 1.25f
                        transformOrigin = TransformOrigin.Center
                    },
                shape = CircleShape,
                contentPadding = PaddingValues(14.dp),
                showSheen = false,
                active = remoteIntroExpanded && !transfersBusyVisual,
                activeColor = colors.accentBlue,
                // 深色由 0.38 提至约 0.60，浅色由 0.80 提至约 0.87；
                // 仍能透出背景，但入口不会再像一层几乎看不见的薄膜。
                frostedOpacityBoost = 0.35f,
                // 入口必须走公共按钮材质：毛玻璃、钛合金、木纹均与当前主题同步。
                // 按压缩放由 GlassButton 统一提供，不在此重复实现。
                shadowElevation = 6.dp
            ) {
                RemoteMark(
                    modifier = Modifier
                        .size(24.dp),
                    color = if (transfersBusyVisual) {
                        colors.onSurfaceVariant.copy(alpha = 0.5f)
                    } else {
                        colors.accentBlue
                    },
                    // 收起时由屏内 48dp 热区承担唯一语义，避免无障碍树出现两个同名入口。
                    contentDescription = remoteEntryDescription.takeIf { remoteExpanded }
                )
                AnimatedVisibility(
                    visible = remoteIntroExpanded,
                    enter = fadeIn(tween(180, delayMillis = 70)) +
                        expandHorizontally(
                            animationSpec = tween(250, easing = FastOutSlowInEasing),
                            expandFrom = Alignment.Start,
                        ),
                    exit = fadeOut(tween(120)) +
                        shrinkHorizontally(
                            animationSpec = tween(240, easing = FastOutSlowInEasing),
                            shrinkTowards = Alignment.Start,
                        ),
                ) {
                    Text(
                        text = stringResource(R.string.remote_entry_intro),
                        modifier = Modifier.clearAndSetSemantics { },
                        color = if (transfersBusyVisual) {
                            colors.onSurfaceVariant.copy(alpha = 0.62f)
                        } else {
                            colors.onBackground
                        },
                        style = MaterialTheme.typography.labelSmall.copy(
                            fontSize = 10.sp,
                            lineHeight = 11.sp,
                        ),
                        fontWeight = FontWeight.SemiBold,
                        textAlign = TextAlign.Center,
                    )
                }
            }
            if (!remoteExpanded) {
                // 视觉上只露出半颗，但保留 48dp 的屏内点击热区，兼顾发现性与可访问性。
                Box(
                    modifier = Modifier
                        .align(Alignment.CenterStart)
                        .fillMaxHeight()
                        .width(48.dp)
                        .semantics { contentDescription = remoteEntryDescription }
                        .clickable(
                            interactionSource = remotePeekInteraction,
                            indication = null,
                            role = Role.Button
                        ) {
                            haptics.tick()
                            remoteExpandedAwayFromTop = true
                        }
                )
            }
        }

        // ---------- 回到顶部（右下角毛玻璃圆钮）：仅在深处向顶部滚动时短暂出现 ----------
        AnimatedVisibility(
            visible = showBackTop,
            enter = fadeIn() + scaleIn(initialScale = 0.6f),
            exit = fadeOut() + scaleOut(targetScale = 0.6f),
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .navigationBarsPadding()
                .padding(end = 20.dp, bottom = 24.dp)
        ) {
            GlassButton(
                onClick = {
                    showBackTop = false
                    returningToTop = true
                    scrollScope.launch {
                        try {
                            // 深位置先瞬移到近处再动画收尾：既有"滚回去"的动效，
                            // 又不会从几千行外慢慢卷。
                            if (gridState.firstVisibleItemIndex > BACK_TO_TOP_SNAP_INDEX) {
                                gridState.scrollToItem(BACK_TO_TOP_SNAP_INDEX)
                            }
                            gridState.animateScrollToItem(0)
                        } finally {
                            returningToTop = false
                        }
                    }
                },
                shape = CircleShape,
                contentPadding = PaddingValues(14.dp)
            ) {
                // 自绘"顶杠+上箭头"标志（与信号条同族的圆头杆件语言）。
                BackToTopMark(
                    modifier = Modifier.size(24.dp),
                    color = colors.accentBlue,
                    contentDescription = stringResource(R.string.cd_back_to_top)
                )
            }
        }

        // ---------- 顶部渐变 scrim：edge-to-edge 内容滚到状态栏后面时，保证状态栏图标
        // 与悬浮控件在任何内容上都可读，也让顶栏更有"浮在雾面上"的层次 ----------
        if (!atTop) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(topInset + 56.dp)
                    .background(
                        Brush.verticalGradient(
                            0f to colors.backgroundTop.copy(alpha = 0.85f),
                            0.45f to colors.backgroundTop.copy(alpha = 0.5f),
                            1f to Color.Transparent
                        )
                    )
            )
        }

        // ---------- 悬浮顶部控件（不占高度，浮在内容上）----------
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (previewIndex == null) {
            // 左：双 Z 标悬浮按钮（原"Z传"文本，换成自绘的尼康 Z 系列标志更简洁），
            // 本身即为设置入口（点击打开设置弹窗）。毛玻璃观感复用 GlassButton。
            GlassButton(
                onClick = {
                    transferDirectoryAttention = false
                    showSettings = true
                },
                shape = RoundedCornerShape(22.dp),
                // 顶栏按钮统一 36dp 高（与队列胶囊等一致）；标志 20dp + 上下 8dp 正好填满。
                // 水平留白略收紧，保留品牌标志的完整呼吸空间。
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
                enforceMinimumTouchTarget = false,
                // 钛合金主题使用品牌黄填充钢印；其余主题仍保留 ZMark 原本的前景色。
                materialContentColor = colors.accentYellow,
                modifier = Modifier
                    .height(36.dp)
                    .onGloballyPositioned { zAnchor = it.boundsInRoot() }
            ) {
                ZMark(modifier = Modifier.height(20.dp))
            }

            // 双 Z 标边上的信号按钮（常驻）：在线显示信号条（点击展开 dBm），断开显示
            // 红色断连图标；断开时点缩略图会放大强调它并弹提示（signalPulse 驱动）。
            Spacer(modifier = Modifier.width(8.dp))
            FileListSignalPill(
                cameraViewModel = cameraViewModel,
                pulseTrigger = signalPulse,
            )

            // 信号按钮右侧：类型筛选按钮。信号条展开/收起的宽度动画是逐帧真实布局，
            // 本按钮随 Row 重排平滑让位，位置天然跟随动画。已设筛选时图标高亮。
            Spacer(modifier = Modifier.width(8.dp))
            val buttonSkin = LocalButtonTexturePalette.current?.skin ?: SkinPreset.FROSTED_GLASS
            val buttonDark = colors.background.luminance() < 0.5f
            val filterButtonColors = remember(
                buttonSkin,
                buttonDark,
                colors.onBackground,
                colors.accentYellow,
            ) {
                filterButtonPalette(
                    skin = buttonSkin,
                    dark = buttonDark,
                    defaultInactiveIcon = colors.onBackground,
                    defaultActive = colors.accentYellow,
                )
            }
            val filterMarkColor by animateColorAsState(
                targetValue = if (filterActive) {
                    filterButtonColors.activeIcon
                } else {
                    filterButtonColors.inactiveIcon
                },
                animationSpec = tween(180),
                label = "filterMarkActive"
            )
            val filterMarkFill by animateFloatAsState(
                targetValue = if (filterActive) 1f else 0f,
                animationSpec = tween(durationMillis = 180, easing = FastOutSlowInEasing),
                label = "filterMarkFill",
            )
            GlassButton(
                onClick = {
                    if (showFilter) {
                        showFilter = false
                        openedFilterAnchor = null
                    } else {
                        filterAnchor?.let { measuredAnchor ->
                            openedFilterAnchor = measuredAnchor
                            showFilter = true
                        }
                    }
                },
                shape = RoundedCornerShape(22.dp),
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                enforceMinimumTouchTarget = false,
                active = filterActive,
                activeColor = filterButtonColors.activeMaterial,
                activeOutline = true,
                // 钛合金按凹刻填色、相机键帽按丝印色处理；其它材质直接沿用图标颜色。
                materialContentColor = filterMarkColor,
                modifier = Modifier
                    .height(36.dp)
                    // 图标按钮统一采用 40dp 紧凑宽度；实体主题也提前给出同一测量基线，
                    // 避免不同材质的可见边缘发生偏移。
                    .widthIn(min = TOP_BAR_COMPACT_BUTTON_MIN_WIDTH)
                    .onGloballyPositioned { filterAnchor = it.boundsInRoot() }
            ) {
                // 自绘筛选标志（与信号条同族的圆头杆件语言）；已设筛选时高亮。
                FilterMark(
                    modifier = Modifier.size(19.dp),
                    color = filterMarkColor,
                    fillProgress = filterMarkFill,
                    contentDescription = stringResource(R.string.cd_filter_type)
                )
            }
            }

            // 右侧队列控件由 NavHost 外的共同宿主持有；这里仅保留弹性占位，
            // 左侧按钮仍按原布局排布，页面切换时右侧控件不会随页面进出场。
            Spacer(modifier = Modifier.weight(1f))
        }

        // ---------- "整组吸入"动画层：一摞卡片残影沿弧线飞向队列胶囊，到达即触发胶囊弹跳 ----------
        queueFlights.forEach { flight ->
            key(flight.id) {
                QueueFlightGhost(
                    flight = flight,
                    target = queueTargetBounds,
                    onDone = {
                        queueFlights.remove(flight)
                        if (flight.holdsQueueCount) {
                            onQueueFlightFinished(flight.count)
                        } else {
                            onQueueFlightCaught()
                        }
                    }
                )
            }
        }

        // ---------- 类型/标记筛选浮层：从筛选按钮变形弹出、关闭缩回按钮（见 FilterOverlay）----------
        openedFilterAnchor?.takeIf { showFilter }?.let { frozenAnchor ->
            FilterOverlay(
                anchorBounds = frozenAnchor,
                availableExts = availableExts,
                current = filterCriteria,
                storageSlots = visibleStorageSlots,
                suggestedDate = latestKnownDate,
                hapticsEnabled = transferState.hapticsEnabled,
                onChange = { criteria ->
                    // FilterOverlay 只在工作状态确实变化时回调；这里每次都提交。
                    // 不能用父层上一帧的 filter* 闭包拦截：快速双击同一项时，第二次
                    // 取消可能在重组前到达，会被误判为“未变化”而无法持久化。
                    filterRevealTick++
                    filterRevealWindow = true
                    transferViewModel.setFilters(
                        criteria.copy(
                            storageSlot = normalizeStorageSlotFilter(
                                selectedSlot = criteria.storageSlot,
                                availableSlots = visibleStorageSlots,
                                hasCompletedFileScan = true,
                            )
                        )
                    )
                },
                onDismiss = {
                    showFilter = false
                    openedFilterAnchor = null
                }
            )
        }

        // 设置面板（点击 "Z传" 或未设目录时弹出），从 "Z传" 按钮位置变形展开。
        if (showSettings) {
            SettingsOverlay(
                viewModel = transferViewModel,
                effectPreviewSource = state.effectPreviewBitmap,
                effectPreviewCameraManufacturer = state.cameraManufacturer,
                effectPreviewCameraModel = state.cameraModel,
                effectPreviewExif = state.effectPreviewExif,
                requestTransferDirectoryAttention = transferDirectoryAttention,
                onEffectPreviewRequested = cameraViewModel::requestEffectPreview,
                anchorBounds = zAnchor,
                onDismiss = {
                    showSettings = false
                    transferDirectoryAttention = false
                },
                onPlayFireworks = { fireworks.launch() },
                cameraConnectionType = state.connectionType,
                cameraConnected = state.isConnectedToCamera,
                cameraIsStaMode = state.isStaConnection,
                // 本页是连着相机时的主界面,购买入口多半从这里进——不接上这条,
                // 购买时就不会断开相机、相机热点不关、付款没网。
                onHoldCameraWifi = { cameraViewModel.holdCameraWifi(it) }
            )
        }

        // 长按预览层：全屏翻页，从被长按格子的位置放大展开/收回。
        previewIndex?.let { idx ->
            if (idx in previewItems.indices) {
                PhotoPreviewOverlay(
                    items = previewItems,
                    initialIndex = idx,
                    // 打开仍从原格子坐标展开；关闭时会重新定位当前照片并使用最新坐标，
                    // 此处的旧坐标只负责首帧，模型改变也不会再缩回错误格位。
                    anchorRect = previewAnchor.takeIf { previewSourceAtOpen === previewSourceIdentity },
                    cameraViewModel = cameraViewModel,
                    hapticsEnabled = transferState.hapticsEnabled,
                    transfersBusy = transfersBusy,
                    initialRotationQuarterTurns = transferState.previewRotationQuarterTurns,
                    histogramVisible = transferState.previewHistogramEnabled,
                    burstHandles = burstHandles,
                    queueTaskFor = { file ->
                        queuedIndexByHandle[file.handle]
                            ?.let(transferState.tasks::getOrNull)
                            ?.takeIf { it.file.handle == file.handle }
                    },
                    isTransferred = hasLocalOriginal,
                    localOriginalUriFor = { file ->
                        transferredOriginalUri(
                            file = file,
                            existingExportIndex = transferState.existingExportIndex,
                            organizeTransfersByDate = transferState.organizeTransfersByDate,
                        )
                    },
                    activeProgressFlow = transferViewModel.activeTransferProgress,
                    queueTargetBounds = queueTargetBounds,
                    onQueueFlightCaught = onQueueFlightCaught,
                    onTransfer = onTransferFromPreview,
                    onTransferBurst = onTransferBurstPreview,
                    onBurstExpandedChange = { id, expanded ->
                        if (expanded) expandedBurstCollections[id] = true
                        else expandedBurstCollections.remove(id)
                    },
                    onRotationChanged = transferViewModel::setPreviewRotationQuarterTurns,
                    onHistogramVisibleChanged =
                        transferViewModel::setPreviewHistogramEnabled,
                    prepareDismissTarget = preparePreviewDismissTarget,
                    onDismiss = { returnFile ->
                        updatePreviewIndex(null)
                        previewItems = emptyList()
                        previewSourceAtOpen = null
                        returnFile?.let { file ->
                            val nonce = previewReturnNonce + 1
                            previewReturnNonce = nonce
                            previewReturnHandle = file.handle
                            scrollScope.launch {
                                delay(760)
                                if (previewReturnNonce == nonce) previewReturnHandle = null
                            }
                        }
                    }
                )
            }
        }

        // 底部通用玻璃提示条（退出确认 / 相机未连接等）。
        // 放在预览层之上：预览中点传输但未连接时，提示仍能看见。
        AnimatedVisibility(
            visible = hintVisible,
            enter = fadeIn() + slideInVertically { it / 2 },
            exit = fadeOut() + slideOutVertically { it / 2 },
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 28.dp)
        ) {
            Surface(
                shape = RoundedCornerShape(22.dp),
                color = colors.glassSurfaceHeavy,
                shadowElevation = 6.dp,
                border = BorderStroke(1.dp, colors.glassPanelBorder)
            ) {
                Text(
                    hintText,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
                    style = MaterialTheme.typography.labelLarge,
                    color = colors.onBackground
                )
            }
        }

        // 高级版烟花彩蛋（最上层，含设置面板与预览层之上）：不拦截触摸，播完自行移除。
        FireworksOverlay(
            state = fireworks,
            hapticsEnabled = transferState.hapticsEnabled,
        )

        // Debug 构建显示效果图生成耗时入口；Release 为同名空实现，不产生节点。
        DebugPhotoGenerationProbePanel(modifier = Modifier.fillMaxSize())
    }
}

internal data class QueuePillTaskSummary(
    val downloadRemaining: Int,
    val generationRemaining: Int,
    val activeDownloadTaskId: Long?,
    val activeProgressTaskId: Long?,
    val hasActive: Boolean,
    val hasCancelled: Boolean,
)

/** 单次遍历生成胶囊所需的低频队列摘要；高频进度重组期间直接复用。 */
internal fun summarizeQueuePillTasks(tasks: List<TransferTask>): QueuePillTaskSummary {
    var downloadRemaining = 0
    var generationRemaining = 0
    var activeDownloadTaskId: Long? = null
    var firstGeneratingTaskId: Long? = null
    var firstWaitingTaskId: Long? = null
    var hasCancelled = false

    tasks.forEach { task ->
        when (task.status) {
            TransferStatus.WAITING -> {
                downloadRemaining++
                if (firstWaitingTaskId == null) firstWaitingTaskId = task.taskId
            }
            TransferStatus.TRANSFERING -> {
                downloadRemaining++
                if (activeDownloadTaskId == null) activeDownloadTaskId = task.taskId
            }
            TransferStatus.CANCELLED -> hasCancelled = true
            TransferStatus.COMPLETED,
            TransferStatus.FAILED -> Unit
        }
        if (task.isGeneratingFrame) {
            generationRemaining++
            if (firstGeneratingTaskId == null) firstGeneratingTaskId = task.taskId
        }
    }

    return QueuePillTaskSummary(
        downloadRemaining = downloadRemaining,
        generationRemaining = generationRemaining,
        activeDownloadTaskId = activeDownloadTaskId,
        activeProgressTaskId = activeDownloadTaskId
            ?: firstGeneratingTaskId
            ?: firstWaitingTaskId,
        hasActive = activeDownloadTaskId != null || generationRemaining > 0,
        hasCancelled = hasCancelled,
    )
}

/** 与状态胶囊同材质的顶部队列操作按钮，不跟随可选按钮皮肤。 */
@Composable
internal fun QueueExecutionButton(
    control: QueueExecutionControl,
    pauseRequested: Boolean,
    startEnabled: Boolean,
    onStart: () -> Unit,
    onPause: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = AppTheme.colors
    val accent by animateColorAsState(
        targetValue = if (control == QueueExecutionControl.START) {
            colors.accentBlue
        } else {
            colors.accentYellow
        },
        animationSpec = tween(180),
        label = "queueExecutionAccent",
    )
    val activeProgress by animateFloatAsState(
        targetValue = if (
            control == QueueExecutionControl.PAUSE && pauseRequested
        ) 1f else 0f,
        animationSpec = tween(180),
        label = "queueExecutionActive",
    )
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val pressScale by animateFloatAsState(
        targetValue = if (pressed &&
            (control == QueueExecutionControl.PAUSE || startEnabled)
        ) {
            0.92f
        } else {
            1f
        },
        animationSpec = if (pressed) tween(80) else Motion.bouncy(),
        label = "queueExecutionPress",
    )
    val enabled = control == QueueExecutionControl.PAUSE || startEnabled
    val visualAlpha = if (enabled) 1f else 0.45f
    // 与通用毛玻璃按钮一致，不让半透明 Surface、投影和缩放共用矩形 RenderNode。
    // 部分 GPU 会把那层缓存边界显成浅色方框；固定外层尺寸、只改变圆形内容尺寸，
    // 禁用态透明度直接落到绘制颜色上，深色/浅色及按压态都不会生成矩形边框。
    Box(
        modifier = modifier.size(32.dp),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size((32f * pressScale).dp)
                .clip(CircleShape)
                .background(
                    colors.glassSurface.copy(
                        alpha = colors.glassSurface.alpha * visualAlpha,
                    )
                )
                .background(
                    Brush.verticalGradient(
                        listOf(
                            colors.glassHighlightTop.copy(
                                alpha = colors.glassHighlightTop.alpha * visualAlpha,
                            ),
                            colors.glassHighlightBottom.copy(
                                alpha = colors.glassHighlightBottom.alpha * visualAlpha,
                            ),
                        )
                    )
                )
                .background(
                    accent.copy(alpha = 0.16f * activeProgress * visualAlpha)
                )
                .clickable(
                    enabled = enabled,
                    role = Role.Button,
                    interactionSource = interactionSource,
                    indication = null,
                    onClick = if (control == QueueExecutionControl.START) onStart else onPause,
                ),
            contentAlignment = Alignment.Center,
        ) {
            AnimatedContent(
                targetState = control,
                transitionSpec = {
                    (fadeIn(tween(150, delayMillis = 35)) +
                        scaleIn(initialScale = 0.72f, animationSpec = tween(175, delayMillis = 25)))
                        .togetherWith(
                            fadeOut(tween(100)) +
                                scaleOut(targetScale = 0.72f, animationSpec = tween(120))
                        )
                },
                contentAlignment = Alignment.Center,
                label = "queueExecutionIcon",
            ) { current ->
                Icon(
                    imageVector = if (current == QueueExecutionControl.START) {
                        Icons.Rounded.PlayArrow
                    } else {
                        TransferQueuePauseIcon
                    },
                    contentDescription = stringResource(
                        when {
                            current == QueueExecutionControl.START -> R.string.cd_start_transfers
                            pauseRequested -> R.string.cd_pause_after_current_scheduled
                            else -> R.string.cd_pause_after_current
                        }
                    ),
                    tint = accent.copy(alpha = accent.alpha * visualAlpha),
                    modifier = Modifier.size(
                        if (current == QueueExecutionControl.START) 21.dp else 18.dp
                    ),
                )
            }
        }
    }
}

@Composable
fun QueuePill(
    transferState: com.ztransfer.viewmodel.TransferState,
    activeProgressFlow: StateFlow<ActiveTransferProgress?>,
    haptics: Haptics,
    onClick: () -> Unit,
    // 显示层押扣:飞行中的"整组包裹"承载的文件数,落袋前不计入读数
    //（数字在包裹到达时才跳上去);实际队列不受影响,仅影响本胶囊显示。
    heldCount: Int = 0
) {
    val colors = AppTheme.colors
    val liveProgress by activeProgressFlow.collectAsStateWithLifecycle()
    val taskSummary = remember(transferState.tasks) {
        summarizeQueuePillTasks(transferState.tasks)
    }
    val downloadRemaining = taskSummary.downloadRemaining
    val generationRemaining = taskSummary.generationRemaining
    val remaining = if (downloadRemaining > 0) {
        queuePillDisplayRemaining(downloadRemaining, heldCount)
    } else {
        generationRemaining
    }
    // Flight bookkeeping can intentionally display zero until the first card lands. Completion
    // still follows the real task state: that temporary zero uses the icon, never the Done state.
    val allDone = downloadRemaining == 0 && generationRemaining == 0
    val transferring = transferState.isTransferring
    val activeProgress = liveProgress?.takeIf {
        it.taskId == taskSummary.activeDownloadTaskId
    }
    // Keep the last valid batch speed across the short preparation gap between two files.
    val activeSpeed = liveProgress?.retainedBytesPerSecond ?: 0L
    val activeSpeedText = activeSpeed
        .takeIf { transferring && it > 0L }
        ?.let(::formatSpeed)
    val paused = !transferring && downloadRemaining > 0
    val mode = queuePillMode(downloadRemaining, generationRemaining, paused = paused)
    val widthKey = queuePillWidthKey(mode, activeSpeedText, remaining)
    val hasActive = taskSummary.hasActive
    // 数字延迟显现：刚入队的任务可能马上被"已存在"跳过（remaining 1→0 一闪而过），
    // 那种情况只播 done→图标转场、不闪数字。真正开始下载(TRANSFERING)立即显示数字；
    // 纯等待超过宽限期（说明确实在排队，如目录扫描慢）也显示。
    var countingVisible by remember { mutableStateOf(false) }
    LaunchedEffect(remaining > 0, hasActive, paused) {
        countingVisible = when {
            paused -> true
            hasActive -> true
            remaining > 0 -> { delay(350); true }
            else -> false
        }
    }
    // "done → 图标" 的转场只由"传输中 → 全部完成"触发。prevAllDone 初值取当前 allDone：
    // 若进入本页时已是完成态（例如从队列页返回），不再闪 done，直接显示图标（无转场动画）。
    var showDoneLabel by remember { mutableStateOf(false) }
    var prevAllDone by remember { mutableStateOf(allDone) }
    // 本轮队列是否真的下载过（用于完成震动：纯"已存在跳过"的瞬时完成不震）。
    var sawTransfer by remember { mutableStateOf(false) }
    var finishProgressVisible by remember { mutableStateOf(false) }
    LaunchedEffect(hasActive) {
        if (hasActive) sawTransfer = true
    }
    // 取消导致的"归零"不是完成：不闪 done、不震成功震（否则取消后出现庆祝反馈，误导）。
    // sawTransfer 在每次归零时都复位，取消那轮的记录不能污染下一轮的完成判定。
    val hasCancelled = taskSummary.hasCancelled
    LaunchedEffect(allDone) {
        if (allDone && !prevAllDone) {
            val celebrate = !hasCancelled && sawTransfer
            sawTransfer = false
            finishProgressVisible = celebrate
            if (!hasCancelled) {
                if (celebrate) haptics.success()
                showDoneLabel = true
                delay(1800)
                showDoneLabel = false
            }
            finishProgressVisible = false
        }
        prevAllDone = allDone
    }
    // 尚无飞行卡片落袋时显示默认图标而不是数字 0；这条优先于 PAUSED，确保“选完再传”
    // 模式也遵循相同叙事。其余情况保持原有规则：完成或尚未准许显示数字时收为图标。
    val allRemainingTasksAreInFlight = queuePillAllRemainingTasksAreInFlight(
        actualRemaining = downloadRemaining,
        heldCount = heldCount,
    )
    val collapsedToIcon = allRemainingTasksAreInFlight ||
        (mode != PillMode.PAUSED && (
            (allDone && !showDoneLabel) || (!allDone && !countingVisible)
        ))

    // 进度条 = 当前单文件进度（复用传输页语义）。保留最近的进度归属，让最后一张
    // 完成后仍能从当前位置顺滑补满，而不是因“当前任务”瞬间消失而重建动画。
    var retainedProgressTaskId by remember { mutableStateOf<Long?>(null) }
    LaunchedEffect(taskSummary.activeProgressTaskId) {
        taskSummary.activeProgressTaskId?.let { retainedProgressTaskId = it }
    }
    val barFraction = when {
        allDone && finishProgressVisible -> 1f
        allDone -> 0f // 静止图标态不预热动画，避免下一轮等待阶段错误继承满格。
        activeProgress != null -> activeProgress.fraction
        generationRemaining > 0 -> 1f
        else -> 0f
    }
    val animatedBar = rememberSmoothTransferProgress(
        targetProgress = barFraction,
        resetKey = taskSummary.activeProgressTaskId ?: retainedProgressTaskId,
    )

    // 普通按钮与胶囊共用同一条宽度弹簧。切换材质实现时右缘仍固定，只向左平滑伸缩，
    // 不会因为图标态改用 GlassButton 而丢掉原先的胶囊变形手感。
    val density = LocalDensity.current
    var contentWidthPx by remember { mutableStateOf(0) }
    var activeQueueMaxWidthPx by remember { mutableStateOf(0) }
    var measuredWidthKey by remember { mutableStateOf<QueuePillWidthKey?>(null) }
    val collapsedWidthPx = with(density) { 40.dp.toPx() } // 22dp 图标 + 左右各 9dp
    val widthAnim = remember { Animatable(0f) }
    var firstMeasure by remember { mutableStateOf(true) }
    val stableContentWidthPx = if (
        mode == PillMode.COUNTING && measuredWidthKey == widthKey
    ) {
        maxOf(contentWidthPx, activeQueueMaxWidthPx)
    } else {
        contentWidthPx
    }
    val targetWidthPx = if (collapsedToIcon) collapsedWidthPx else stableContentWidthPx.toFloat()
    LaunchedEffect(targetWidthPx) {
        if (targetWidthPx > 0f) {
            if (firstMeasure) {
                widthAnim.snapTo(targetWidthPx)
                firstMeasure = false
            } else {
                widthAnim.animateTo(targetWidthPx, Motion.bouncy())
            }
        }
    }

    // 图标态已经是普通入口按钮，不再沿用下方固定毛玻璃胶囊的手写 Surface。
    // 直接复用全局按钮组件后，毛玻璃、钛合金（含钢印）与随机稳定木纹都会自动生效；
    // 一旦出现 Done、速度或数量，仍回到原胶囊实现，不受按钮主题影响。
    if (collapsedToIcon) {
        GlassButton(
            onClick = onClick,
            shape = RoundedCornerShape(22.dp),
            contentPadding = PaddingValues(horizontal = 9.dp, vertical = 7.dp),
            enforceMinimumTouchTarget = false,
            textureSeed = QUEUE_ENTRY_BUTTON_TEXTURE_SEED,
            modifier = Modifier
                .height(36.dp)
                .then(
                    if (widthAnim.value > 0f) {
                        Modifier.width(with(density) { widthAnim.value.toDp() })
                    } else {
                        Modifier
                    }
                )
        ) {
            Icon(
                imageVector = Icons.Default.Checklist,
                contentDescription = stringResource(R.string.cd_transfer),
                tint = colors.statusConnected,
                modifier = Modifier.size(22.dp)
            )
        }
        return
    }

    // 按压微缩放：本胶囊是顶栏唯一手写 Surface（不经 GlassButton），手感与全局按钮对齐。
    val pillInteraction = remember { MutableInteractionSource() }
    val pillPressed by pillInteraction.collectIsPressedAsState()
    val pillPressScale by animateFloatAsState(
        targetValue = if (pillPressed) 0.95f else 1f,
        animationSpec = if (pillPressed) tween(80) else Motion.bouncy(),
        label = "pillPress"
    )
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(22.dp),
        color = colors.glassSurface,   // 毛玻璃半透明底（与 "Z传" 一致）
        shadowElevation = 4.dp,
        interactionSource = pillInteraction,
        modifier = Modifier
            .height(36.dp)
            .graphicsLayer {
                scaleX = pillPressScale
                scaleY = pillPressScale
            }
            // 用动画宽度；首帧未测量时先按内容自适应，测到后即锁定为动画宽度。
            .then(if (contentWidthPx > 0) Modifier.width(with(density) { widthAnim.value.toDp() }) else Modifier)
    ) {
        Box(contentAlignment = Alignment.CenterEnd) {
            // 1) 单文件进度填充（填满当前动画宽度；收起为图标后不显示）。
            if (!allDone || finishProgressVisible) {
                LiquidProgressFill(
                    progress = { animatedBar.value },
                    waveEligible = taskSummary.activeDownloadTaskId != null ||
                        finishProgressVisible,
                    seedKey = taskSummary.activeProgressTaskId ?: retainedProgressTaskId,
                    color = colors.accentBlue.copy(alpha = 0.35f),
                    modifier = Modifier.matchParentSize(),
                )
            }
            // 2) 毛玻璃高光 + 描边叠层（与 "Z传" 同款，略有区别）。
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .background(
                        brush = Brush.verticalGradient(
                            listOf(colors.glassHighlightTop, colors.glassHighlightBottom)
                        )
                    )
                    .border(
                        width = 1.dp,
                        brush = Brush.verticalGradient(
                            listOf(colors.glassBorderTop, colors.glassBorderBottom)
                        ),
                        shape = RoundedCornerShape(22.dp)
                    )
            )

            // 3) 内容：以自然宽度测量(unbounded)、靠右对齐；宽度动画滞后时左侧溢出被圆角裁掉。
            Box(modifier = Modifier.wrapContentWidth(Alignment.End, unbounded = true)) {
                Box(modifier = Modifier.onGloballyPositioned {
                    contentWidthPx = it.size.width
                    if (measuredWidthKey != widthKey) {
                        measuredWidthKey = widthKey
                        activeQueueMaxWidthPx = it.size.width
                    } else if (
                        mode == PillMode.COUNTING && it.size.width > activeQueueMaxWidthPx
                    ) {
                        activeQueueMaxWidthPx = it.size.width
                    }
                }) {
                    // 胶囊内部的 Done / 计数切换用交叉淡化 + 轻微缩放过渡，不硬切。
                    // 尺寸动画交给外层的弹性宽度弹簧（snap 禁用 AnimatedContent 自带的尺寸
                    // 动画，避免两套叠加）；计数态内部的数字/速度更新不触发转场，原地刷新。
                    AnimatedContent(
                        targetState = mode,
                        // 胶囊右缘钉死、向左伸缩：新旧内容必须都锚定右缘（CenterEnd），
                        // 否则容器 snap 到新宽度时，退场内容会从右对齐跳成左对齐（文字漂移）。
                        contentAlignment = Alignment.CenterEnd,
                        transitionSpec = {
                            (fadeIn(tween(200, delayMillis = 60)) +
                                    scaleIn(
                                        initialScale = 0.85f,
                                        animationSpec = tween(200, delayMillis = 60),
                                        // 缩放原点同样锚在右缘中点，与布局语义一致
                                        transformOrigin = TransformOrigin(1f, 0.5f)
                                    ))
                                .togetherWith(fadeOut(tween(120)))
                                .using(SizeTransform(clip = false, sizeAnimationSpec = { _, _ -> snap() }))
                        },
                        label = "pillContent"
                    ) { m ->
                        when (m) {
                            PillMode.DONE ->
                                Text(
                                    // 刻意不走字符串资源:所有语言统一显示 "Done"(短暂闪现的
                                    // 状态徽记,当装饰性标识处理,不参与本地化)。
                                    text = "Done",
                                    style = MaterialTheme.typography.labelLarge.copy(fontFeatureSettings = "tnum"),
                                    color = colors.statusConnected,
                                    fontWeight = FontWeight.Bold,
                                    modifier = Modifier.padding(horizontal = 16.dp)
                                )
                            PillMode.PAUSED ->
                                AnimatedQueuePillCount(
                                    count = remaining,
                                    color = colors.onBackground,
                                    label = "pausedCount",
                                    modifier = Modifier.padding(horizontal = 16.dp),
                                )
                            PillMode.GENERATING ->
                                Row(
                                    modifier = Modifier.padding(horizontal = 16.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                ) {
                                    Text(
                                        text = stringResource(R.string.queue_pill_generating),
                                        style = MaterialTheme.typography.labelLarge,
                                        color = colors.accentBlue,
                                        fontWeight = FontWeight.Bold,
                                    )
                                    AnimatedQueuePillCount(
                                        count = generationRemaining,
                                        color = colors.onBackground,
                                        label = "generationCount",
                                    )
                                }
                            PillMode.COUNTING ->
                                Row(
                                    modifier = Modifier.padding(horizontal = 16.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    // 速度在前（仅传输且有速度时显示）。tnum：等宽数字，位数相同则宽度恒定。
                                    if (activeSpeedText != null) {
                                        Text(
                                            text = activeSpeedText,
                                            style = MaterialTheme.typography.labelMedium.copy(fontFeatureSettings = "tnum"),
                                            color = colors.accentBlue,
                                            fontWeight = FontWeight.Bold
                                        )
                                    }
                                    // 数字滚动：减少（传输推进）时旧数上滑、新数自下滑入；增加（新入队）反向。
                                    // 尺寸仍 snap 交给外层宽度弹簧；clip 让滑动的数字在行内裁切，像里程表。
                                    AnimatedQueuePillCount(
                                        count = remaining,
                                        color = colors.onBackground,
                                        label = "downloadCount",
                                    )
                                }
                        }
                    }
                }
            }
        }
    }
}

/**
 * 文件列表只会在建立过相机会话后出现；极端恢复场景拿不到类型时沿用原有 Wi-Fi 兜底。
 * 一旦识别过 USB，本次会话即使掉线也必须持续展示 USB 提示。
 */
internal fun disconnectedConnectionType(
    connectionType: CameraConnectionType?
): CameraConnectionType = connectionType ?: CameraConnectionType.WIFI

internal data class FilterButtonPalette(
    val inactiveIcon: Color,
    val activeIcon: Color,
    val activeMaterial: Color,
)

/**
 * 筛选按钮按实体材质选择刻印与激活指示色。强调色同时驱动轻染、轮廓和图标，
 * 但强度仍由 GlassButton 的统一 active 动画控制，切换主题不会增加额外绘制层。
 */
internal fun filterButtonPalette(
    skin: SkinPreset,
    dark: Boolean,
    defaultInactiveIcon: Color,
    defaultActive: Color,
): FilterButtonPalette = when (skin) {
    SkinPreset.FROSTED_GLASS -> FilterButtonPalette(
        inactiveIcon = defaultInactiveIcon,
        activeIcon = defaultActive,
        activeMaterial = defaultActive,
    )

    SkinPreset.TITANIUM -> {
        FilterButtonPalette(
            inactiveIcon = if (dark) Color(0xFFE4ECEF) else Color(0xFF344149),
            activeIcon = if (dark) Color(0xFFF0FAFF) else Color(0xFF053A54),
            activeMaterial = if (dark) Color(0xFF45A9D8) else Color(0xFF167DA7),
        )
    }

    SkinPreset.WOOD -> {
        FilterButtonPalette(
            inactiveIcon = if (dark) Color(0xFFF1D6A7) else Color(0xFF472A18),
            activeIcon = if (dark) Color(0xFFD8F6E8) else Color(0xFF062D22),
            activeMaterial = if (dark) Color(0xFF43A37B) else Color(0xFF1A7658),
        )
    }

    SkinPreset.CAMERA_CONTROLS -> FilterButtonPalette(
        // 相机键帽在深浅界面里始终是黑色，统一使用冷灰丝印与琥珀状态灯。
        inactiveIcon = Color(0xFFD5D8DA),
        activeIcon = Color(0xFFFFE2A3),
        activeMaterial = Color(0xFFFF9F1A),
    )
}

/** 缩略图只借用材质色相，不复制按钮纹理、投影或高光。 */
internal fun thumbnailThemeBorderColor(skin: SkinPreset, dark: Boolean): Color = when (skin) {
    SkinPreset.FROSTED_GLASS -> if (dark) {
        Color.White.copy(alpha = 0.12f)
    } else {
        Color.Black.copy(alpha = 0.09f)
    }

    SkinPreset.TITANIUM -> if (dark) {
        Color(0xFFD7E2E7).copy(alpha = 0.20f)
    } else {
        Color(0xFF46545B).copy(alpha = 0.17f)
    }

    SkinPreset.WOOD -> if (dark) {
        Color(0xFFE4B979).copy(alpha = 0.20f)
    } else {
        Color(0xFF623519).copy(alpha = 0.17f)
    }

    SkinPreset.CAMERA_CONTROLS -> if (dark) {
        Color(0xFFCDD3D6).copy(alpha = 0.16f)
    } else {
        Color(0xFF23272A).copy(alpha = 0.18f)
    }
}

internal fun stackedThumbnailThemeBorderColor(skin: SkinPreset, dark: Boolean): Color {
    val base = thumbnailThemeBorderColor(skin, dark)
    return base.copy(alpha = (base.alpha * 1.55f).coerceAtMost(0.36f))
}

internal data class SignalBarPalette(
    val lit: Color,
    val unlit: Color,
)

/** 木纹表面使用与胡桃/蜂蜜底色反向的指示灯色，档位靠明暗和格数共同表达。 */
internal fun signalBarPalette(
    skin: SkinPreset,
    dark: Boolean,
    level: Int,
    defaultLit: Color,
    defaultUnlit: Color,
): SignalBarPalette {
    if (skin != SkinPreset.WOOD) return SignalBarPalette(defaultLit, defaultUnlit)

    val lit = if (dark) {
        when {
            level >= 4 -> Color(0xFFA8E7BC) // 胡桃木上的柔和薄荷绿
            level >= 2 -> Color(0xFFFFD58A) // 暖金色，与木纹同族但亮度充分
            else -> Color(0xFFFF9D91)       // 低信号保持克制的珊瑚红警示
        }
    } else {
        when {
            level >= 4 -> Color(0xFF164F32) // 蜂蜜木上的深森林绿
            level >= 2 -> Color(0xFF4B2A12) // 深琥珀棕，不与橙色木纹融在一起
            else -> Color(0xFF8A2025)       // 深酒红，弱信号仍清楚可辨
        }
    }
    val unlitBase = if (dark) Color(0xFFFFE4B5) else Color(0xFF321D10)
    return SignalBarPalette(lit = lit, unlit = unlitBase.copy(alpha = 0.34f))
}

/** RSSI 的周期更新只在这个小范围内重组，不再使照片页正文和网格失效。 */
// `.value` only seeds the mapped flow; ongoing updates are collected immediately below.
@SuppressLint("StateFlowValueCalledInComposition")
@Composable
private fun FileListSignalPill(
    cameraViewModel: CameraViewModel,
    pulseTrigger: Int,
) {
    val state by remember(cameraViewModel) {
        cameraViewModel.state
            .map(CameraState::toFileListSignalUiState)
            .distinctUntilChanged()
    }.collectAsStateWithLifecycle(
        initialValue = cameraViewModel.state.value.toFileListSignalUiState(),
    )
    SignalPill(
        rssi = state.rssi,
        connected = state.connected,
        pulseTrigger = pulseTrigger,
        connectionType = state.connectionType,
        staMode = state.staMode,
        onStaDisconnectedClick = cameraViewModel::retryStaConnection,
    )
}

/**
 * 连接状态毛玻璃按钮：AP 显示信号格与 dBm，STA 显示专属拓扑状态，USB 显示经典三叉标；
 * AP 断开进入 Wi-Fi 设置，STA 断开进入个人热点设置，USB 断开则等待重新插线。
 * [pulseTrigger] 递增时按钮轻微放大再弹性缩回（断开时点缩略图的"病因指向"反馈）。
 * "Z传"页与队列页顶栏共用。
 */
@Composable
fun SignalPill(
    rssi: Int?,
    connected: Boolean,
    pulseTrigger: Int = 0,
    connectionType: CameraConnectionType? = null,
    staMode: Boolean = false,
    onStaDisconnectedClick: () -> Unit = {},
) {
    val colors = AppTheme.colors
    var expanded by remember { mutableStateOf(false) }
    val usbMode = connectionType == CameraConnectionType.USB
    val online = connected && (usbMode || staMode || rssi != null)
    val r = rssi ?: -999
    // dBm 越接近 0 越强。判定从严：满格只给极好信号，稍差立刻掉格。
    //  -30↑ 满格 / -45↑ 三格 / -55↑ 两格 / -65↑ 一格 / 更弱 0 格。
    val level = when {
        r >= -30 -> 4
        r >= -45 -> 3
        r >= -55 -> 2
        r >= -65 -> 1
        else -> 0
    }
    val color = when {
        usbMode && connected -> colors.accentBlue
        usbMode -> colors.statusError
        staMode && connected -> colors.accentBlue
        staMode -> colors.statusError
        level == 4 -> colors.statusConnected
        level >= 2 -> colors.accentOrange
        else -> colors.statusError
    }
    val skin = LocalButtonTexturePalette.current?.skin ?: SkinPreset.FROSTED_GLASS
    val dark = colors.background.luminance() < 0.5f
    val signalBars = remember(skin, dark, level, color, colors.onSurfaceVariant) {
        signalBarPalette(
            skin = skin,
            dark = dark,
            level = level,
            defaultLit = color,
            defaultUnlit = colors.onSurfaceVariant.copy(alpha = 0.28f),
        )
    }

    // 强调动画：trigger 递增时轻微放大、再弹性缩回（比左右抖动柔和）。
    val pulse = remember { Animatable(1f) }
    LaunchedEffect(pulseTrigger) {
        if (pulseTrigger > 0) {
            pulse.animateTo(1.15f, tween(120, easing = FastOutSlowInEasing))
            pulse.animateTo(1f, Motion.bouncy())
        }
    }
    // 断开呼吸：整个按钮持续轻微放大缩小，把“该重连相机了”顶到眼前。仅断开时
    // 组合 infinite transition，在线零开销；值在 graphicsLayer
    // 里读，每帧只更新图层不重组。与 pulse 强调相乘叠加，互不打架。
    val breath = if (!online) {
        rememberInfiniteTransition(label = "signalBreath").animateFloat(
            initialValue = 1f, targetValue = 1.09f,
            animationSpec = infiniteRepeatable(tween(550, easing = FastOutSlowInEasing), RepeatMode.Reverse),
            label = "signalBreathScale"
        )
    } else null

    val context = LocalContext.current
    GlassButton(
        onClick = {
            if (staMode) {
                expanded = false
                if (!connected) {
                    onStaDisconnectedClick()
                }
            } else if (online) expanded = !expanded
            // 断开态：断连图标即"去连 Wi-Fi"的入口，跳系统 Wi-Fi 设置（与连接页
            // 的 Wi-Fi 按钮同款行为）；离线时展开 dBm 本来就无意义。
            else if (!usbMode) try {
                context.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
            } catch (_: Exception) {}
        },
        shape = RoundedCornerShape(22.dp),
        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 9.dp),
        enforceMinimumTouchTarget = false,
        // 顶栏按钮统一 36dp 高；信号条内容 15dp，在按钮内垂直居中。
        modifier = Modifier
            .height(36.dp)
            // 收起状态与筛选按钮共用 40dp 宽度基线；展开的 dBm 文本仍可自然增宽。
            .widthIn(min = TOP_BAR_COMPACT_BUTTON_MIN_WIDTH)
            .graphicsLayer {
                val s = pulse.value * (breath?.value ?: 1f)
                scaleX = s
                scaleY = s
            }
    ) {
        // dBm 文本用 AnimatedVisibility 逐帧驱动宽度+透明度，按钮宽度随内容自然过渡。
        // 不能用 animateContentSize + if(expanded)：那是"内容瞬间增删、容器尺寸补动画"，
        // 文字会凭空闪现/先消失再缩壳，且外层 spacedBy 间距在元素移除瞬间跳变。
        // 单一子元素（外层 spacedBy 不参与），文字的起始间距放进动画宽度内一起过渡。
        // 内容高度锁定为信号条高度：文字比信号条略高，靠 unbounded 溢出居中进 padding，
        // 展开/收起时按钮高度不跳动。
        Row(
            modifier = Modifier.height(15.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // AP、STA、USB 各自使用独立图形；连接状态变化时交叉淡化切换。
            Crossfade(
                targetState = when {
                    usbMode -> SignalPillMode.USB
                    staMode && connected -> SignalPillMode.STA_ONLINE
                    staMode -> SignalPillMode.STA_OFFLINE
                    online -> SignalPillMode.WIFI_ONLINE
                    else -> SignalPillMode.WIFI_OFFLINE
                },
                animationSpec = tween(220),
                label = "signalMode"
            ) { mode ->
                when (mode) {
                    SignalPillMode.USB -> ClassicUsbIcon(
                            tint = color,
                            modifier = Modifier
                                .wrapContentHeight(unbounded = true)
                                .size(18.dp),
                        )

                    SignalPillMode.STA_ONLINE,
                    SignalPillMode.STA_OFFLINE -> StaSignalIcon(
                        connected = mode == SignalPillMode.STA_ONLINE,
                        tint = color,
                        modifier = Modifier
                            .wrapContentHeight(unbounded = true)
                            .size(19.dp),
                    )

                    SignalPillMode.WIFI_ONLINE -> Row(
                            modifier = Modifier.fillMaxHeight(),
                            verticalAlignment = Alignment.Bottom,
                            horizontalArrangement = Arrangement.spacedBy(2.5.dp),
                        ) {
                            repeat(4) { i ->
                                val lit = i < level.coerceAtLeast(1)
                                Box(
                                    modifier = Modifier
                                        .width(4.dp)
                                        .height((6 + i * 3).dp)
                                        .clip(RoundedCornerShape(1.5.dp))
                                        .background(if (lit) signalBars.lit else signalBars.unlit),
                                )
                            }
                        }

                    SignalPillMode.WIFI_OFFLINE -> Icon(
                            Icons.Default.WifiOff,
                            contentDescription = stringResource(R.string.camera_not_connected),
                            tint = colors.statusError,
                            modifier = Modifier
                                .wrapContentHeight(unbounded = true)
                                .size(18.dp),
                        )
                }
            }
            AnimatedVisibility(
                visible = expanded && online && !staMode,
                // 展开带一点弹性（与胶囊同款手感），从左侧展开、文字先露出开头。
                enter = expandHorizontally(
                    animationSpec = Motion.bouncy(),
                    expandFrom = Alignment.Start
                ) + fadeIn(),
                // 收起不用弹簧：宽度弹向 0 以下没有意义，干脆利落更自然。
                exit = shrinkHorizontally(
                    animationSpec = tween(220, easing = FastOutSlowInEasing),
                    shrinkTowards = Alignment.Start
                ) + fadeOut(tween(160))
            ) {
                Text(
                    text = if (usbMode) stringResource(R.string.connection_usb) else "$r dBm",
                    style = MaterialTheme.typography.labelMedium.copy(fontFeatureSettings = "tnum"),
                    fontWeight = FontWeight.Medium,
                    color = if (usbMode) color else signalBars.lit,
                    maxLines = 1,
                    softWrap = false,
                    modifier = Modifier
                        .padding(start = 6.dp)
                        .wrapContentHeight(unbounded = true)
                )
            }
        }
    }
}

private enum class SignalPillMode {
    WIFI_OFFLINE,
    WIFI_ONLINE,
    STA_OFFLINE,
    STA_ONLINE,
    USB,
}

/** STA does not expose a meaningful client-Wi-Fi RSSI, so connected state stays visually full. */
@Composable
private fun StaSignalIcon(
    connected: Boolean,
    tint: Color,
    modifier: Modifier = Modifier,
) {
    val description = stringResource(
        if (connected) R.string.sta_signal_connected
        else R.string.sta_signal_disconnected_reconnect,
    )
    Canvas(
        modifier = modifier.semantics { contentDescription = description },
    ) {
        val barWidth = 3.2.dp.toPx()
        val gap = 1.65.dp.toPx()
        val bottom = size.height * 0.88f
        val barHeights = floatArrayOf(5.dp.toPx(), 8.dp.toPx(), 11.dp.toPx(), 14.dp.toPx())
        val totalWidth = barWidth * barHeights.size + gap * (barHeights.size - 1)
        val startX = (size.width - totalWidth) / 2f
        val barColor = if (connected) tint else tint.copy(alpha = 0.28f)

        barHeights.forEachIndexed { index, height ->
            drawRoundRect(
                color = barColor,
                topLeft = Offset(startX + index * (barWidth + gap), bottom - height),
                size = Size(barWidth, height),
                cornerRadius = CornerRadius(1.35.dp.toPx()),
            )
        }

        if (!connected) {
            drawLine(
                color = tint,
                start = Offset(size.width * 0.15f, size.height * 0.12f),
                end = Offset(size.width * 0.87f, size.height * 0.88f),
                strokeWidth = 2.15.dp.toPx(),
                cap = StrokeCap.Round,
            )
        }
    }
}

@Composable
private fun GroupHeader(
    group: FileGroup,
    collapsed: Boolean,
    onToggleCollapse: () -> Unit,
    onTransferGroup: (List<NikonCamera.FileInfo>, Rect?) -> Unit
) {
    val colors = AppTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // 日期 + 展开箭头 + 张数合并为一颗毛玻璃"日期胶囊"，整颗可点切换收起/展开：
        // 触点比原来的小图标大得多，规格与右侧"传输"按钮同语言（28dp 高、8dp 圆角）。
        // 箭头用旋转动画（收起朝下、展开转 180°），比图标切换更顺滑。
        val chevron by animateFloatAsState(
            targetValue = if (collapsed) 0f else 180f,
            label = "chevron"
        )
        GlassButton(
            onClick = onToggleCollapse,
            shape = RoundedCornerShape(14.dp),   // 半高全圆，胶囊观感
            contentPadding = PaddingValues(horizontal = 12.dp),
            modifier = Modifier.height(28.dp)
        ) {
            Text(
                text = if (group.date == UNKNOWN_DATE_KEY) stringResource(R.string.unknown_date)
                       else formatDateHeader(group.date),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Bold,
                color = colors.onBackground
            )
            Icon(
                Icons.Default.ExpandMore,
                contentDescription = stringResource(if (collapsed) R.string.cd_expand else R.string.cd_collapse),
                tint = colors.accentBlue,
                modifier = Modifier
                    .size(18.dp)
                    .rotate(chevron)
            )
            // 仅数字（去掉"张"），tnum 等宽，界面更简约
            AnimatedContent(
                targetState = group.files.size,
                transitionSpec = {
                    (slideInVertically { it / 2 } + fadeIn(tween(140)))
                        .togetherWith(slideOutVertically { -it / 2 } + fadeOut(tween(100)))
                        .using(SizeTransform(clip = true, sizeAnimationSpec = { _, _ -> snap() }))
                },
                label = "dateGroupCount",
            ) { count ->
                Text(
                    text = "$count",
                    style = MaterialTheme.typography.bodySmall.copy(
                        fontFeatureSettings = "tnum",
                    ),
                    color = colors.onSurfaceVariant,
                )
            }
        }
        Spacer(modifier = Modifier.weight(1f))
        // 整组传输始终允许再次加入；任务执行时分别检查原片和边框是否已经存在。
        // 按钮在根坐标系的 bounds 供"整组吸入"动画定位起飞点。
        var plusBounds by remember { mutableStateOf<Rect?>(null) }
        GlassButton(
            onClick = { onTransferGroup(group.files, plusBounds) },
            enabled = group.files.isNotEmpty(),
            shape = RoundedCornerShape(14.dp),
            modifier = Modifier
                .width(40.dp)
                .height(28.dp)
                .onGloballyPositioned {
                    // 只收有效样本，避免分离/复用瞬间的零矩形污染动画起点。
                    if (it.isAttached) {
                        val b = it.boundsInRoot()
                        if (b.width > 0f && b.height > 0f) plusBounds = b
                    }
                },
            contentPadding = PaddingValues(horizontal = 10.dp),
            enforceMinimumTouchTarget = false,
        ) {
            Icon(
                Icons.Default.Add,
                contentDescription = stringResource(R.string.cd_transfer_group),
                tint = colors.accentBlue,
                modifier = Modifier.size(18.dp)
            )
        }
    }
}

internal fun buildThumbnailGridItems(
    files: List<NikonCamera.FileInfo>,
    burstIdByHandle: Map<Int, String>,
    collapseBurstPhotos: Boolean,
    expandedBurstIds: Set<String>
): List<ThumbnailGridItem> {
    if (!collapseBurstPhotos || burstIdByHandle.isEmpty()) {
        return files.map { file ->
            ThumbnailGridItem.Photo(file, burstId = burstIdByHandle[file.handle])
        }
    }

    // 先按当前筛选后的日期组收集成员。筛选可能令原本 ≥3 张的连拍只剩 1 张；
    // 单张不再画“合集”，避免用户为看一张照片还要多点一次。
    val visibleBursts = files
        .mapNotNull { file -> burstIdByHandle[file.handle]?.let { it to file } }
        .groupBy({ it.first }, { it.second })
    val collected = HashSet<String>()
    val result = ArrayList<ThumbnailGridItem>(files.size)

    files.forEach { file ->
        val burstId = burstIdByHandle[file.handle]
        val members = burstId?.let(visibleBursts::get)
        if (burstId == null || members == null || members.size < 2) {
            result += ThumbnailGridItem.Photo(file, burstId = burstId)
        } else if (collected.add(burstId)) {
            result += ThumbnailGridItem.BurstCollection(burstId, members)
            if (burstId in expandedBurstIds) {
                members.forEach { member ->
                    result += ThumbnailGridItem.Photo(
                        file = member,
                        burstId = burstId
                    )
                }
            }
        }
    }
    return result
}

/** Keeps an expanded burst expanded when camera-side deletion changes its derived collection id. */
internal fun reconciledExpandedBurstIds(
    previousGroups: List<BurstPhotoGroup>,
    currentGroups: List<BurstPhotoGroup>,
    expandedIds: Set<String>,
): Set<String> {
    if (expandedIds.isEmpty() || currentGroups.isEmpty()) return emptySet()
    val currentIds = currentGroups.mapTo(HashSet(currentGroups.size)) { it.id }
    val reconciled = expandedIds
        .filterTo(LinkedHashSet()) { it in currentIds }
    if (previousGroups == currentGroups) return reconciled
    val previouslyExpandedGroups = previousGroups.filter { it.id in expandedIds }
    if (previouslyExpandedGroups.isEmpty()) return reconciled

    val successorIdsByFile = HashMap<PublishedCameraFileIdentity, MutableSet<String>>()
    currentGroups.forEach { group ->
        group.files.forEach { file ->
            successorIdsByFile
                .getOrPut(file.publishedIdentity()) { LinkedHashSet(1) }
                .add(group.id)
        }
    }
    previouslyExpandedGroups.asSequence()
        .flatMap { it.files.asSequence() }
        .mapNotNull { successorIdsByFile[it.publishedIdentity()] }
        .forEach(reconciled::addAll)
    return reconciled
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ThumbnailGrid(
    groups: List<FileGroup>,
    tasks: List<TransferTask>,
    queuedIndexByHandle: Map<Int, Int>,
    existingExportIndex: ExportedOriginalIndex,
    existingExportRevision: Long,
    organizeTransfersByDate: Boolean,
    activeProgressFlow: StateFlow<ActiveTransferProgress?>,
    columns: Int,
    isLoading: Boolean,
    transfersBusy: Boolean,
    allowRemoteThumbnails: Boolean,
    collapsedDates: MutableMap<String, Boolean>,
    cameraViewModel: CameraViewModel,
    onTransferGroup: (List<NikonCamera.FileInfo>, Rect?) -> Unit,
    onTapFile: (NikonCamera.FileInfo) -> Unit,
    onPreview: (NikonCamera.FileInfo, Rect) -> Unit,
    onPreviewBurst: (String, List<NikonCamera.FileInfo>, Rect) -> Unit,
    tapToPreview: Boolean,
    cellBoundsRegistry: MutableMap<Int, Rect>,
    burstBoundsRegistry: MutableMap<String, Rect>,
    burstHandles: Set<Int>,
    burstIdByHandle: Map<Int, String>,
    collapseBurstPhotos: Boolean,
    expandedBursts: MutableMap<String, Boolean>,
    contentPadding: PaddingValues,
    gridState: LazyGridState,
    modifier: Modifier = Modifier,
    // 筛选入场：确定筛选的瞬间 tick 递增、window 开启 600ms（都在事件回调里同步置起，
    // 晚一帧格子就先以终态闪现穿帮）。窗口内组成的格子重播级联入场——复用分组展开的
    // "瞬时重排 + 级联入场"方案；条目位移动画不可用的原因见下方手风琴注释。
    filterRevealTick: Int = 0,
    filterRevealWindow: Boolean = false,
    exitingExportHandles: Set<Int> = emptySet(),
    exportReflowActive: Boolean = false,
    cameraRemovalReflowActive: Boolean = false,
    cameraRemovalAffectedDates: Set<String> = emptySet(),
    returnFocusHandle: Int? = null,
    returnFocusNonce: Int = 0,
    onExportExitFinished: (Int) -> Unit = {}
) {
    val colors = AppTheme.colors
    val thumbnailSkin = LocalButtonTexturePalette.current?.skin ?: SkinPreset.FROSTED_GLASS
    val thumbnailDark = colors.background.luminance() < 0.5f
    val thumbnailBorderColor = remember(thumbnailSkin, thumbnailDark) {
        thumbnailThemeBorderColor(thumbnailSkin, thumbnailDark)
    }

    // 日期展开/收起动画（手风琴方案；不用条目位移动画——它对"被推出屏幕的条目"有框架级
    // 边缘悬停，对"从屏外移入"的条目又根本不生效，大日期组收起时什么动画都看不到）：
    // - 收起：真实的高度收合。收起瞬间只保留该组当前可见的前 keep 个格子参与动画
    //  （其余在屏外，立即移除、无感知）；这些格子按 collapseProgress 收合高度并淡出，
    //   下方内容随布局逐帧连续上移——是布局本身在变化，不经过位移动画器，无任何钳制。
    //   行间距烘焙在格子内部（底部 6dp），随高度一起收合，动画结束零跳变。
    // - 展开：瞬时重排 + 被展开组格子的级联入场（淡入+放大）。不做反向增高动画：
    //   格子从 0 高度长起时视口会一次性容纳数百行，组合成本爆炸。
    var collapsing by remember { mutableStateOf<CollapsingGroup?>(null) }
    val collapseProgress = remember { Animatable(1f) }
    val toggleScope = rememberCoroutineScope()
    var recentlyExpanded by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(recentlyExpanded) {
        if (recentlyExpanded != null) {
            delay(600)   // 入场窗口：展开瞬间组成的格子播入场，之后滚动进入的不播
            recentlyExpanded = null
        }
    }

    // 连拍展开/收起只做一次原子模型更新。成员的出现/消失与所有存量条目的重排均交给
    // Foundation 1.7 的 LazyGrid animateItem：不裁剪屏外成员、不分批、不逐排改模型。
    val expandedBurstIds = expandedBursts.keys.toSet()
    var burstReflowActive by remember { mutableStateOf(false) }
    var activeBurstReflowId by remember { mutableStateOf<String?>(null) }
    var burstAnimationBusy by remember { mutableStateOf(false) }
    val burstScope = rememberCoroutineScope()
    var burstAnimationJob by remember { mutableStateOf<Job?>(null) }

    // 设置切换会直接替换网格展示模型；取消尚未完成的展开/收起任务，避免旧协程
    // 在新模型生效后晚一帧写回展开状态或留下半程 placement 动画。
    LaunchedEffect(collapseBurstPhotos) {
        burstAnimationJob?.cancel()
        burstAnimationJob = null
        burstAnimationBusy = false
        burstReflowActive = false
        activeBurstReflowId = null
    }

    val itemsByDate = remember(
        groups,
        burstIdByHandle,
        collapseBurstPhotos,
        expandedBurstIds
    ) {
        groups.associate { group ->
            group.date to buildThumbnailGridItems(
                files = group.files,
                burstIdByHandle = burstIdByHandle,
                collapseBurstPhotos = collapseBurstPhotos,
                expandedBurstIds = expandedBurstIds
            )
        }
    }

    // “未传输”筛选的单格退场原本由 ThumbnailCell 回调完成。折叠合集里的成员不会
    // compose，必须在这里直接结算，否则它会永远滞留在过滤快照中。
    val hiddenBurstHandles = remember(itemsByDate, expandedBurstIds) {
        itemsByDate.values.asSequence()
            .flatten()
            .filterIsInstance<ThumbnailGridItem.BurstCollection>()
            .filter { it.id !in expandedBurstIds }
            .flatMap { it.files.asSequence() }
            .mapTo(HashSet()) { it.handle }
    }
    val hiddenExitingHandles = exitingExportHandles.intersect(hiddenBurstHandles)
    LaunchedEffect(hiddenExitingHandles) {
        hiddenExitingHandles.forEach(onExportExitFinished)
    }

    val toggleBurstCollection: (String) -> Unit = { burstId ->
        if (!burstAnimationBusy && collapsing == null && !cameraRemovalReflowActive) {
            burstAnimationBusy = true
            burstAnimationJob = burstScope.launch {
                try {
                    val exists = itemsByDate.values.asSequence()
                        .flatten()
                        .filterIsInstance<ThumbnailGridItem.BurstCollection>()
                        .any { it.id == burstId }
                    if (!exists) return@launch

                    // 先让所有条目的 animateItem 节点进入同一个重排窗口，再在下一帧只提交
                    // 一次最终列表。无论连拍有几张，所有既有照片、合集和标题共享同一起点。
                    activeBurstReflowId = burstId
                    burstReflowActive = true
                    withFrameNanos { }
                    if (expandedBursts[burstId] == true) {
                        expandedBursts.remove(burstId)
                    } else {
                        expandedBursts[burstId] = true
                    }
                    delay((BURST_REFLOW_DURATION_MS + 48).toLong())
                } finally {
                    burstReflowActive = false
                    activeBurstReflowId = null
                    burstAnimationBusy = false
                }
            }
        }
    }

    // 后台缩略图填充已移入 CameraViewModel.startThumbnailFill（与连接同生共死、
    // 与页面无关——停在队列页也照常推进）；本页只负责可见格子的即时加载。

    LazyVerticalGrid(
        state = gridState,
        columns = GridCells.Fixed(columns.coerceIn(1, 4)),
        modifier = modifier,
        contentPadding = contentPadding,
        // 竖向行距烘焙在每个格子底部（6dp），随收合动画一起缩放；这里只留横向间距。
        horizontalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        groups.forEach { group ->
            val collapsed = collapsedDates[group.date] == true
            val collapsingThis = collapsing?.date == group.date
            val groupItems = itemsByDate[group.date].orEmpty()
            // Camera-side deletion only animates the date group that actually changed. Other date
            // groups must not acquire per-cell placement work merely because an earlier group shrank.
            val cameraRemovalAffectsGroup = cameraRemovalReflowActive &&
                group.date in cameraRemovalAffectedDates
            // 所有既有格位——照片、合集、日期标题——严格共享同一个 placementSpec。
            // 空闲时传 null，但 animateItem 节点始终存在，不会因临时挂载 modifier 错帧。
            val placementSpec = when {
                collapsingThis -> null
                burstReflowActive -> tween<IntOffset>(
                    durationMillis = BURST_REFLOW_DURATION_MS,
                    easing = FastOutSlowInEasing
                )
                cameraRemovalAffectsGroup -> tween<IntOffset>(
                    durationMillis = CAMERA_REMOVAL_REFLOW_DURATION_MS,
                    easing = FastOutSlowInEasing,
                )
                exportReflowActive -> tween<IntOffset>(
                    durationMillis = 280,
                    easing = FastOutSlowInEasing
                )
                else -> null
            }
            // 分组头整行跨列，保持与列表模式一致的分组语义
            item(
                span = { GridItemSpan(maxLineSpan) },
                key = "header_${group.date}",
                contentType = "header"
            ) {
                Column(
                    modifier = Modifier.animateItem(
                        fadeInSpec = if (cameraRemovalAffectsGroup) {
                            tween(CAMERA_REMOVAL_ENTER_DURATION_MS, easing = FastOutSlowInEasing)
                        } else {
                            null
                        },
                        placementSpec = placementSpec,
                        fadeOutSpec = if (cameraRemovalAffectsGroup) {
                            tween(CAMERA_REMOVAL_EXIT_DURATION_MS, easing = FastOutSlowInEasing)
                        } else {
                            null
                        },
                    )
                ) {
                    Spacer(modifier = Modifier.height(4.dp))
                    GroupHeader(
                        group = group,
                        // 收合动画进行中箭头即刻转向，不等动画结束。
                        collapsed = collapsed || collapsingThis,
                        onToggleCollapse = {
                            // 日期与连拍都在改变同一网格布局，任一收合进行中都忽略再次点击，
                            // 防止两套高度动画同帧竞争。
                            if (collapsing == null && !burstAnimationBusy &&
                                !cameraRemovalReflowActive
                            ) {
                                if (collapsed) {
                                    // 展开：瞬时重排 + 该组格子级联入场。
                                    recentlyExpanded = group.date
                                    collapsedDates[group.date] = false
                                } else {
                                    recentlyExpanded = null
                                    toggleScope.launch {
                                        // 只保留当前可见的格子（+一行缓冲）参与收合动画。
                                        val visibleKeys = gridState.layoutInfo.visibleItemsInfo
                                            .mapTo(HashSet()) { it.key }
                                        val lastVisible = groupItems.indexOfLast { it.key in visibleKeys }
                                        if (lastVisible < 0) {
                                            collapsedDates[group.date] = true
                                        } else {
                                            collapsing = CollapsingGroup(group.date, lastVisible + 1 + columns)
                                            collapseProgress.snapTo(1f)
                                            collapseProgress.animateTo(0f, tween(300, easing = FastOutSlowInEasing))
                                            collapsedDates[group.date] = true
                                            collapsing = null
                                        }
                                    }
                                }
                            }
                        },
                        onTransferGroup = onTransferGroup
                    )
                    // 头到首行的间距（行距已烘焙进格子底部，这里补足到与原 spacedBy 一致）。
                    Spacer(modifier = Modifier.height(10.dp))
                }
            }
            // 收起的分组不 emit cell：ThumbnailCell 不 compose → 不触发 GetThumb，
            // 从而"锁起来"的缩略图不加载；展开后 cell 重新 emit 才恢复加载。
            // 收合动画期间保留可见的前 keep 个格子，随 collapseProgress 收合。
            if (!collapsed || collapsingThis) {
                val displayedItems = if (collapsingThis) {
                    groupItems.take(collapsing?.keep ?: 0)
                } else groupItems
                itemsIndexed(
                    displayedItems,
                    key = { _, item -> item.key },
                    contentType = { _, item -> item.reuseContentType }
                ) { index, item ->
                    // 照片与合集必须由完全相同的外层节点拥有尺寸和 placement 动画。
                    // 只有本次操作合集的成员允许淡入/淡出。其他已展开合集即使被重排，
                    // 也只使用与普通照片相同的 placement，不能重新触发透明度动画。
                    val animateBurstMemberAppearance =
                        burstReflowActive &&
                            item is ThumbnailGridItem.Photo &&
                            item.burstId == activeBurstReflowId
                    Box(
                        modifier = Modifier
                            .animateItem(
                                fadeInSpec = if (animateBurstMemberAppearance) {
                                    tween(
                                        BURST_MEMBER_ENTER_DURATION_MS,
                                        easing = FastOutSlowInEasing
                                    )
                                } else if (cameraRemovalAffectsGroup) {
                                    tween(
                                        CAMERA_REMOVAL_ENTER_DURATION_MS,
                                        easing = FastOutSlowInEasing,
                                    )
                                } else {
                                    null
                                },
                                placementSpec = placementSpec,
                                fadeOutSpec = if (animateBurstMemberAppearance) {
                                    tween(
                                        BURST_MEMBER_EXIT_DURATION_MS,
                                        easing = FastOutSlowInEasing
                                    )
                                } else if (cameraRemovalAffectsGroup) {
                                    tween(
                                        CAMERA_REMOVAL_EXIT_DURATION_MS,
                                        easing = FastOutSlowInEasing,
                                    )
                                } else {
                                    null
                                }
                            )
                            .then(
                                if (collapsingThis) {
                                    Modifier.collapseHeight { collapseProgress.value }
                                } else {
                                    Modifier
                                }
                            )
                            .padding(bottom = 6.dp)
                            .aspectRatio(1f)
                    ) {
                        when (item) {
                            is ThumbnailGridItem.BurstCollection -> {
                                val expanded = expandedBursts[item.id] == true
                                BurstCollectionCell(
                                    collectionId = item.id,
                                    files = item.files,
                                    expanded = expanded,
                                    transfersBusy = transfersBusy,
                                    allowRemoteThumbnails = allowRemoteThumbnails,
                                    cameraViewModel = cameraViewModel,
                                    onTransferGroup = onTransferGroup,
                                    onToggle = { toggleBurstCollection(item.id) },
                                    onPreviewFirst = { rect ->
                                        onPreviewBurst(item.id, item.files, rect)
                                    },
                                    onBoundsChanged = { bounds ->
                                        if (bounds == null) burstBoundsRegistry.remove(item.id)
                                        else burstBoundsRegistry[item.id] = bounds
                                    },
                                    modifier = Modifier.fillMaxSize()
                                )
                            }
                            is ThumbnailGridItem.Photo -> {
                                val file = item.file
                                val transferred = remember(
                                    file,
                                    existingExportIndex,
                                    existingExportRevision,
                                    organizeTransfersByDate,
                                ) {
                                    isTransferredOriginal(
                                        file,
                                        existingExportIndex,
                                        organizeTransfersByDate,
                                    )
                                }
                                ThumbnailCell(
                                    file = file,
                                    task = queuedIndexByHandle[file.handle]
                                        ?.let(tasks::getOrNull)
                                        ?.takeIf { it.file.handle == file.handle },
                                    transferred = transferred,
                                    activeProgressFlow = activeProgressFlow,
                                    themeBorderColor = thumbnailBorderColor,
                                    transfersBusy = transfersBusy,
                                    allowRemoteThumbnail = allowRemoteThumbnails,
                                    cameraViewModel = cameraViewModel,
                                    onTapFile = onTapFile,
                                    onPreview = onPreview,
                                    tapToPreview = tapToPreview,
                                    cellBoundsRegistry = cellBoundsRegistry,
                                    inBurst = file.handle in burstHandles,
                                    animateBurstBadgeRemoval = cameraRemovalAffectsGroup,
                                    inExpandedBurstCollection =
                                        collapseBurstPhotos &&
                                            item.burstId != null &&
                                            item.burstId in expandedBurstIds,
                                    // 连拍展开不参与缩放；这里只保留原有日期与筛选入场。
                                    reveal =
                                        group.date == recentlyExpanded || filterRevealWindow,
                                    revealDelayMs = (index.coerceAtMost(18) * 15).toLong(),
                                    revealKey = filterRevealTick,
                                    exiting = file.handle in exitingExportHandles,
                                    returnFocusNonce = returnFocusNonce.takeIf {
                                        returnFocusHandle == file.handle
                                    },
                                    onExitFinished = onExportExitFinished,
                                    modifier = Modifier.fillMaxSize()
                                )
                            }
                        }
                    }
                }
            }
        }

        if (isLoading) {
            item(span = { GridItemSpan(maxLineSpan) }) { LoadingMoreRow() }
        }
    }
}

@Composable
private fun BurstCollectionCell(
    collectionId: String,
    files: List<NikonCamera.FileInfo>,
    expanded: Boolean,
    transfersBusy: Boolean,
    allowRemoteThumbnails: Boolean,
    cameraViewModel: CameraViewModel,
    onTransferGroup: (List<NikonCamera.FileInfo>, Rect?) -> Unit,
    onToggle: () -> Unit,
    onPreviewFirst: (Rect) -> Unit,
    onBoundsChanged: (Rect?) -> Unit,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    val a11y = stringResource(R.string.burst_collection_a11y, files.size)
    // 两个坐标都只在点击/长按瞬间读取，使用普通容器避免列表滚动时的全局坐标变化
    // 触发合集卡重组。合集 registry 同样是普通 Map，更新本身不使网格重组。
    val plusBoundsRef = remember { arrayOfNulls<Rect>(1) }
    val collectionBoundsRef = remember { arrayOfNulls<Rect>(1) }
    val latestOnPreviewFirst by rememberUpdatedState(onPreviewFirst)
    val latestOnBoundsChanged by rememberUpdatedState(onBoundsChanged)
    DisposableEffect(collectionId) {
        // LazyGrid 可复用同 contentType 的组合槽；以真实 id 为 key，复用到下一合集前
        // 先精确清掉旧 id 的坐标，避免普通 HashMap 留下不可见的历史项。
        onDispose { onBoundsChanged(null) }
    }
    val chevronRotation by animateFloatAsState(
        targetValue = if (expanded) 180f else 0f,
        animationSpec = tween(240, easing = FastOutSlowInEasing),
        label = "burstCollectionChevron"
    )

    BoxWithConstraints(
        modifier = modifier
            .onGloballyPositioned {
                if (it.isAttached) {
                    val bounds = it.boundsInRoot()
                    if (bounds.width > 0f && bounds.height > 0f) {
                        collectionBoundsRef[0] = bounds
                        latestOnBoundsChanged(bounds)
                    }
                }
            }
            .semantics { contentDescription = a11y }
    ) {
        val cellWidth = maxWidth
        // 在保持清晰触点的同时收紧视觉尺寸；极窄格子继续按比例缩小，避免两钮相碰。
        val actionSize = when {
            cellWidth < 78.dp -> 30.dp
            cellWidth < 96.dp -> 34.dp
            cellWidth < 132.dp -> 36.dp
            else -> 40.dp
        }
        val actionInset = if (cellWidth < 96.dp) 3.dp else 7.dp
        // 深色主题下照片透过玻璃底过多时按钮轮廓会发虚；只给合集两钮补一层很淡的
        // 圆形暗底，保留玻璃高光与描边。浅色主题完全不变。
        val actionBacking = if (colors.background == DarkAppColors.background) {
            Color.Black.copy(alpha = 0.18f)
        } else {
            Color.Transparent
        }
        AnimatedContent(
            targetState = files,
            // Only these three members are rendered in the stack. A deletion outside them should
            // update the count without recomposing an identical old/new photo stack.
            contentKey = { current -> current.take(3).map { it.publishedIdentity() } },
            transitionSpec = {
                fadeIn(tween(CAMERA_REMOVAL_ENTER_DURATION_MS)) togetherWith
                    fadeOut(tween(CAMERA_REMOVAL_EXIT_DURATION_MS))
            },
            contentAlignment = Alignment.Center,
            label = "burstCollectionFiles",
            modifier = Modifier.fillMaxSize(),
        ) { animatedFiles ->
            Box(modifier = Modifier.fillMaxSize()) {
                val stackFiles = animatedFiles.take(3).reversed()
                stackFiles.forEachIndexed { index, file ->
                    val last = stackFiles.lastIndex
                    val rotation = when (stackFiles.size) {
                        1 -> 0f
                        2 -> if (index == 0) -5f else 3f
                        else -> when (index) {
                            0 -> -6f
                            1 -> 5f
                            else -> 0f
                        }
                    }
                    val x = when {
                        index == last -> 0.dp
                        index % 2 == 0 -> (-4).dp
                        else -> 4.dp
                    }
                    val y = if (index == last) 1.dp else 2.dp
                    BurstStackPhoto(
                        file = file,
                        cameraViewModel = cameraViewModel,
                        transfersBusy = transfersBusy,
                        allowRemoteThumbnail = allowRemoteThumbnails,
                        showPlaceholderIcon = index == last,
                        modifier = Modifier
                            .fillMaxSize(0.86f)
                            .align(Alignment.Center)
                            .offset(x = x, y = y)
                            .graphicsLayer { rotationZ = rotation }
                    )
                }
            }
        }

        // 顶层轻暗角保证角标和底部按钮压在任何照片上都清晰，同时不把照片整体压灰。
        Box(
            modifier = Modifier
                .fillMaxSize(0.86f)
                .align(Alignment.Center)
                .offset(y = 1.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(
                    Brush.verticalGradient(
                        0f to Color.Transparent,
                        0.55f to Color.Transparent,
                        1f to Color.Black.copy(alpha = 0.42f)
                    )
                )
        )

        // 图片区域仅响应长按；普通轻触仍不做任何事。按钮后绘制在更高层，
        // 因而左下入队和右下展开不会被这层手势抢占。
        Box(
            modifier = Modifier
                .fillMaxSize(0.86f)
                .align(Alignment.Center)
                .pointerInput(files.firstOrNull()?.handle) {
                    detectTapGestures(
                        onLongPress = {
                            // 长按只建立“合集 + 成员”的预览快照并直达第一张；底层列表不在
                            // 预览出现前重排，从而不会短暂闪出展开成员或箭头旋转。
                            collectionBoundsRef[0]?.let(latestOnPreviewFirst)
                        }
                    )
                }
        )

        BurstCollectionBadge(
            count = files.size,
            iconSize = 13.dp,
            modifier = Modifier
                .align(Alignment.TopStart)
                .offset(x = 9.dp, y = 9.dp)
        )

        // 用户指定的位置：左下整组入队，右下展开/收起。按钮直接复用全局 GlassButton；
        // 只有在 4 列极窄格子下按比例缩小，避免两颗触点互相覆盖。
        GlassButton(
            onClick = { onTransferGroup(files, plusBoundsRef[0]) },
            enabled = files.isNotEmpty(),
            shape = CircleShape,
            contentPadding = PaddingValues(0.dp),
            showSheen = false,
            modifier = Modifier
                .align(Alignment.BottomStart)
                .offset(x = actionInset, y = -actionInset)
                .size(actionSize)
                .drawBehind { drawCircle(actionBacking) }
                .onGloballyPositioned {
                    if (it.isAttached) {
                        val bounds = it.boundsInRoot()
                        if (bounds.width > 0f && bounds.height > 0f) {
                            plusBoundsRef[0] = bounds
                        }
                    }
                }
        ) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = Icons.Default.Add,
                    contentDescription = stringResource(R.string.cd_transfer_group),
                    tint = colors.accentBlue,
                    modifier = Modifier.size(actionSize * 0.54f)
                )
            }
        }

        GlassButton(
            onClick = onToggle,
            shape = CircleShape,
            contentPadding = PaddingValues(0.dp),
            showSheen = false,
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .offset(x = -actionInset, y = -actionInset)
                .size(actionSize)
                .drawBehind { drawCircle(actionBacking) }
        ) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Icon(
                    Icons.Default.ChevronRight,
                    contentDescription = stringResource(
                        if (expanded) R.string.cd_collapse else R.string.cd_expand
                    ),
                    tint = colors.accentBlue,
                    modifier = Modifier
                        .size(actionSize * 0.58f)
                        .rotate(chevronRotation)
                )
            }
        }
    }
}

@Composable
internal fun BurstStackPhoto(
    file: NikonCamera.FileInfo,
    cameraViewModel: CameraViewModel,
    transfersBusy: Boolean,
    loadEnabled: Boolean = true,
    allowRemoteThumbnail: Boolean = true,
    showPlaceholderIcon: Boolean,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    val skin = LocalButtonTexturePalette.current?.skin ?: SkinPreset.FROSTED_GLASS
    val dark = colors.background.luminance() < 0.5f
    val borderColor = remember(skin, dark) {
        stackedThumbnailThemeBorderColor(skin, dark)
    }
    var thumbnail by remember(file.handle) {
        mutableStateOf(cameraViewModel.cachedThumbnail(file.handle))
    }
    LaunchedEffect(file.handle, transfersBusy, loadEnabled, allowRemoteThumbnail) {
        if (loadEnabled && thumbnail == null) {
            thumbnail = cameraViewModel.loadThumbnail(file, allowRemoteThumbnail)
        }
    }
    val shape = RoundedCornerShape(10.dp)

    Box(
        modifier = modifier
            .clip(shape)
            .background(colors.thumbPlaceholder)
            .border(THUMBNAIL_THEME_BORDER_WIDTH, borderColor, shape)
    ) {
        thumbnail?.let { image ->
            Image(
                bitmap = image,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
        } ?: if (showPlaceholderIcon) {
            Icon(
                imageVector = if (file.extension == ".mov" || file.extension == ".mp4") {
                    Icons.Default.Movie
                } else {
                    Icons.Default.Image
                },
                contentDescription = null,
                tint = colors.onSurfaceVariant.copy(alpha = 0.38f),
                modifier = Modifier
                    .size(28.dp)
                    .align(Alignment.Center)
            )
        } else {
            Unit
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ThumbnailCell(
    file: NikonCamera.FileInfo,
    task: TransferTask?,
    transferred: Boolean,
    activeProgressFlow: StateFlow<ActiveTransferProgress?>,
    themeBorderColor: Color,
    transfersBusy: Boolean,
    allowRemoteThumbnail: Boolean,
    cameraViewModel: CameraViewModel,
    onTapFile: (NikonCamera.FileInfo) -> Unit,
    onPreview: (NikonCamera.FileInfo, Rect) -> Unit,
    tapToPreview: Boolean,
    cellBoundsRegistry: MutableMap<Int, Rect>,
    modifier: Modifier = Modifier,
    inBurst: Boolean = false,
    animateBurstBadgeRemoval: Boolean = false,
    inExpandedBurstCollection: Boolean = false,
    reveal: Boolean = false,
    revealDelayMs: Long = 0L,
    // 变化即重播入场动画（筛选确定时存量格子也要重播）；平时保持不变。
    revealKey: Any? = null,
    exiting: Boolean = false,
    returnFocusNonce: Int? = null,
    onExitFinished: (Int) -> Unit = {}
) {
    val colors = AppTheme.colors
    // 展开/筛选入场：本组刚被展开或筛选刚确定时淡入+轻微放大、按 revealDelayMs 级联错峰；
    // 平时（滚动进入）revealProgress 初始即 1，直接全显、零开销。
    val revealProgress = remember(revealKey) { Animatable(if (reveal) 0f else 1f) }
    LaunchedEffect(revealKey) {
        if (revealProgress.value < 1f) {
            delay(revealDelayMs)
            revealProgress.animateTo(1f, tween(220))
        }
    }
    // 仅当前完成传输的格子缩小淡出。动画结束后父层才把它加入过滤集合，
    // 因而 LazyGrid 有完整的旧、 新位置可用于其余条目的补位动画。
    val exitProgress = remember(file.handle) { Animatable(1f) }
    val returnFocusPulse = remember(file.handle) { Animatable(0f) }
    val latestOnExitFinished by rememberUpdatedState(onExitFinished)
    LaunchedEffect(exiting) {
        if (exiting) {
            exitProgress.snapTo(1f)
            exitProgress.animateTo(0f, tween(200, easing = FastOutSlowInEasing))
            latestOnExitFinished(file.handle)
        } else if (exitProgress.value != 1f) {
            exitProgress.snapTo(1f)
        }
    }
    // 已加载的缩略图按 handle 记住，transfersBusy 变化不会让它闪回占位。
    var thumbnail by remember(file.handle) {
        // 网格插入/移除大量连拍成员时，可见项可能离开再重新进入组合。直接从缓存恢复，
        // 避免先画一帧占位图、下一帧再换回缩略图造成列表闪烁。
        mutableStateOf(cameraViewModel.cachedThumbnail(file.handle))
    }
    // 传输中仍允许取图，远程请求排到分块间隙；大图打开后只读本地缓存，不再向相机
    // 发 GetThumb。关闭大图时 allowRemoteThumbnail 变回 true，缺图格子自动恢复。
    LaunchedEffect(file.handle, transfersBusy, allowRemoteThumbnail) {
        if (thumbnail == null) {
            thumbnail = cameraViewModel.loadThumbnail(file, allowRemoteThumbnail)
        }
    }
    DisposableEffect(file.handle, cellBoundsRegistry) {
        onDispose {
            cellBoundsRegistry.remove(file.handle)
        }
    }
    LaunchedEffect(returnFocusNonce) {
        if (returnFocusNonce != null) {
            returnFocusPulse.snapTo(0f)
            repeat(2) {
                returnFocusPulse.animateTo(1f, tween(110, easing = FastOutSlowInEasing))
                returnFocusPulse.animateTo(0f, tween(155, easing = FastOutSlowInEasing))
                delay(35)
            }
        }
    }

    val thumbnailShape = RoundedCornerShape(8.dp)
    val thumbnailBorderWidth = if (inExpandedBurstCollection) 1.dp else THUMBNAIL_THEME_BORDER_WIDTH
    val thumbnailBorderColor = if (inExpandedBurstCollection) {
        colors.accentOrange.copy(alpha = 0.92f)
    } else {
        themeBorderColor
    }
    Box(
        modifier = modifier
            .graphicsLayer {
                val revealP = revealProgress.value
                val exitP = exitProgress.value
                alpha = (if (reveal) revealP else 1f) * exitP
                // 只有明确处于日期/筛选 reveal 窗口的格子才允许缩放；普通网格重排
                // 永远保持 1x，避免连拍展开让无关照片整体“缩一下再弹回”。
                val revealScale = if (reveal) 0.94f + 0.06f * revealP else 1f
                val exitScale = 0.82f + 0.18f * exitP
                val s = revealScale * exitScale
                val returnScale = 1f + 0.055f * returnFocusPulse.value
                scaleX = s * returnScale
                scaleY = s * returnScale
            }
            .clip(thumbnailShape)
            .background(colors.thumbPlaceholder)
            .border(
                width = thumbnailBorderWidth,
                color = thumbnailBorderColor,
                shape = thumbnailShape,
            )
            .onGloballyPositioned {
                // 同一份 bounds 双用:长按预览的放大起点 + 打包动画的灵魂起点。
                // 只收有效样本：分离/复用瞬间的零矩形会让动画从屏幕外冒出。
                if (it.isAttached) {
                    val b = it.boundsInRoot()
                    if (b.width > 0f && b.height > 0f) {
                        cellBoundsRegistry[file.handle] = b
                    }
                }
            }
            // 只在这里交换两个既有动作的手势入口；传输校验、入队和预览逻辑保持单一来源。
            .combinedClickable(
                enabled = !exiting,
                onClick = {
                    if (tapToPreview) {
                        cellBoundsRegistry[file.handle]?.let { onPreview(file, it) }
                    } else onTapFile(file)
                },
                onLongClick = {
                    if (tapToPreview) onTapFile(file)
                    else cellBoundsRegistry[file.handle]?.let { onPreview(file, it) }
                }
            )
    ) {
        val image = thumbnail
        if (image != null) {
            Image(
                bitmap = image,
                contentDescription = file.fileName,
                // 黑边已在解码时按实际黑条精确裁除（CameraViewModel.cropLetterbox），
                // Crop 填满格子即为刚好，无需再放大遮边。
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
        } else {
            // 占位：类型角标底色
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = when (file.extension) {
                        ".mov", ".mp4" -> Icons.Default.Movie
                        else -> Icons.Default.Image
                    },
                    contentDescription = null,
                    tint = colors.onSurfaceVariant.copy(alpha = 0.4f),
                    modifier = Modifier.size(28.dp)
                )
            }
        }

        // 左上角类型角标
        Surface(
            shape = RoundedCornerShape(bottomEnd = 6.dp),
            color = when (file.extension) {
                ".jpg" -> colors.accentBlue.copy(alpha = 0.85f)
                ".nef" -> colors.accentPurple.copy(alpha = 0.85f)
                // 视频统一橙色（MOV/MP4 同族）；MP4 原本落到灰底、灰字太不起眼。
                ".mov", ".mp4" -> colors.accentOrange.copy(alpha = 0.85f)
                else -> colors.surfaceVariant.copy(alpha = 0.85f)
            },
            modifier = Modifier.align(Alignment.TopStart)
        ) {
            Text(
                text = file.extension.uppercase().removePrefix("."),
                modifier = Modifier.padding(horizontal = 4.dp, vertical = 1.dp),
                style = MaterialTheme.typography.labelSmall.copy(fontSize = 9.sp, lineHeight = 10.sp),
                fontWeight = FontWeight.Medium,
                color = if (file.extension in TYPE_BADGE_COLORED_EXTS) colors.onAccent else colors.onSurfaceVariant
            )
        }

        // 右上角连拍角标：与左上角类型标签同族的角贴(实色底 + 白色内容),
        // 青绿是连拍的专属色(蓝/紫/橙已被类型占用,绿是传输状态色)。
        // 叠帧图标 + 三条渐短的速度线("嗖"地扫过的拖尾),不用文字也一眼读出
        // "这一串是按住快门快速扫出来的"。算法见 computeBurstGroups。
        // 普通照片不常驻一套 AnimatedVisibility；只有连拍成员和本次受影响组保留，
        // 既能让展开后的幸存照片平滑退掉连拍角标，也不给全列表增加空动画节点。
        if (inBurst || animateBurstBadgeRemoval) {
            AnimatedVisibility(
                visible = inBurst,
                enter = fadeIn(tween(CAMERA_REMOVAL_ENTER_DURATION_MS)) + scaleIn(
                    animationSpec = tween(CAMERA_REMOVAL_ENTER_DURATION_MS),
                    initialScale = 0.82f,
                ),
                exit = fadeOut(tween(CAMERA_REMOVAL_EXIT_DURATION_MS)) + scaleOut(
                    animationSpec = tween(CAMERA_REMOVAL_EXIT_DURATION_MS),
                    targetScale = 0.82f,
                ),
                modifier = Modifier.align(Alignment.TopEnd),
            ) {
                Surface(
                    shape = RoundedCornerShape(bottomStart = 6.dp),
                    color = BurstBadgeColor.copy(alpha = 0.85f),
                ) {
                    // 叠帧图标 + 三条渐短速度线；与筛选面板的连拍胶囊共用 BurstGlyph，保证一致。
                    BurstGlyph(
                        tint = colors.onAccent,
                        modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp)
                    )
                }
            }
        }

        // 左下角保护角标（机内 🔑 选片标记）：黄底深色钥匙,像一枚金钥匙,标注
        // "这张被机内选中/保护"。四角分工:左上类型、右上连拍、左下保护、右下传输状态。
        if (file.isProtected) {
            Surface(
                shape = RoundedCornerShape(topEnd = 6.dp),
                color = ProtectBadgeColor.copy(alpha = 0.9f),
                modifier = Modifier.align(Alignment.BottomStart)
            ) {
                Icon(
                    Icons.Default.Key,
                    contentDescription = stringResource(R.string.filter_protected),
                    tint = Color.Black.copy(alpha = 0.75f),
                    modifier = Modifier
                        .padding(3.dp)
                        .size(11.dp)
                )
            }
        }

        // 只有尚在队列流程中的任务显示遮罩和状态角标；COMPLETED 已经是“目录中存在”，
        // 与历史扫描结果统一交给下方玻璃绿勾，不再保留另一套半透明完成样式。
        val overlayTask = task?.takeIf { showsQueueStatusOverlay(it.status) }
        // lastTask 保留最后一次的任务，退场动画期间角标仍有内容可渲染。
        var lastTask by remember(file.handle) { mutableStateOf(overlayTask) }
        LaunchedEffect(overlayTask) { if (overlayTask != null) lastTask = overlayTask }
        AnimatedVisibility(
            visible = overlayTask != null,
            enter = fadeIn(tween(150)),
            exit = fadeOut(tween(150)),
            modifier = Modifier.matchParentSize()
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(colors.background.copy(alpha = 0.35f))
            ) {
                (overlayTask ?: lastTask)?.let { t ->
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .padding(4.dp)
                    ) {
                        TransferStatusIndicator(
                            task = t,
                            activeProgressFlow = activeProgressFlow,
                        )
                    }
                }
            }
        }
        AnimatedVisibility(
            visible = transferred && overlayTask == null,
            enter = fadeIn(tween(150)),
            exit = fadeOut(tween(120)),
            modifier = Modifier.align(Alignment.BottomEnd).padding(4.dp),
        ) {
            TransferredIndicator()
        }
        if (returnFocusNonce != null) {
            // 只给目标格子挂一层短命亮度脉冲；alpha 在图层阶段读取，不逐帧重组网格。
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .graphicsLayer { alpha = returnFocusPulse.value * 0.11f }
                    .background(Color.White)
            )
        }
    }
}

/** 已完成任务与目录扫描结果统一使用已传输徽标，其余状态仍属于队列过程。 */
internal fun showsQueueStatusOverlay(status: TransferStatus): Boolean =
    when (status) {
        TransferStatus.COMPLETED -> false
        TransferStatus.WAITING,
        TransferStatus.TRANSFERING,
        TransferStatus.FAILED,
        TransferStatus.CANCELLED -> true
    }

@Composable
internal fun TransferredIndicator() {
    val colors = AppTheme.colors
    // 已传输是状态徽标而不是可点击按钮：复用全局玻璃材质，但不挂点击、投影或按压反馈。
    // heavy 实底保证叠在任何明暗照片上都清楚，绿色细边与对号共同表达“已完成”。
    GlassSurface(
        modifier = Modifier.size(24.dp),
        shape = CircleShape,
        active = true,
        activeColor = colors.statusConnected,
        tint = colors.glassSurfaceHeavy,
        borderColor = colors.statusConnected.copy(alpha = 0.72f)
    ) {
        Icon(
            Icons.Default.Check,
            contentDescription = null,
            tint = colors.statusConnected,
            modifier = Modifier
                .align(Alignment.Center)
                .size(15.dp)
        )
    }
}

/** 经典 USB 三叉标：箭头、圆点和方形分别作为三条分支端点。 */
@Composable
internal fun ClassicUsbIcon(
    tint: Color,
    modifier: Modifier = Modifier
) {
    val description = stringResource(R.string.connection_usb)
    Canvas(modifier = modifier.semantics { contentDescription = description }) {
        val unit = size.minDimension
        val stroke = unit * 0.11f
        val centerX = size.width * 0.5f
        val junctionY = size.height * 0.62f

        drawLine(
            color = tint,
            start = Offset(centerX, size.height * 0.84f),
            end = Offset(centerX, size.height * 0.22f),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
        drawLine(
            color = tint,
            start = Offset(centerX, junctionY),
            end = Offset(size.width * 0.25f, size.height * 0.48f),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
        drawLine(
            color = tint,
            start = Offset(centerX, size.height * 0.52f),
            end = Offset(size.width * 0.76f, size.height * 0.38f),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
        drawLine(
            color = tint,
            start = Offset(size.width * 0.76f, size.height * 0.38f),
            end = Offset(size.width * 0.76f, size.height * 0.25f),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )

        val arrow = Path().apply {
            moveTo(centerX, size.height * 0.08f)
            lineTo(size.width * 0.36f, size.height * 0.27f)
            lineTo(size.width * 0.64f, size.height * 0.27f)
            close()
        }
        drawPath(arrow, tint)
        drawCircle(
            color = tint,
            radius = unit * 0.09f,
            center = Offset(size.width * 0.22f, size.height * 0.46f)
        )
        drawRect(
            color = tint,
            topLeft = Offset(size.width * 0.68f, size.height * 0.10f),
            size = androidx.compose.ui.geometry.Size(unit * 0.16f, unit * 0.16f)
        )
    }
}

@Composable
private fun LoadingMoreRow() {
    val colors = AppTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically
    ) {
        CircularProgressIndicator(
            modifier = Modifier.size(20.dp),
            color = colors.accentBlue,
            strokeWidth = 2.dp
        )
        Spacer(modifier = Modifier.width(8.dp))
        Text(stringResource(R.string.loading_more), style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
    }
}

private fun formatDateHeader(date: String): String {
    if (date.length < 8 || date == UNKNOWN_DATE_KEY) return date
    return "${date.substring(0, 4)}-${date.substring(4, 6)}-${date.substring(6, 8)}"
}

/** 大图打开时，底层照片网格只能读本地缓存，不能继续向相机取缩略图。 */
internal fun allowGridRemoteThumbnails(previewOpen: Boolean): Boolean = !previewOpen

/**
 * 类型/标记/日期筛选浮层。主面板保持紧凑；日期页上下同时展示开始、结束两组三波轮，
 * 编辑期间只改草稿，完成时才一次提交，避免滚动波轮时反复重排列表与后台请求。
 * 类型语义：勾"全部"= 不过滤（未来出现的新类型也放行）；点具体类型自动脱离"全部"；
 * 全不选或凑齐全部现有类型时自动归位"全部"（不允许空集）。
 * 面板随开合重建，每次打开都从当前设置初始化。
 */
@Composable
private fun FilterOverlay(
    anchorBounds: Rect,
    availableExts: List<String>,
    current: PhotoFilterCriteria,
    storageSlots: List<Int>,
    suggestedDate: LocalDate?,
    hapticsEnabled: Boolean,
    onChange: (PhotoFilterCriteria) -> Unit,
    onDismiss: () -> Unit
) {
    val colors = AppTheme.colors
    val density = LocalDensity.current
    var editingDate by remember { mutableStateOf(false) }
    val screenWidth = LocalConfiguration.current.screenWidthDp.dp
    val panelWidth = minOf(
        FILTER_PANEL_MAX_WIDTH,
        screenWidth - FILTER_PANEL_SCREEN_MARGIN * 2,
    )
    // 顶边贴按钮下缘 + 8dp；左缘对齐按钮，但不许超出屏幕右缘（信号条展开把按钮推得很靠右/
    // 窄屏时，面板整体向左钳制到贴边 12dp）。
    val panelTop = with(density) { anchorBounds.bottom.toDp() } + 8.dp
    val panelStart = with(density) { anchorBounds.left.toDp() }
        .coerceAtMost(screenWidth - panelWidth - FILTER_PANEL_SCREEN_MARGIN)
        .coerceAtLeast(FILTER_PANEL_SCREEN_MARGIN)

    // 外部“一键清除”发生时同步丢弃面板草稿，不能让旧日期范围继续存活。
    var working by remember(current) { mutableStateOf(current) }

    val otherLabel = stringResource(R.string.filter_other)
    fun extLabel(ext: String) = ext.removePrefix(".").uppercase().ifEmpty { otherLabel }
    fun commit(next: PhotoFilterCriteria) {
        if (next == working) return
        working = next
        onChange(next)
    }
    fun toggle(ext: String) {
        val cur = working.extensions ?: availableExts.toSet()
        val next = if (ext in cur) cur - ext else cur + ext
        val normalized = when {
            next.isEmpty() -> null                       // 全不选无意义，归位"全部"
            next.containsAll(availableExts) -> null      // 凑齐全部现有类型 = 全部
            else -> next
        }
        commit(working.copy(extensions = normalized))
    }

    AnchorPopup(
        anchorBounds = anchorBounds,
        onDismiss = onDismiss,
        panelModifier = Modifier
            .padding(start = panelStart, top = panelTop)
            .width(panelWidth),
        animateScale = false,
        shape = RoundedCornerShape(16.dp),
        dim = false,
    ) { _ ->
        AnimatedContent(
            targetState = editingDate,
            transitionSpec = {
                fadeIn(tween(150)) togetherWith fadeOut(tween(100)) using SizeTransform(clip = false)
            },
            label = "filterDateEditor",
        ) { showDateEditor ->
            if (showDateEditor) {
                DateRangeEditor(
                    current = working.dateRange,
                    suggestedDate = suggestedDate,
                    hapticsEnabled = hapticsEnabled,
                    onBack = { editingDate = false },
                    onApply = { range ->
                        commit(working.copy(dateRange = range))
                        editingDate = false
                    },
                )
            } else {
                Column(
                    modifier = Modifier.padding(14.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        FilterMark(
                            modifier = Modifier.size(18.dp),
                            color = colors.accentBlue,
                        )
                        Text(
                            text = stringResource(R.string.filter_title),
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.SemiBold,
                            color = colors.onBackground,
                        )
                    }

                    Spacer(Modifier.height(14.dp))

                    FilterSectionLabel(
                        label = stringResource(R.string.filter_section_file_type),
                    )
                    Spacer(Modifier.height(8.dp))

                    // ---- 类型：全部 + 各扩展名，短标签最多五列，保持原有多选语义 ----
                    val typeChips: List<Triple<String, Boolean, () -> Unit>> = buildList {
                        add(Triple(stringResource(R.string.filter_all), working.extensions == null) {
                            if (working.extensions != null) {
                                commit(working.copy(extensions = null))
                            }
                        })
                        availableExts.forEach { ext ->
                            add(Triple(extLabel(ext), working.extensions?.contains(ext) ?: true) { toggle(ext) })
                        }
                    }
                    val typeColumnCount = minOf(5, typeChips.size.coerceAtLeast(1))
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        typeChips.chunked(typeColumnCount).forEach { rowChips ->
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                rowChips.forEach { (label, selected, onClick) ->
                                    FilterChip(label, selected, onClick, Modifier.weight(1f))
                                }
                                repeat(typeColumnCount - rowChips.size) {
                                    Spacer(Modifier.weight(1f))
                                }
                            }
                        }
                    }

                    FilterSectionDivider()

                    FilterSectionLabel(
                        label = stringResource(R.string.filter_section_status),
                    )
                    Spacer(Modifier.height(8.dp))

                    // ---- 标记：保护 / 连拍 / 未传输（独立开关，与日期和类型叠加）----
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(
                            label = stringResource(R.string.filter_protected),
                            selected = working.protectedOnly,
                            onClick = {
                                commit(working.copy(protectedOnly = !working.protectedOnly))
                            },
                            modifier = Modifier.weight(1f),
                            icon = Icons.Default.Key
                        )
                        FilterChip(
                            label = stringResource(R.string.burst_label),
                            selected = working.burstOnly,
                            onClick = {
                                commit(working.copy(burstOnly = !working.burstOnly))
                            },
                            modifier = Modifier.weight(1f),
                            leading = { tint -> BurstGlyph(tint = tint) }
                        )
                        FilterChip(
                            label = stringResource(R.string.filter_untransferred),
                            selected = working.untransferredOnly,
                            onClick = {
                                commit(working.copy(untransferredOnly = !working.untransferredOnly))
                            },
                            modifier = Modifier.weight(1f),
                            leading = { tint -> UntransferredGlyph(tint = tint) },
                        )
                    }

                    if (storageSlots.isNotEmpty()) {
                        FilterSectionDivider()

                        FilterSectionLabel(
                            label = stringResource(R.string.filter_section_storage),
                        )
                        Spacer(Modifier.height(8.dp))

                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            storageSlots.forEach { slot ->
                                FilterChip(
                                    label = stringResource(R.string.filter_storage_slot, slot),
                                    selected = isStorageSlotSelected(working.storageSlot, slot),
                                    onClick = {
                                        commit(
                                            working.copy(
                                                storageSlot = toggleStorageSlotSelection(
                                                    selectedSlot = working.storageSlot,
                                                    toggledSlot = slot,
                                                    availableSlots = storageSlots,
                                                )
                                            )
                                        )
                                    },
                                    modifier = Modifier.weight(1f),
                                )
                            }
                            if (storageSlots.size == 1) Spacer(Modifier.weight(1f))
                        }
                    }

                    FilterSectionDivider()

                    FilterSectionLabel(
                        label = stringResource(R.string.filter_section_date),
                    )
                    Spacer(Modifier.height(8.dp))

                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(
                            label = compactDateRangeLabel(working.dateRange)
                                ?: stringResource(R.string.filter_date),
                            selected = working.dateRange != null,
                            onClick = { editingDate = true },
                            modifier = Modifier.weight(1f),
                            icon = Icons.Default.DateRange,
                        )
                        if (working.dateRange != null) {
                            FilterClearButton(
                                onClick = { commit(working.copy(dateRange = null)) },
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FilterSectionLabel(
    label: String,
) {
    val colors = AppTheme.colors
    Text(
        text = label,
        style = MaterialTheme.typography.labelMedium,
        fontWeight = FontWeight.SemiBold,
        color = colors.onSurfaceVariant,
    )
}

@Composable
private fun FilterSectionDivider() {
    val colors = AppTheme.colors
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 13.dp, horizontal = 2.dp)
            .height(1.dp)
            .background(colors.glassPanelBorder),
    )
}

@Composable
private fun FilterClearButton(onClick: () -> Unit) {
    val colors = AppTheme.colors
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(9.dp),
        color = colors.surfaceVariant,
        modifier = Modifier.size(38.dp),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(
                imageVector = Icons.Default.Close,
                contentDescription = stringResource(R.string.clear),
                tint = colors.onSurfaceVariant,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

@Composable
private fun DateRangeEditor(
    current: PhotoDateRange?,
    suggestedDate: LocalDate?,
    hapticsEnabled: Boolean,
    onBack: () -> Unit,
    onApply: (PhotoDateRange?) -> Unit,
) {
    val colors = AppTheme.colors
    val haptics = rememberHaptics(hapticsEnabled)
    val initial = current?.endInclusive ?: suggestedDate ?: LocalDate.now()
    // 编辑页进入时快照一次；文件列表仍在渐进加载时 suggestedDate 可能变化，不能把用户
    // 已经拨到一半的草稿重置掉。
    var start by remember { mutableStateOf(current?.start ?: initial) }
    var end by remember { mutableStateOf(current?.endInclusive ?: initial) }

    fun updateStart(next: LocalDate) {
        start = next
        if (next.isAfter(end)) end = next
    }

    fun updateEnd(next: LocalDate) {
        end = next
        if (next.isBefore(start)) start = next
    }

    val minYear = minOf(1990, start.year, end.year)
    val maxYear = maxOf(LocalDate.now().year + 1, start.year, end.year)
    val years = remember(minYear, maxYear) { (minYear..maxYear).toList() }

    Column(
        modifier = Modifier.padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack, modifier = Modifier.size(34.dp)) {
                Icon(
                    Icons.Default.ArrowBack,
                    contentDescription = stringResource(R.string.cd_back),
                    tint = colors.onBackground,
                    modifier = Modifier.size(18.dp),
                )
            }
            Spacer(Modifier.width(4.dp))
            Text(
                stringResource(R.string.date_range),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                color = colors.onBackground,
            )
        }

        DateEndpointWheels(
            label = stringResource(R.string.date_start),
            date = start,
            years = years,
            onDateChanged = ::updateStart,
            onDetent = haptics::tick,
        )

        DateEndpointWheels(
            label = stringResource(R.string.date_end),
            date = end,
            years = years,
            onDateChanged = ::updateEnd,
            onDetent = haptics::tick,
        )

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            GlassButton(
                onClick = { onApply(null) },
                modifier = Modifier.weight(1f).height(40.dp),
                shape = RoundedCornerShape(11.dp),
                panel = true,
            ) {
                Text(stringResource(R.string.clear), color = colors.onSurfaceVariant)
            }
            GlassButton(
                onClick = { onApply(PhotoDateRange.between(start, end)) },
                modifier = Modifier.weight(1f).height(40.dp),
                shape = RoundedCornerShape(11.dp),
                active = true,
                activeColor = colors.accentBlue,
            ) {
                Text(
                    stringResource(R.string.done),
                    color = colors.onBackground,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

@Composable
private fun DateEndpointWheels(
    label: String,
    date: LocalDate,
    years: List<Int>,
    onDateChanged: (LocalDate) -> Unit,
    onDetent: () -> Unit,
) {
    val colors = AppTheme.colors
    val months = remember { (1..12).toList() }
    val days = remember(date.year, date.monthValue) {
        (1..YearMonth.of(date.year, date.monthValue).lengthOfMonth()).toList()
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                label,
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                color = colors.onBackground,
            )
            Spacer(Modifier.weight(1f))
            Text(
                formatLocalDate(date),
                style = MaterialTheme.typography.labelSmall,
                color = colors.onSurfaceVariant,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ReleaseCommitWheel(
                options = years,
                selected = date.year,
                optionLabel = Int::toString,
                onValueCommitted = { onDateChanged(date.withClampedDate(year = it)) },
                onDetent = onDetent,
                label = stringResource(R.string.date_year),
                wheelHeight = DATE_FILTER_WHEEL_HEIGHT,
                modifier = Modifier.weight(1.3f),
            )
            ReleaseCommitWheel(
                options = months,
                selected = date.monthValue,
                optionLabel = { it.toString().padStart(2, '0') },
                onValueCommitted = { onDateChanged(date.withClampedDate(month = it)) },
                onDetent = onDetent,
                label = stringResource(R.string.date_month),
                wheelHeight = DATE_FILTER_WHEEL_HEIGHT,
                modifier = Modifier.weight(1f),
            )
            ReleaseCommitWheel(
                options = days,
                selected = date.dayOfMonth,
                optionLabel = { it.toString().padStart(2, '0') },
                onValueCommitted = { onDateChanged(date.withClampedDate(day = it)) },
                onDetent = onDetent,
                label = stringResource(R.string.date_day),
                wheelHeight = DATE_FILTER_WHEEL_HEIGHT,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

private fun LocalDate.withClampedDate(
    year: Int = this.year,
    month: Int = this.monthValue,
    day: Int = this.dayOfMonth,
): LocalDate {
    val clampedDay = day.coerceAtMost(YearMonth.of(year, month).lengthOfMonth())
    return LocalDate.of(year, month, clampedDay)
}

private fun formatLocalDate(date: LocalDate): String =
    "${(date.year % 100).twoDigits()}/${date.monthValue.twoDigits()}/${date.dayOfMonth.twoDigits()}"

private fun Int.twoDigits(): String = toString().padStart(2, '0')

/**
 * 筛选面板的选中态胶囊：选中 = 主题蓝底 + 反色加粗字；未选 = surfaceVariant 底。
 * 与设置面板的选择胶囊同族语言。
 */
@Composable
internal fun FilterChip(
    label: String? = null,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    // 自定义前导内容（如连拍的 BurstGlyph）；给定内容色，优先于 [icon]。
    leading: (@Composable (Color) -> Unit)? = null
) {
    val colors = AppTheme.colors
    val contentColor = if (selected) colors.onAccent else colors.onSurfaceVariant
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(9.dp),
        color = if (selected) colors.accentBlue else colors.surfaceVariant,
        modifier = modifier.height(38.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(5.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically
        ) {
            when {
                leading != null -> leading(contentColor)
                icon != null -> Icon(icon, contentDescription = null, tint = contentColor, modifier = Modifier.size(14.dp))
            }
            if (label != null) {
                Text(
                    label,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                    maxLines = 1,
                    color = contentColor
                )
            }
        }
    }
}

/**
 * 连拍标志：叠帧图标 + 三条渐短速度线（缩略图右上角标与筛选面板连拍胶囊共用，一处定义两处一致）。
 * [tint] 决定图标与速度线颜色（角标用白、胶囊用内容色）。
 */
@Composable
internal fun BurstGlyph(
    tint: Color,
    modifier: Modifier = Modifier,
    iconSize: Dp = 11.dp
) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(iconSize * 0.18f)
    ) {
        Icon(
            Icons.Default.BurstMode,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(iconSize)
        )
        // 三条渐短的速度线（拖尾越短越靠下）：细、压低到与图标齐高。
        Column(
            verticalArrangement = Arrangement.spacedBy(iconSize * 0.11f),
            horizontalAlignment = Alignment.Start
        ) {
            listOf(0.64f, 0.45f, 0.27f).forEach { ratio ->
                Box(
                    modifier = Modifier
                        .width(iconSize * ratio)
                        .height(iconSize * 0.09f)
                        .clip(CircleShape)
                        .background(tint)
                )
            }
        }
    }
}

/** “未传”标志：向下箭头落入接收槽，表达照片仍等待传入手机。 */
@Composable
private fun UntransferredGlyph(
    tint: Color,
    modifier: Modifier = Modifier,
    iconSize: Dp = 14.dp,
) {
    Canvas(modifier = modifier.size(iconSize)) {
        val stroke = size.minDimension * 0.11f
        val centerX = size.width * 0.5f
        val arrowTipY = size.height * 0.58f
        drawLine(
            color = tint,
            start = Offset(centerX, size.height * 0.12f),
            end = Offset(centerX, arrowTipY),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = tint,
            start = Offset(size.width * 0.31f, size.height * 0.40f),
            end = Offset(centerX, arrowTipY),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = tint,
            start = Offset(size.width * 0.69f, size.height * 0.40f),
            end = Offset(centerX, arrowTipY),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = tint,
            start = Offset(size.width * 0.18f, size.height * 0.67f),
            end = Offset(size.width * 0.18f, size.height * 0.84f),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = tint,
            start = Offset(size.width * 0.18f, size.height * 0.84f),
            end = Offset(size.width * 0.82f, size.height * 0.84f),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = tint,
            start = Offset(size.width * 0.82f, size.height * 0.84f),
            end = Offset(size.width * 0.82f, size.height * 0.67f),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
    }
}

/** 合集数量角标：列表与预览严格共用，仅通过 [iconSize] 等比缩放。 */
@Composable
internal fun BurstCollectionBadge(
    count: Int,
    modifier: Modifier = Modifier,
    iconSize: Dp = 13.dp
) {
    val colors = AppTheme.colors
    Surface(
        shape = RoundedCornerShape(iconSize * 0.69f),
        color = BurstBadgeColor.copy(alpha = 0.9f),
        modifier = modifier
    ) {
        Row(
            modifier = Modifier.padding(
                horizontal = iconSize * 0.46f,
                vertical = iconSize * 0.23f
            ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(iconSize * 0.31f)
        ) {
            BurstGlyph(tint = colors.onAccent, iconSize = iconSize)
            AnimatedContent(
                targetState = count,
                transitionSpec = {
                    (slideInVertically { it / 2 } + fadeIn(tween(140)))
                        .togetherWith(slideOutVertically { -it / 2 } + fadeOut(tween(100)))
                        .using(SizeTransform(clip = true, sizeAnimationSpec = { _, _ -> snap() }))
                },
                label = "burstCollectionCount",
            ) { animatedCount ->
                Text(
                    text = stringResource(R.string.burst_collection_count, animatedCount),
                    style = MaterialTheme.typography.labelSmall.copy(
                        fontSize = (iconSize.value * 0.69f).sp,
                        fontFeatureSettings = "tnum"
                    ),
                    fontWeight = FontWeight.SemiBold,
                    color = colors.onAccent
                )
            }
        }
    }
}

/**
 * 缩略图右下角传输状态角标:统一的暗色圆片承载各状态图形——圆片给图形提供
 * 恒定的对比度,不再让裸图标的可读性赌照片内容的深浅(旧版即是如此,观感过时)。
 * 等待=时钟、传输中=【确定型】进度环(与队列卡片同一进度语义,不再放空转圈)、
 * 完成=绿钩、失败=红色感叹、取消=灰叉;状态切换交叉淡化不硬切。
 * 与左下保护角标同底色,四角的"状态类"标识(左下/右下)共享一种安静的暗片语言,
 * 与"分类类"的彩色角贴(左上类型/右上连拍)分层。
 */
@Composable
internal fun TransferStatusIndicator(
    task: TransferTask,
    activeProgressFlow: StateFlow<ActiveTransferProgress?>,
) {
    val colors = AppTheme.colors
    Box(
        modifier = Modifier
            .size(22.dp)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.45f)),
        contentAlignment = Alignment.Center
    ) {
        Crossfade(targetState = task.status, animationSpec = tween(200), label = "cellStatus") { st ->
            Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxSize()) {
                if (st == TransferStatus.TRANSFERING) {
                    // 只有唯一的活动格子订阅高频进度；其余可见缩略图不会因此重组。
                    val liveProgress by activeProgressFlow.collectAsStateWithLifecycle()
                    val progress = liveProgress
                        ?.takeIf { it.taskId == task.taskId }
                        ?.fraction
                        ?: task.progress
                    // 传输中在列表用确定型进度环（卡片那侧改用下载字形，见 statusGlyph 说明）。
                    // 平滑追值：进度环随进度缓缓扫过，而非一段段硬跳。
                    val animatedProgress = rememberSmoothTransferProgress(
                        targetProgress = progress,
                        resetKey = task.taskId,
                    )
                    CircularProgressIndicator(
                        progress = animatedProgress.value,
                        modifier = Modifier.size(15.dp),
                        color = colors.accentBlue,
                        trackColor = Color.White.copy(alpha = 0.25f),
                        strokeWidth = 2.dp,
                        strokeCap = StrokeCap.Round
                    )
                } else {
                    // 其余状态：字形 + 语义色取自共用的 statusGlyph（与传输页卡片统一）。
                    // 黑圆片提供恒定对比，裸符号直接落在片上、语义色照旧读得清。
                    val (icon, tint) = statusGlyph(st)
                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        tint = tint,
                        modifier = Modifier.size(14.dp)
                    )
                }
            }
        }
    }
}

/** 打包幕的单个"灵魂":从 [bounds](格子原位原尺寸)浮起被吸向 + 按钮;[thumb] = 该格缩略图。 */
private data class PackSoul(val bounds: Rect, val thumb: ImageBitmap?)

/**
 * 一次"入队吸入"动画的参数([id] 供 key 复用隔离),整组与单张共用:
 * [from] = 起飞点根坐标 bounds(整组 = + 按钮,兼灵魂汇聚点;单张 = 该格子);
 * [packs] = 打包幕的各"灵魂"(整组时为该组可见缩略图;单张恒空 = 跳过打包幕);
 * [count] = 承载的文件数——飞行期间从胶囊计数里"押扣"这么多,落袋才释放,
 * 数字在包裹到达那一刻才跳上去(实际传输在点击瞬间已开始,押扣只是显示层);
 * count==1 时摞退化为不倾斜的单卡;
 * [topThumb] = 顶卡缩略图(整组取本次传输顺序第一张;内存缓存引用,null 回退纯色+图标)。
 */
private data class QueueFlight(
    val id: Long,
    val from: Rect,
    val packs: List<PackSoul>,
    val count: Int,
    val topThumb: ImageBitmap?,
    val holdsQueueCount: Boolean = true,
)

// 打包幕最多放飞的缩略图残影数(超出按均匀间隔抽样,视觉密度足够又不糊成一团)。
private const val MAX_PACK_GHOSTS = 8

// 连拍角标专属色(青绿):蓝/紫/橙被类型标签占用、绿是传输状态色,须与两族都区分;
// 实色 0.85 底上配白色内容,深浅主题通用(与金徽标同为"单值双主题"的少数例外)。
// internal:预览大图的左上角连拍角标(PhotoPreview)与此同色。
internal val BurstBadgeColor = Color(0xFF26A69A)

// 保护角标底色(琥珀黄):机内选片/保护标记,黄底配深色钥匙如一枚金钥匙,
// 与彩色分类角贴分层。单值双主题(深浅通用)。
internal val ProtectBadgeColor = Color(0xFFFFC107)

// "吸入"节奏:前段缓(残影凝聚成形、离巢慢),后段陡(加速俯冲进胶囊)——
// 到达时带着冲量,与胶囊的"接住"弹跳在动量上衔接。
internal val QueueFlightEasing = CubicBezierEasing(0.5f, 0f, 0.8f, 0.35f)

/** 列表、单张预览与合集预览共用的入队弧线；只接收像素参数，不持有任何 Compose 状态。 */
internal fun queueFlightBezierPoint(
    progress: Float,
    start: Offset,
    end: Offset,
    liftBasePx: Float,
    maxLiftPx: Float,
    minApexYPx: Float,
    maxBowPx: Float,
    bowFadeDistancePx: Float,
): Offset {
    val t = progress.coerceIn(0f, 1f)
    val dx = abs(end.x - start.x)
    val lift = (0.35f * dx + liftBasePx).coerceAtMost(maxLiftPx)
    val controlY = maxOf(
        minOf(start.y, end.y) - lift,
        (4f * minApexYPx - start.y - end.y) / 2f,
    )
    val bow = maxBowPx * (1f - (dx / bowFadeDistancePx).coerceAtMost(1f))
    val controlX = (start.x + end.x) / 2f - bow
    val remaining = 1f - t
    return Offset(
        x = remaining * remaining * start.x +
            2f * remaining * t * controlX + t * t * end.x,
        y = remaining * remaining * start.y +
            2f * remaining * t * controlY + t * t * end.y,
    )
}

/**
 * "打包 → 吸入"两幕连播:
 * 第一幕(~420ms,吸取灵魂):每张可见照片的半透明本体(原位原尺寸、真实缩略图)
 * 先浮起"出窍",再被 + 按钮平方加速吸走、骤缩、吸入即灭,按传输顺序错峰鱼贯;
 * 组收起时没有可见格子,自动跳过本幕。
 * 第二幕(~560ms):三张错位叠放的卡片摞在 + 按钮处凝聚成形(恰接第一幕收尾),
 * 沿二次贝塞尔弧线加速飞向 [target] 右缘的队列胶囊落点,途中收拢缩小、临近终点
 * 淡出;播完 [onDone] 移除自身并触发胶囊"接住"弹跳。
 * 弧线对任意起点自适应:弧高随行程缩放并钳制峰值不飞出屏幕顶(组头可滚到贴着状态栏);
 * 组头 + 按钮与胶囊几乎同在屏幕右缘竖线上,水平行程越小控制点越向左偏,
 * 把近乎竖直的路径弯成一道向内的弧,避免直上直下的呆板。
 * [target] 是胶囊的承载容器(右缘与胶囊右缘钉死重合,不随胶囊宽度动画抖动),
 * 落点取其右缘内侧即胶囊身上。逐帧只写 graphicsLayer,零重组/重布局。
 */
@Composable
private fun QueueFlightGhost(flight: QueueFlight, target: Rect?, onDone: () -> Unit) {
    val colors = AppTheme.colors
    val pack = remember { Animatable(0f) }
    val progress = remember { Animatable(0f) }
    val currentOnDone by rememberUpdatedState(onDone)
    LaunchedEffect(Unit) {
        // 兜底:落点未知(理论上只在首帧布局前存在)就不播——立即收尾释放押扣,
        // 不让残影按退化坐标乱飞。
        if (target == null) {
            currentOnDone()
            return@LaunchedEffect
        }
        // 打包幕总时间线用线性——各灵魂的错峰窗口均匀推进,吸走的加速感
        // 由窗口内的平方曲线提供(见下),不叠加两层缓动。
        if (flight.packs.isNotEmpty()) {
            pack.animateTo(1f, tween(420, easing = LinearEasing))
        }
        progress.animateTo(1f, tween(560, easing = QueueFlightEasing))
        currentOnDone()
    }

    // ---------- 第一幕:吸取灵魂。每张可见照片的半透明本体(原位原尺寸、真实缩略图)
    // 先从格子里浮起(上移 + 微放大 + 淡入 = 出窍),再被 + 按钮平方加速吸走,
    // 途中骤缩,吸入瞬间消失。按传输顺序错峰,鱼贯归巢。----------
    val n = flight.packs.size
    val density = LocalDensity.current
    flight.packs.forEachIndexed { i, soul ->
        Box(
            modifier = Modifier
                .size(with(density) { soul.bounds.width.toDp() })
                .graphicsLayer {
                    // 错峰窗口:第 i 张在总进度 [i·step, i·step+span] 内走完自己的行程,
                    // 首尾两张恰好铺满 0..1;只有一个灵魂时窗口铺满全程,
                    // 避免"吸完等半拍才起摞"的空档。
                    // 错峰预算 28%:间隔短、重叠多——一波带着次序的同吸,而非逐张排队。
                    val step = if (n <= 1) 0f else 0.28f / (n - 1)
                    val span = if (n <= 1) 1f else 0.72f
                    val t = ((pack.value - i * step) / span).coerceIn(0f, 1f)
                    if (t <= 0f || t >= 1f) {
                        alpha = 0f
                        return@graphicsLayer
                    }
                    // 出窍(前 30% 窗口):原位上浮 10dp、放大到 1.06、淡入到 0.75;
                    // 吸走(后 70%):suck 取平方 = 起步慢、越来越快的吸力。
                    val rise = (t / 0.3f).coerceAtMost(1f)
                    val suckLinear = ((t - 0.3f) / 0.7f).coerceIn(0f, 1f)
                    val suck = suckLinear * suckLinear
                    val sx = soul.bounds.center.x
                    val sy = soul.bounds.center.y - 10.dp.toPx() * rise
                    val ex = flight.from.center.x
                    val ey = flight.from.center.y
                    translationX = sx + (ex - sx) * suck - size.width / 2f
                    translationY = sy + (ey - sy) * suck - size.height / 2f
                    val s = (1f + 0.06f * rise) * (1f - 0.85f * suck)
                    scaleX = s
                    scaleY = s
                    // 半透明的"魂体":出窍时淡入,被吸走途中再轻微变淡,吸入即灭(t=1 归零)。
                    alpha = 0.75f * rise * (1f - 0.3f * suck)
                }
                .clip(RoundedCornerShape(8.dp))
                .background(colors.accentBlue.copy(alpha = 0.4f))
        ) {
            soul.thumb?.let {
                Image(
                    bitmap = it,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize()
                )
            }
        }
    }

    // ---------- 第二幕:卡片摞吸入(打包完成后成形起飞)。----------
    Box(
        modifier = Modifier
            .size(44.dp)
            .graphicsLayer {
                val t = progress.value
                val sx = flight.from.center.x
                val sy = flight.from.center.y
                // 落点：胶囊容器右缘向内 28dp、垂直居中（即常驻胶囊身上）。
                val ex = (target?.right ?: sx) - 28.dp.toPx()
                val ey = target?.center?.y ?: sy
                // 弧高随行程自适应；短横程额外向左弯，且峰值不会飞出状态栏。
                val point = queueFlightBezierPoint(
                    progress = t,
                    start = Offset(sx, sy),
                    end = Offset(ex, ey),
                    liftBasePx = 36.dp.toPx(),
                    maxLiftPx = 90.dp.toPx(),
                    minApexYPx = 12.dp.toPx(),
                    maxBowPx = 52.dp.toPx(),
                    bowFadeDistancePx = 160.dp.toPx(),
                )
                translationX = point.x - size.width / 2f
                translationY = point.y - size.height / 2f
                // 出场"凝聚"微弹(0.7→1,占前 12% 行程,配合缓起的 easing 约有 200ms 成形感),
                // 随后一路收拢缩小。淡出窗口必须极窄(最后 6% 行程):它按路径参数走,
                // 长路径(从屏幕下方点单张)上稍宽的窗口就意味着残影在离胶囊几百像素的
                // 半空消失,看起来像"飞去了错误的位置";6% 配合加速曲线只有最后 ~25ms,
                // 肉眼可见地贴到胶囊上才灭,消失时机恰接胶囊弹跳。
                val appear = (t / 0.12f).coerceAtMost(1f)
                val s = (0.7f + 0.3f * appear) * (1f - 0.62f * t)
                scaleX = s
                scaleY = s
                alpha = appear * (if (t > 0.94f) (1f - t) / 0.06f else 1f)
            }
    ) {
        // 整组(count>1)= 三张错位叠影读作"一摞照片";单张(count==1)只有顶卡一张,
        // 正着飞、不倾斜——"这张照片"本人飞过去。顶卡放缩略图(整组取本次传输顺序
        // 第一张;白描边像相纸),未缓存时回退实色+图标。
        val layers = if (flight.count > 1) 3 else 1
        repeat(layers) { i ->
            val top = i == layers - 1
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .graphicsLayer {
                        if (layers > 1) {
                            rotationZ = (i - 1) * 9f
                            translationX = (i - 1) * 3.dp.toPx()
                            translationY = (1 - i) * 2.dp.toPx()
                        }
                    }
                    .clip(RoundedCornerShape(9.dp))
                    .background(
                        if (top && flight.topThumb == null) colors.accentBlue
                        else colors.accentBlue.copy(alpha = 0.35f)
                    )
                    .then(
                        if (top && flight.topThumb != null) {
                            Modifier.border(
                                1.dp, Color.White.copy(alpha = 0.8f), RoundedCornerShape(9.dp)
                            )
                        } else Modifier
                    )
            ) {
                if (top && flight.topThumb != null) {
                    Image(
                        bitmap = flight.topThumb,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize()
                    )
                }
            }
        }
        if (flight.topThumb == null) {
            Icon(
                Icons.Default.Photo,
                contentDescription = null,
                tint = colors.onAccent,
                modifier = Modifier
                    .size(20.dp)
                    .align(Alignment.Center)
            )
        }
    }
}

/**
 * 连拍检测：
 * 同扩展名内按「拍摄日期 + 文件编号」排序，"编号连续 且 相邻拍摄间隔为 0..1 秒"的
 * 连续段长度 ≥3 视为一组连拍。分组 id 取扩展名、日期、最早文件编号与 handle；
 * 连拍末尾继续增加新照片时保持稳定，展开状态不会因为新照片到达而无故丢失。
 * 不依赖 ObjectInfo.SequenceNumber（机型可能恒填 0），只用文件名编号 + 秒级时间戳,
 * 对 RAW+JPG 双格式连拍两条轨各自成组。O(n log n)，仅在文件列表变化时重算。
 * 已知边界：编号 9999 回卷、跨零点的连拍会被切成两段——都只影响标记完整性，可接受。
 */
internal fun computeBurstGroups(files: List<NikonCamera.FileInfo>): List<BurstPhotoGroup> {
    return detectCameraBurstGroups(files).map { group ->
        BurstPhotoGroup(id = group.id, files = group.files)
    }
}
