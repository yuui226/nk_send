package com.ztransfer.ui.screen

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
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
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
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
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
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
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.ui.theme.*
import com.ztransfer.ui.util.Haptics
import com.ztransfer.ui.util.formatSpeed
import com.ztransfer.ui.util.rememberHaptics
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.PhotoFilterCriteria
import com.ztransfer.viewmodel.PhotoDateRange
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import com.ztransfer.viewmodel.TransferViewModel
import com.ztransfer.viewmodel.currentFileProgress
import com.ztransfer.viewmodel.compactDateRangeLabel
import com.ztransfer.viewmodel.isTransferredOriginal
import com.ztransfer.viewmodel.latestCaptureLocalDate
import com.ztransfer.viewmodel.remainingCount
import com.ztransfer.viewmodel.storageIdsBySlot
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlinx.coroutines.Job
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.YearMonth

data class FileGroup(
    val date: String,
    val files: List<NikonCamera.FileInfo>
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
        override val key: Any = "burst_collection_$id"
    }
}

/** 展开后的队列胶囊内容：完成短标 / 计数（速度+剩余数）；入口图标由主题按钮独立绘制。 */
private enum class PillMode { DONE, COUNTING }

/** 队列入口收起为普通按钮时使用固定材质种子，保证木纹/金属微纹在重组后保持一致。 */
private const val QUEUE_ENTRY_BUTTON_TEXTURE_SEED = 0x2A71E001

// 缩略图后台填充没有任何窗口/视口参数：未传输=从新到旧全量填充；传输中=完全停止。
// 填充逻辑住在 CameraViewModel.startThumbnailFill（与页面无关）。

// 主筛选与日期编辑共用固定宽度，切页时不横向重排面板。
private val FILTER_PANEL_WIDTH = 316.dp
private val DATE_FILTER_WHEEL_HEIGHT = 48.dp

// 有彩色角标底（白字）的类型：其余走灰底灰字。提到顶层，避免每个格子每次重组都新建集合。
private val TYPE_BADGE_COLORED_EXTS = setOf(".jpg", ".nef", ".mov", ".mp4")

// 无拍摄日期文件的分组键（非显示文案，显示时映射到 R.string.unknown_date）。
// 以 "zzz" 开头保证按键降序排序时排在所有 "yyyyMMdd" 日期之前，与原行为一致。
private const val UNKNOWN_DATE_KEY = "zzz_unknown"

// 回到顶部：翻过多少条目（含分组头）才算"够深"；点击回顶时先瞬移到该位置再动画收尾。
private const val BACK_TO_TOP_MIN_INDEX = 30
private const val BACK_TO_TOP_SNAP_INDEX = 24

/** 正在播放收合动画的分组：[date] + 保留参与动画的前 [keep] 个格子（收起瞬间可见的那部分）。 */
private data class CollapsingGroup(val date: String, val keep: Int)

private const val BURST_REFLOW_DURATION_MS = 300
private const val BURST_MEMBER_ENTER_DURATION_MS = 180
private const val BURST_MEMBER_EXIT_DURATION_MS = 150

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

/** 从 Compose 的 Context 逐层向上找到宿主 Activity（返回键退出应用、切语言后 recreate 共用）。 */
internal fun Context.findActivity(): Activity? {
    var ctx: Context? = this
    while (ctx is ContextWrapper) {
        if (ctx is Activity) return ctx
        ctx = ctx.baseContext
    }
    return null
}

fun groupFilesByDate(files: List<NikonCamera.FileInfo>): List<FileGroup> {
    val grouped = files.groupBy { it.captureDate?.take(8) ?: UNKNOWN_DATE_KEY }
    return grouped.map { (date, groupFiles) ->
        FileGroup(date = date, files = groupFiles.sortedByDescending { it.captureDate ?: "" })
    }.sortedByDescending { it.date }
}

@Composable
fun FileListScreen(
    cameraViewModel: CameraViewModel,
    transferViewModel: TransferViewModel,
    onNavigateToTransfer: () -> Unit,
    onNavigateToRemote: () -> Unit
) {
    val state by cameraViewModel.state.collectAsState()
    val transferState by transferViewModel.state.collectAsState()
    val colors = AppTheme.colors
    // 设置以轻量面板呈现（点击左上角 "Z传" 打开），不再跳转独立页面。
    var showSettings by remember { mutableStateOf(false) }
    // 双 Z 标按钮在根坐标系中的边界：设置面板贴其下缘展开（下拉弹窗），并以其中心为动画原点。
    var zAnchor by remember { mutableStateOf<Rect?>(null) }
    // 高级版烟花彩蛋：设置面板里的"高级版"徽标点击时在本页放烟花（与连接页共用实现）。
    val fireworks = rememberFireworksState()
    // "整组吸入"动画：飞行中的卡片摞（可并发多摞）、队列胶囊容器区域（飞行终点）、
    // 胶囊"接住"弹跳（每摞到达 nonce+1，胶囊放大回弹一次）。
    val queueFlights = remember { mutableStateListOf<QueueFlight>() }
    var nextFlightId by remember { mutableStateOf(0L) }
    // 在途文件数(显示层押扣):飞行中的摞承载的文件先不计入胶囊数字,落袋才释放——
    // 数字在包裹到达那一刻跳上去,符合"队列收到了"的直觉;实际传输在点击瞬间已开始。
    var heldFiles by remember { mutableStateOf(0) }
    var queueArea by remember { mutableStateOf<Rect?>(null) }
    // 每个格子在根坐标系的精确 bounds(格子本就为长按预览挂了 onGloballyPositioned,
    // 顺手写进注册表,零额外监听)。普通 HashMap 而非快照状态:只在点击瞬间读取,
    // 滚动期间的高频写入不触发任何重组。滚出屏幕的旧条目用可见 key 过滤,不会误用。
    val cellBoundsRegistry = remember { HashMap<Int, Rect>() }
    var pillCatchNonce by remember { mutableStateOf(0) }
    val pillCatchScale = remember { Animatable(1f) }
    LaunchedEffect(pillCatchNonce) {
        if (pillCatchNonce > 0) {
            pillCatchScale.animateTo(1.18f, tween(110, easing = FastOutSlowInEasing))
            pillCatchScale.animateTo(1f, spring(dampingRatio = Spring.DampingRatioMediumBouncy))
        }
    }
    // 类型筛选下拉：开关 + 筛选按钮在根坐标系中的边界（面板贴其下缘展开）。
    var showFilter by remember { mutableStateOf(false) }
    var filterAnchor by remember { mutableStateOf<Rect?>(null) }
    // 网格滚动状态提升到页面层：回到顶部按钮需要读取滚动位置/方向并驱动滚动。
    val gridState = rememberLazyGridState()
    val scrollScope = rememberCoroutineScope()
    val atTop by remember {
        derivedStateOf {
            gridState.firstVisibleItemIndex == 0 && gridState.firstVisibleItemScrollOffset < 8
        }
    }
    // 监看入口离开顶部后缩进左侧；用户点开后保持完整，继续滚动或回到顶部时重置手动状态。
    var remoteExpandedAwayFromTop by remember { mutableStateOf(false) }
    LaunchedEffect(atTop) {
        if (atTop) remoteExpandedAwayFromTop = false
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
    // 提示条文案在非组合的回调（BackHandler/onClick）里使用，先在组合期取出。
    val exitHint = stringResource(R.string.press_back_to_exit)
    val notConnectedHint = stringResource(R.string.camera_not_connected)
    // 免费版监看时长用完的引导（指向设置里的"高级版"入口），轻提示不打断。
    val remoteEndedHint = stringResource(R.string.remote_trial_ended)
    // 带参数的文案组合期取不到,回调/协程里经 context.getString 现取;返回键退出也用它。
    val context = LocalContext.current

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

    // 文件列表是连接成功后的主页面：返回不回到连接页，而是"再按一次退出应用"。
    var lastBackTime by remember { mutableStateOf(0L) }
    BackHandler {
        val now = System.currentTimeMillis()
        if (now - lastBackTime < 2000L) {
            context.findActivity()?.finish()
        } else {
            lastBackTime = now
            showHint(exitHint)
        }
    }
    // 筛选浮层的返回键收起由 FilterOverlay 内部（AnchorPopup 的 BackHandler）处理，此处不再拦截。

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
    val visibleStorageSlots = remember(storageIdBySlot, filterStorageSlot) {
        when {
            BuildConfig.DEBUG -> listOf(1, 2)
            storageIdBySlot.size > 1 -> storageIdBySlot.keys.sorted()
            filterStorageSlot != null -> listOf(filterStorageSlot)
            else -> emptyList()
        }
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

    // 跨相机保留筛选时，完整枚举确认目标卡槽不存在才清除；扫描途中不能误清。
    LaunchedEffect(state.hasCompletedFileScan, storageIdBySlot, filterStorageSlot) {
        if (state.hasCompletedFileScan && filterStorageSlot != null && selectedStorageIds == null) {
            transferViewModel.setFilters(filterCriteria.copy(storageSlot = null))
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
    val availableExts = remember(state.files) {
        state.files.map { it.extension }.distinct().sorted()
    }
    val latestKnownDate = remember(state.files) {
        latestCaptureLocalDate(state.files.asSequence().map { it.captureDate })
    }
    // 连拍检测基于原始列表，只在文件列表变化时重算。角标、筛选和合集都共享这一份
    // 结果，避免三个功能对“哪些照片属于连拍”产生分歧。
    val burstGroups = remember(state.files) { computeBurstGroups(state.files) }
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
    val exportedHandles: Set<Int> = remember(state.files, transferState.existingExportFiles) {
        state.files.asSequence()
            .filter { file ->
                isTransferredOriginal(file, transferState.existingExportFiles)
            }
            .mapTo(HashSet()) { it.handle }
    }
    // “未传输”筛选下，本次队列刚完成的照片先留在网格中播放单格退场，再真正加入过滤集合。
    // 导出目录扫描发现的历史文件不需要动画，仍然同步过滤，避免列表初次加载时闪现旧照片。
    val animatedExportCandidates = remember(transferState.tasks) {
        transferState.tasks.asSequence()
            .filter {
                it.status == TransferStatus.WAITING ||
                    it.status == TransferStatus.TRANSFERING ||
                    it.status == TransferStatus.COMPLETED
            }
            .mapTo(HashSet()) { it.file.handle }
    }
    var finishedExportExitHandles by remember {
        mutableStateOf(exportedHandles.intersect(animatedExportCandidates))
    }
    val exitingExportHandles = remember { mutableStateMapOf<Int, Unit>() }
    var exportReflowActive by remember { mutableStateOf(false) }
    var exportReflowTick by remember { mutableStateOf(0) }
    val filteredExportHandles = remember(
        exportedHandles,
        animatedExportCandidates,
        finishedExportExitHandles
    ) {
        (exportedHandles - animatedExportCandidates) + finishedExportExitHandles
    }

    LaunchedEffect(exportedHandles, animatedExportCandidates, filterUntransferred) {
        finishedExportExitHandles = finishedExportExitHandles.intersect(exportedHandles)
        exitingExportHandles.keys
            .filterNot { it in exportedHandles }
            .forEach(exitingExportHandles::remove)

        if (!filterUntransferred) {
            // 筛选未开启时没有退场语义；先同步基线，防止下次开启时重播历史完成项。
            exitingExportHandles.clear()
            finishedExportExitHandles = exportedHandles.intersect(animatedExportCandidates)
            exportReflowActive = false
        } else {
            val newlyExported = exportedHandles
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
        state.files, filterExts, filterProtected, filterBurst, filterUntransferred,
        filterStorageSlot, selectedStorageIds, filterDateRange,
        burstHandles, filteredExportHandles
    ) {
        val files = state.files.asSequence()
            .filter { filterExts == null || it.extension in filterExts }
            .filter { !filterProtected || it.isProtected }
            .filter { !filterBurst || it.handle in burstHandles }
            .filter { !filterUntransferred || it.handle !in filteredExportHandles }
            .filter { file ->
                filterStorageSlot == null ||
                    selectedStorageIds?.any { storageId -> storageId in file.storageIds } == true
            }
            .filter { filterDateRange == null || filterDateRange.containsCaptureDate(it.captureDate) }
            .toList()
        groupFilesByDate(files)
    }
    // 列表与预览共享同一份“合集是否展开”状态。预览页主动展开后，关闭预览仍能看到
    // 底层列表已展开；反之亦然。合集关闭设置时，模型退化为原来的纯照片序列。
    val expandedBurstCollections = remember { mutableStateMapOf<String, Boolean>() }
    LaunchedEffect(transferState.collapseBurstPhotos, burstGroups) {
        if (!transferState.collapseBurstPhotos) {
            expandedBurstCollections.clear()
        } else {
            val validIds = burstGroups.mapTo(HashSet()) { it.id }
            expandedBurstCollections.keys
                .filterNot { it in validIds }
                .forEach(expandedBurstCollections::remove)
        }
    }
    // 该状态表只保存 true，收起时直接 remove；无需再构造 filterValues 视图。
    val expandedBurstIds = expandedBurstCollections.keys.toSet()
    // 只用一个轻量身份对象追踪“底层展示模型是否还是打开预览时那一版”；真正的预览
    // 分页列表仅在长按发生时构建，避免每次连拍展开都为尚未打开的预览额外扫描全表。
    val previewSourceIdentity = remember(
        groups, burstIdByHandle, transferState.collapseBurstPhotos, expandedBurstIds
    ) { Any() }
    val currentPreviewSourceIdentity by rememberUpdatedState(previewSourceIdentity)
    val transfersBusy = transferState.tasks.any {
        it.status == TransferStatus.WAITING || it.status == TransferStatus.TRANSFERING
    }
    // 触感反馈（开关在设置里，默认开）。
    val haptics = rememberHaptics(transferState.hapticsEnabled)

    // 长按预览：全屏翻页 + 从被长按格子的位置放大展开。
    var previewIndex by remember { mutableStateOf<Int?>(null) }
    var previewAnchor by remember { mutableStateOf<Rect?>(null) }
    var previewSourceAtOpen by remember { mutableStateOf<Any?>(null) }
    var previewBuildJob by remember { mutableStateOf<Job?>(null) }
    // 预览会话固定为打开瞬间的展示模型。“未传输”激活时，当前照片在
    // 后台传完会从网格派生列表移除；若预览仍直接引用实时模型，固定下标会
    // 突然指向下一张，末尾项还会直接让 overlay 消失。快照保证当次浏览稳定，
    // 关闭后底下列表已是最新筛选结果。
    var previewItems by remember { mutableStateOf<List<PhotoPreviewItem>>(emptyList()) }
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
                previewIndex = idx
                previewAnchor = rect
                previewSourceAtOpen = sourceAtOpen
            }
        }
    }
    val onPreviewBurst: (String, List<NikonCamera.FileInfo>, Rect) -> Unit =
        onPreviewBurst@{ burstId, files, rect ->
            val first = files.firstOrNull() ?: return@onPreviewBurst
            // 快照立即包含目标成员，保证底层展开动画尚未提交时也能直接落到第一张；
            // 向左仍可回到合集页。折叠合集的长按会由卡片先触发同一个展开状态机。
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
                    previewIndex = idx
                    previewAnchor = rect
                    previewSourceAtOpen = sourceAtOpen
                }
            }
        }

    // 队列 handle → 最新任务，仅用于列表角标；是否允许再次入队不再由队列状态决定。
    val queuedByHandle = remember(transferState.tasks) {
        transferState.tasks.associateBy { it.file.handle }
    }
    val hasLocalOriginal: (NikonCamera.FileInfo) -> Boolean = { file ->
        isTransferredOriginal(file, transferState.existingExportFiles)
    }
    // 单文件入队：列表轻触 + 预览页传输按钮共用。gating 与整组传输一致。
    val onTapFile: (NikonCamera.FileInfo) -> Unit = onTapFile@{ file ->
        if (transferState.transferDirUri == null) {
            // 预览层盖在设置面板之上，先关掉预览再弹设置，否则用户看不见。
            previewIndex = null
            previewItems = emptyList()
            previewSourceAtOpen = null
            showSettings = true; return@onTapFile
        }
        if (!state.isConnectedToCamera && !hasLocalOriginal(file)) {
            signalPulse++
            showHint(notConnectedHint)
        } else {
            haptics.tick()
            transferViewModel.addToQueue(listOf(file), cameraViewModel::getCamera)
            // 单张"吸入":缩略图从格子位置起飞(count=1 → 单卡无叠影),
            // 同一条弧线进胶囊。预览中格子若仍在注册表则照常飞；滚出屏幕则只入队无动画。
            val fromCell = cellBoundsRegistry[file.handle]
            // 同源去重:同帧双击防重复残影。
            if (file.handle !in queuedByHandle && fromCell != null &&
                queueFlights.none { it.from == fromCell }
            ) {
                queueFlights += QueueFlight(
                    id = nextFlightId++, from = fromCell,
                    packs = emptyList(), count = 1,
                    topThumb = cameraViewModel.cachedThumbnail(file.handle)
                )
                heldFiles += 1
            }
        }
    }

    val onTransferBurstPreview: (List<NikonCamera.FileInfo>) -> Unit =
        onTransferBurstPreview@{ files ->
            val remaining = files
            if (remaining.isEmpty()) return@onTransferBurstPreview
            if (transferState.transferDirUri == null) {
                previewIndex = null
                previewItems = emptyList()
                previewSourceAtOpen = null
                showSettings = true
                return@onTransferBurstPreview
            }
            if (!state.isConnectedToCamera && remaining.any { !hasLocalOriginal(it) }) {
                signalPulse++
                showHint(notConnectedHint)
                return@onTransferBurstPreview
            }
            // 全屏合集没有可信的列表坐标，不伪造飞行动画起点；整组只震一次、直接入队。
            haptics.tick()
            transferViewModel.addToQueue(remaining, cameraViewModel::getCamera)
        }

    // 根需不透明底色：与队列页左右滑动转场期间两页同屏层叠，透明根会让底层页面透出。
    // 用全局背景渐变刷（而非纯 background 色），与 Scaffold 底的纵深一致。
    // 遥控页入口是左下角圆钮（曾试过横滑手势进入，误触率高已去掉）。
    Box(modifier = Modifier.fillMaxSize().background(rememberAppBackgroundBrush())) {
        // ---------- 内容（铺满，延伸到系统栏后面）----------
        if (state.isLoadingFiles && state.files.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(color = colors.accentBlue)
                    Spacer(modifier = Modifier.height(16.dp))
                    Text(stringResource(R.string.loading_file_list), color = colors.onSurfaceVariant)
                }
            }
        }

        if (!state.isLoadingFiles && state.files.isEmpty() &&
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

        if (state.files.isNotEmpty()) {
            // 各日期分组的收起状态（key=日期）。收起的组不渲染其条目/缩略图，
            // 因而缩略图不会加载；展开后条目重新 emit 才恢复加载。跨渐进加载持久保留。
            val collapsedDates = remember { mutableStateMapOf<String, Boolean>() }

            // 分组批量传输。gating 用响应式的 isConnectedToCamera；
            // 队列内部经 provider 现取当前相机实例，中途重连后续传任务自动用新连接。
            // 单文件入队见外层 onTapFile（列表点击与预览页按钮共用）。
            val onTransferGroup: (List<NikonCamera.FileInfo>, Rect?) -> Unit = onTransferGroup@{ remaining, fromBounds ->
                if (transferState.transferDirUri == null) {
                    showSettings = true; return@onTransferGroup
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
                        heldFiles += remaining.size
                    }
                }
            }

            // 筛选后无匹配：给出指认原因的空态（原始列表非空，只是被筛掉了）。
            if (groups.isEmpty() && state.hasCompletedFileScan) {
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
                    }
                }
            }

            ThumbnailGrid(
                groups = groups,
                queuedByHandle = queuedByHandle,
                exportedHandles = exportedHandles,
                columns = transferState.thumbnailColumns,
                isLoading = state.isLoadingFiles,
                transfersBusy = transfersBusy,
                collapsedDates = collapsedDates,
                cameraViewModel = cameraViewModel,
                onTransferGroup = onTransferGroup,
                onTapFile = onTapFile,
                onPreview = onPreview,
                onPreviewBurst = onPreviewBurst,
                tapToPreview = transferState.tapToPreview,
                cellBoundsRegistry = cellBoundsRegistry,
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
        val remoteExpanded = atTop || remoteExpandedAwayFromTop
        val remoteReveal = animateFloatAsState(
            targetValue = if (remoteExpanded) 1f else 0f,
            animationSpec = spring(dampingRatio = 0.58f, stiffness = 360f),
            label = "remoteEntryReveal"
        )
        val remotePeekInteraction = remember { MutableInteractionSource() }
        val density = LocalDensity.current
        val hiddenTravelPx = with(density) { 48.dp.toPx() }
        val playfulLiftPx = with(density) { 6.dp.toPx() }
        val openRemote: () -> Unit = {
            // 端侧录制与照片传输共用同一个 SAF 保存目录。与加入传输队列的
            // 拦截顺序一致：目录未设置时先引导设置，不进入监看后再让用户返工。
            if (transferState.transferDirUri == null) showSettings = true
            else if (transfersBusy) showHint(remoteBlockedHint)
            // 免费版当日监看时长已用完:入口处直接提示,不进页再弹回。
            else if (LicenseManager.remoteTimeLeftMs() <= 0L) showHint(remoteEndedHint)
            else {
                remoteExpandedAwayFromTop = false
                onNavigateToRemote()
            }
        }
        Box(
            modifier = Modifier
                .align(Alignment.BottomStart)
                .navigationBarsPadding()
                .padding(bottom = 40.dp)
                .size(width = 80.dp, height = 56.dp),
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
                    .size(52.dp)
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
                    color = if (transfersBusy) colors.onSurfaceVariant.copy(alpha = 0.5f) else colors.accentBlue,
                    // 收起时由屏内 48dp 热区承担唯一语义，避免无障碍树出现两个同名入口。
                    contentDescription = remoteEntryDescription.takeIf { remoteExpanded }
                )
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
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(topInset + 56.dp)
                .background(
                    // 用 backgroundTop（页面顶端的实际底色）而非名义中间色，
                    // 否则在渐变底上会压出一条色差带。
                    Brush.verticalGradient(
                        0f to colors.backgroundTop.copy(alpha = 0.85f),
                        0.45f to colors.backgroundTop.copy(alpha = 0.5f),
                        1f to Color.Transparent
                    )
                )
        )

        // ---------- 悬浮顶部控件（不占高度，浮在内容上）----------
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // 左：双 Z 标悬浮按钮（原"Z传"文本，换成自绘的尼康 Z 系列标志更简洁），
            // 本身即为设置入口（点击打开设置弹窗）。毛玻璃观感复用 GlassButton。
            GlassButton(
                onClick = { showSettings = true },
                shape = RoundedCornerShape(22.dp),
                // 顶栏按钮统一 36dp 高（与队列胶囊等一致）；标志 20dp + 上下 8dp 正好填满。
                // 水平 padding 与旁边信号按钮同值，宽度刚好包住标志。
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
                // 钛合金主题使用品牌黄填充钢印；其余主题仍保留 ZMark 原本的前景色。
                titaniumStampColor = colors.accentYellow,
                modifier = Modifier
                    .height(36.dp)
                    .onGloballyPositioned { zAnchor = it.boundsInRoot() }
            ) {
                ZMark(modifier = Modifier.height(20.dp))
            }

            // 双 Z 标边上的信号按钮（常驻）：在线显示信号条（点击展开 dBm），断开显示
            // 红色断连图标；断开时点缩略图会放大强调它并弹提示（signalPulse 驱动）。
            Spacer(modifier = Modifier.width(8.dp))
            SignalPill(
                rssi = state.wifiRssi,
                connected = state.isConnectedToCamera,
                pulseTrigger = signalPulse,
                connectionType = state.connectionType
            )

            // 信号按钮右侧：类型筛选按钮。信号条展开/收起的宽度动画是逐帧真实布局，
            // 本按钮随 Row 重排平滑让位，位置天然跟随动画。已设筛选时图标高亮。
            Spacer(modifier = Modifier.width(8.dp))
            val filterMarkColor by animateColorAsState(
                targetValue = if (filterActive) colors.accentYellow else colors.onBackground,
                animationSpec = tween(180),
                label = "filterMarkActive"
            )
            GlassButton(
                onClick = { showFilter = !showFilter },
                shape = RoundedCornerShape(22.dp),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
                active = filterActive,
                activeColor = colors.accentYellow,
                modifier = Modifier
                    .height(36.dp)
                    .onGloballyPositioned { filterAnchor = it.boundsInRoot() }
            ) {
                // 自绘筛选标志（与信号条同族的圆头杆件语言）；已设筛选时高亮。
                FilterMark(
                    modifier = Modifier.size(19.dp),
                    color = filterMarkColor,
                    contentDescription = stringResource(R.string.cd_filter_type)
                )
            }

            // 右：传输胶囊（悬浮）。用"占满剩余宽度 + 靠右对齐"的 Box 承载，
            // 保证胶囊宽度变化时右边缘固定、只向左伸缩，不会向右溢出屏幕。
            // 容器同时是"入队吸入"动画的落点锚（右缘与胶囊右缘钉死重合）。
            Box(
                modifier = Modifier
                    .weight(1f)
                    .onGloballyPositioned {
                        // 分离/复用瞬间的回调会报出零矩形(boundsInRoot 对未附着节点
                        // 返回 Rect.Zero),存下它会让残影飞向屏幕左上角外——只收有效样本。
                        if (it.isAttached) {
                            val b = it.boundsInRoot()
                            if (b.width > 0f && b.height > 0f) queueArea = b
                        }
                    },
                contentAlignment = Alignment.CenterEnd
            ) {
                // 胶囊常驻:队列为空时收成图标态——明确"这里有个队列",也让首次入队的
                // 吸入动画始终有可见落点(曾随 tasks 隐藏,首飞落在空气里)。
                // 读数为 0(押扣在途/全部完成)同样是图标态,不闪不藏。
                // 卡片摞到达时胶囊"接住"弹跳。原点锚在右缘:向左生长,
                // 不会把贴屏幕右缘的胶囊顶出屏幕。
                Box(
                    modifier = Modifier.graphicsLayer {
                        transformOrigin = TransformOrigin(1f, 0.5f)
                        scaleX = pillCatchScale.value
                        scaleY = pillCatchScale.value
                    }
                ) {
                    QueuePill(
                        transferState = transferState,
                        heldCount = heldFiles,
                        haptics = haptics,
                        onClick = onNavigateToTransfer
                    )
                }
            }
        }

        // ---------- "整组吸入"动画层：一摞卡片残影沿弧线飞向队列胶囊，到达即触发胶囊弹跳 ----------
        queueFlights.forEach { flight ->
            key(flight.id) {
                QueueFlightGhost(
                    flight = flight,
                    target = queueArea,
                    onDone = {
                        queueFlights.remove(flight)
                        heldFiles -= flight.count   // 落袋:释放押扣,胶囊数字此刻跳上去
                        pillCatchNonce++
                    }
                )
            }
        }

        // ---------- 类型/标记筛选浮层：从筛选按钮变形弹出、关闭缩回按钮（见 FilterOverlay）----------
        if (showFilter) {
            FilterOverlay(
                anchorBounds = filterAnchor,
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
                    transferViewModel.setFilters(criteria)
                },
                onDismiss = { showFilter = false }
            )
        }

        // 设置面板（点击 "Z传" 或未设目录时弹出），从 "Z传" 按钮位置变形展开。
        if (showSettings) {
            SettingsOverlay(
                viewModel = transferViewModel,
                effectPreviewSource = state.effectPreviewBitmap,
                anchorBounds = zAnchor,
                onDismiss = { showSettings = false },
                onPlayFireworks = { fireworks.launch() },
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
                    // 只有底层列表仍是打开瞬间的同一实例时，原格子坐标才可信。
                    // 传输完成/文件增量加载/合集展开导致展示模型更换后，收起改为原地淡出，
                    // 避免飞向已被其他照片占据的旧位置。引用比较是 O(1)，不扫描大列表。
                    anchorRect = previewAnchor.takeIf { previewSourceAtOpen === previewSourceIdentity },
                    cameraViewModel = cameraViewModel,
                    hapticsEnabled = transferState.hapticsEnabled,
                    initialRotationQuarterTurns = transferState.previewRotationQuarterTurns,
                    burstHandles = burstHandles,
                    onTransfer = onTapFile,
                    onTransferBurst = onTransferBurstPreview,
                    onBurstExpandedChange = { id, expanded ->
                        if (expanded) expandedBurstCollections[id] = true
                        else expandedBurstCollections.remove(id)
                    },
                    onRotationChanged = transferViewModel::setPreviewRotationQuarterTurns,
                    onDismiss = {
                        previewIndex = null
                        previewItems = emptyList()
                        previewSourceAtOpen = null
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
    }
}

@Composable
fun QueuePill(
    transferState: com.ztransfer.viewmodel.TransferState,
    haptics: Haptics,
    onClick: () -> Unit,
    // 显示层押扣:飞行中的"整组包裹"承载的文件数,落袋前不计入读数
    //（数字在包裹到达时才跳上去);实际队列不受影响,仅影响本胶囊显示。
    heldCount: Int = 0
) {
    val colors = AppTheme.colors
    val remaining = (transferState.remainingCount - heldCount).coerceAtLeast(0)
    val allDone = remaining == 0
    val transferring = transferState.isTransferring
    val hasActive = transferState.tasks.any {
        it.status == TransferStatus.TRANSFERING || it.isGeneratingFrame
    }
    // 数字延迟显现：刚入队的任务可能马上被"已存在"跳过（remaining 1→0 一闪而过），
    // 那种情况只播 done→图标转场、不闪数字。真正开始下载(TRANSFERING)立即显示数字；
    // 纯等待超过宽限期（说明确实在排队，如目录扫描慢）也显示。
    var countingVisible by remember { mutableStateOf(false) }
    LaunchedEffect(remaining > 0, hasActive) {
        countingVisible = when {
            hasActive -> true
            remaining > 0 -> { delay(350); true }
            else -> false
        }
    }
    // 进度条 = 当前单文件进度（复用传输页语义）；全部传完时填满。
    val barFraction = if (allDone) 1f else transferState.currentFileProgress
    // 平滑追值：填充宽度随 Motion.progress 弹簧缓动而非硬跳（与传输页进度条/列表进度环同一手感）。
    // 用 State 在 drawBehind 里读 .value：每帧只重绘填充，不触发胶囊重组。
    val animatedBar = animateFloatAsState(
        targetValue = barFraction,
        animationSpec = Motion.progress,
        label = "pillProgress"
    )

    // "done → 图标" 的转场只由"传输中 → 全部完成"触发。prevAllDone 初值取当前 allDone：
    // 若进入本页时已是完成态（例如从队列页返回），不再闪 done，直接显示图标（无转场动画）。
    var showDoneLabel by remember { mutableStateOf(false) }
    var prevAllDone by remember { mutableStateOf(allDone) }
    // 本轮队列是否真的下载过（用于完成震动：纯"已存在跳过"的瞬时完成不震）。
    var sawTransfer by remember { mutableStateOf(false) }
    LaunchedEffect(hasActive) {
        if (hasActive) sawTransfer = true
    }
    // 取消导致的"归零"不是完成：不闪 done、不震成功震（否则取消后出现庆祝反馈，误导）。
    // sawTransfer 在每次归零时都复位，取消那轮的记录不能污染下一轮的完成判定。
    val hasCancelled = transferState.tasks.any { it.status == TransferStatus.CANCELLED }
    LaunchedEffect(allDone) {
        if (allDone && !prevAllDone) {
            val celebrate = !hasCancelled && sawTransfer
            sawTransfer = false
            if (!hasCancelled) {
                if (celebrate) haptics.success()
                showDoneLabel = true
                delay(1800)
                showDoneLabel = false
            }
        }
        prevAllDone = allDone
    }
    // 收起为图标：全部完成（且 done 标签已过），或数字尚未获准显示（防"已存在跳过"闪 1）。
    val collapsedToIcon = (allDone && !showDoneLabel) || (!allDone && !countingVisible)

    // 普通按钮与胶囊共用同一条宽度弹簧。切换材质实现时右缘仍固定，只向左平滑伸缩，
    // 不会因为图标态改用 GlassButton 而丢掉原先的胶囊变形手感。
    val density = LocalDensity.current
    var contentWidthPx by remember { mutableStateOf(0) }
    val collapsedWidthPx = with(density) { 46.dp.toPx() } // 22dp 图标 + 左右各 12dp
    val widthAnim = remember { Animatable(0f) }
    var firstMeasure by remember { mutableStateOf(true) }
    val targetWidthPx = if (collapsedToIcon) collapsedWidthPx else contentWidthPx.toFloat()
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
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 7.dp),
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
            if (!allDone) {
                Box(
                    modifier = Modifier
                        .matchParentSize()
                        .drawBehind {
                            drawRect(
                                color = colors.accentBlue.copy(alpha = 0.35f),
                                size = Size(size.width * animatedBar.value, size.height)
                            )
                        }
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
                Box(modifier = Modifier.onGloballyPositioned { contentWidthPx = it.size.width }) {
                    // 胶囊内部的 Done / 计数切换用交叉淡化 + 轻微缩放过渡，不硬切。
                    // 尺寸动画交给外层的弹性宽度弹簧（snap 禁用 AnimatedContent 自带的尺寸
                    // 动画，避免两套叠加）；计数态内部的数字/速度更新不触发转场，原地刷新。
                    val mode = if (allDone) PillMode.DONE else PillMode.COUNTING
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
                                    modifier = Modifier.padding(horizontal = 18.dp)
                                )
                            PillMode.COUNTING ->
                                Row(
                                    modifier = Modifier.padding(horizontal = 18.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    // 速度在前（仅传输且有速度时显示）。tnum：等宽数字，位数相同则宽度恒定。
                                    if (transferring && transferState.currentSpeed > 0) {
                                        Text(
                                            text = formatSpeed(transferState.currentSpeed),
                                            style = MaterialTheme.typography.labelMedium.copy(fontFeatureSettings = "tnum"),
                                            color = colors.accentBlue,
                                            fontWeight = FontWeight.Bold
                                        )
                                    }
                                    // 数字滚动：减少（传输推进）时旧数上滑、新数自下滑入；增加（新入队）反向。
                                    // 尺寸仍 snap 交给外层宽度弹簧；clip 让滑动的数字在行内裁切，像里程表。
                                    AnimatedContent(
                                        targetState = remaining,
                                        transitionSpec = {
                                            val dir = if (targetState < initialState) 1 else -1
                                            (slideInVertically { it / 2 * dir } + fadeIn(tween(160)))
                                                .togetherWith(slideOutVertically { -it / 2 * dir } + fadeOut(tween(120)))
                                                .using(SizeTransform(clip = true, sizeAnimationSpec = { _, _ -> snap() }))
                                        },
                                        label = "count"
                                    ) { n ->
                                        Text(
                                            text = "$n",
                                            style = MaterialTheme.typography.labelLarge.copy(fontFeatureSettings = "tnum"),
                                            color = colors.onBackground,
                                            fontWeight = FontWeight.Bold
                                        )
                                    }
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

/**
 * 连接状态毛玻璃按钮：Wi-Fi 显示信号格与 dBm，USB 显示经典三叉标；
 * Wi-Fi 断开时点击进入系统设置，USB 断开则等待重新插线。
 * [pulseTrigger] 递增时按钮轻微放大再弹性缩回（断开时点缩略图的"病因指向"反馈）。
 * "Z传"页与队列页顶栏共用。
 */
@Composable
fun SignalPill(
    rssi: Int?,
    connected: Boolean,
    pulseTrigger: Int = 0,
    connectionType: CameraConnectionType? = null
) {
    val colors = AppTheme.colors
    var expanded by remember { mutableStateOf(false) }
    val usbMode = connectionType == CameraConnectionType.USB
    val online = connected && (usbMode || rssi != null)
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
        level == 4 -> colors.statusConnected
        level >= 2 -> colors.accentOrange
        else -> colors.statusError
    }

    // 强调动画：trigger 递增时轻微放大、再弹性缩回（比左右抖动柔和）。
    val pulse = remember { Animatable(1f) }
    LaunchedEffect(pulseTrigger) {
        if (pulseTrigger > 0) {
            pulse.animateTo(1.15f, tween(120, easing = FastOutSlowInEasing))
            pulse.animateTo(1f, Motion.bouncy())
        }
    }
    // 断开呼吸：整个按钮持续轻微放大缩小，把"该重连相机了"顶到眼前（点击即跳
    // Wi-Fi 设置）。仅断开时组合 infinite transition，在线零开销；值在 graphicsLayer
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
            if (online) expanded = !expanded
            // 断开态：断连图标即"去连 Wi-Fi"的入口，跳系统 Wi-Fi 设置（与连接页
            // 的 Wi-Fi 按钮同款行为）；离线时展开 dBm 本来就无意义。
            else if (!usbMode) try {
                context.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
            } catch (_: Exception) {}
        },
        shape = RoundedCornerShape(22.dp),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 9.dp),
        // 顶栏按钮统一 36dp 高；信号条内容 15dp，在按钮内垂直居中。
        modifier = Modifier
            .height(36.dp)
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
            // 在线：4 格信号条；断开：红色断连图标。两态交叉淡化切换。
            Crossfade(
                targetState = when {
                    usbMode -> 2
                    online -> 1
                    else -> 0
                },
                animationSpec = tween(220),
                label = "signalMode"
            ) { mode ->
                if (mode == 2) {
                    ClassicUsbIcon(
                        tint = color,
                        modifier = Modifier
                            .wrapContentHeight(unbounded = true)
                            .size(18.dp)
                    )
                } else if (mode == 1) {
                    Row(
                        modifier = Modifier.fillMaxHeight(),
                        verticalAlignment = Alignment.Bottom,
                        horizontalArrangement = Arrangement.spacedBy(2.5.dp)
                    ) {
                        repeat(4) { i ->
                            val lit = i < level.coerceAtLeast(1)   // 至少亮一格，表示"在连接中"
                            Box(
                                modifier = Modifier
                                    .width(4.dp)
                                    .height((6 + i * 3).dp)
                                    .clip(RoundedCornerShape(1.5.dp))
                                    .background(if (lit) color else colors.onSurfaceVariant.copy(alpha = 0.28f))
                            )
                        }
                    }
                } else {
                    Icon(
                        Icons.Default.WifiOff,
                        contentDescription = stringResource(R.string.camera_not_connected),
                        tint = colors.statusError,
                        // 图标比 15dp 内容行略大，溢出居中进 padding（与 dBm 文本同法）。
                        modifier = Modifier
                            .wrapContentHeight(unbounded = true)
                            .size(18.dp)
                    )
                }
            }
            AnimatedVisibility(
                visible = expanded && online,
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
                    color = color,
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
            Text(
                text = "${group.files.size}",
                style = MaterialTheme.typography.bodySmall.copy(fontFeatureSettings = "tnum"),
                color = colors.onSurfaceVariant
            )
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
                .height(28.dp)
                .onGloballyPositioned {
                    // 只收有效样本(零矩形防护,见 queueArea 处)。
                    if (it.isAttached) {
                        val b = it.boundsInRoot()
                        if (b.width > 0f && b.height > 0f) plusBounds = b
                    }
                },
            contentPadding = PaddingValues(horizontal = 12.dp)
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

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ThumbnailGrid(
    groups: List<FileGroup>,
    queuedByHandle: Map<Int, TransferTask>,
    exportedHandles: Set<Int>,
    columns: Int,
    isLoading: Boolean,
    transfersBusy: Boolean,
    collapsedDates: MutableMap<String, Boolean>,
    cameraViewModel: CameraViewModel,
    onTransferGroup: (List<NikonCamera.FileInfo>, Rect?) -> Unit,
    onTapFile: (NikonCamera.FileInfo) -> Unit,
    onPreview: (NikonCamera.FileInfo, Rect) -> Unit,
    onPreviewBurst: (String, List<NikonCamera.FileInfo>, Rect) -> Unit,
    tapToPreview: Boolean,
    cellBoundsRegistry: MutableMap<Int, Rect>,
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
    onExportExitFinished: (Int) -> Unit = {}
) {

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
        if (!burstAnimationBusy && collapsing == null) {
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
            // 所有既有格位——照片、合集、日期标题——严格共享同一个 placementSpec。
            // 空闲时传 null，但 animateItem 节点始终存在，不会因临时挂载 modifier 错帧。
            val placementSpec = when {
                collapsingThis -> null
                burstReflowActive -> tween<IntOffset>(
                    durationMillis = BURST_REFLOW_DURATION_MS,
                    easing = FastOutSlowInEasing
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
                        fadeInSpec = null,
                        placementSpec = placementSpec,
                        fadeOutSpec = null
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
                            if (collapsing == null && !burstAnimationBusy) {
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
                    contentType = { _, _ -> "thumbnail_grid_cell" }
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
                                } else {
                                    null
                                },
                                placementSpec = placementSpec,
                                fadeOutSpec = if (animateBurstMemberAppearance) {
                                    tween(
                                        BURST_MEMBER_EXIT_DURATION_MS,
                                        easing = FastOutSlowInEasing
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
                                    files = item.files,
                                    expanded = expanded,
                                    transfersBusy = transfersBusy,
                                    cameraViewModel = cameraViewModel,
                                    onTransferGroup = onTransferGroup,
                                    onToggle = { toggleBurstCollection(item.id) },
                                    onPreviewFirst = { rect ->
                                        onPreviewBurst(item.id, item.files, rect)
                                    },
                                    modifier = Modifier.fillMaxSize()
                                )
                            }
                            is ThumbnailGridItem.Photo -> {
                                val file = item.file
                                ThumbnailCell(
                                    file = file,
                                    task = queuedByHandle[file.handle],
                                    alreadyExported = file.handle in exportedHandles,
                                    transfersBusy = transfersBusy,
                                    cameraViewModel = cameraViewModel,
                                    onTapFile = onTapFile,
                                    onPreview = onPreview,
                                    tapToPreview = tapToPreview,
                                    cellBoundsRegistry = cellBoundsRegistry,
                                    inBurst = file.handle in burstHandles,
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
    files: List<NikonCamera.FileInfo>,
    expanded: Boolean,
    transfersBusy: Boolean,
    cameraViewModel: CameraViewModel,
    onTransferGroup: (List<NikonCamera.FileInfo>, Rect?) -> Unit,
    onToggle: () -> Unit,
    onPreviewFirst: (Rect) -> Unit,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    val a11y = stringResource(R.string.burst_collection_a11y, files.size)
    var plusBounds by remember { mutableStateOf<Rect?>(null) }
    var collectionBounds by remember { mutableStateOf<Rect?>(null) }
    val latestExpanded by rememberUpdatedState(expanded)
    val latestOnToggle by rememberUpdatedState(onToggle)
    val latestOnPreviewFirst by rememberUpdatedState(onPreviewFirst)
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
                    if (bounds.width > 0f && bounds.height > 0f) collectionBounds = bounds
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
        val stackFiles = files.take(3).reversed()

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
                showPlaceholderIcon = index == last,
                modifier = Modifier
                    .fillMaxSize(0.86f)
                    .align(Alignment.Center)
                    .offset(x = x, y = y)
                    .graphicsLayer { rotationZ = rotation }
            )
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
                            // 与右下按钮走同一展开状态机：折叠时先展开，已展开则不重复切换。
                            if (!latestExpanded) latestOnToggle()
                            collectionBounds?.let(latestOnPreviewFirst)
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
            onClick = { onTransferGroup(files, plusBounds) },
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
                        if (bounds.width > 0f && bounds.height > 0f) plusBounds = bounds
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
    showPlaceholderIcon: Boolean,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    var thumbnail by remember(file.handle) {
        mutableStateOf(cameraViewModel.cachedThumbnail(file.handle))
    }
    LaunchedEffect(file.handle, transfersBusy, loadEnabled) {
        if (loadEnabled && thumbnail == null) thumbnail = cameraViewModel.loadThumbnail(file)
    }
    val shape = RoundedCornerShape(10.dp)

    Box(
        modifier = modifier
            .clip(shape)
            .background(colors.thumbPlaceholder)
            .border(1.dp, Color.White.copy(alpha = 0.62f), shape)
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
    alreadyExported: Boolean,
    transfersBusy: Boolean,
    cameraViewModel: CameraViewModel,
    onTapFile: (NikonCamera.FileInfo) -> Unit,
    onPreview: (NikonCamera.FileInfo, Rect) -> Unit,
    tapToPreview: Boolean,
    cellBoundsRegistry: MutableMap<Int, Rect>,
    modifier: Modifier = Modifier,
    inBurst: Boolean = false,
    inExpandedBurstCollection: Boolean = false,
    reveal: Boolean = false,
    revealDelayMs: Long = 0L,
    // 变化即重播入场动画（筛选确定时存量格子也要重播）；平时保持不变。
    revealKey: Any? = null,
    exiting: Boolean = false,
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
    // 可见格子始终允许取图（传输中请求排到文件间隙执行，见 loadThumbnail 注释）。
    // transfersBusy 仅作为重试键：传输结束时对瞬时失败（如短暂掉线）的格子再补一次。
    LaunchedEffect(file.handle, transfersBusy) {
        if (thumbnail == null) {
            thumbnail = cameraViewModel.loadThumbnail(file)
        }
    }
    // 记录本格子在根坐标系中的位置，供长按预览"从格子位置放大"用。
    var cellBounds by remember { mutableStateOf<Rect?>(null) }

    val thumbnailShape = RoundedCornerShape(8.dp)
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
                scaleX = s
                scaleY = s
            }
            .clip(thumbnailShape)
            .background(colors.thumbPlaceholder)
            .then(
                if (inExpandedBurstCollection) {
                    Modifier.border(
                        width = 1.dp,
                        color = colors.accentOrange.copy(alpha = 0.92f),
                        shape = thumbnailShape
                    )
                } else {
                    Modifier
                }
            )
            .onGloballyPositioned {
                // 同一份 bounds 双用:长按预览的放大起点 + 打包动画的灵魂起点。
                // 只收有效样本:分离/复用瞬间的零矩形会让动画从屏幕外冒出(见 queueArea 处)。
                if (it.isAttached) {
                    val b = it.boundsInRoot()
                    if (b.width > 0f && b.height > 0f) {
                        cellBounds = b
                        cellBoundsRegistry[file.handle] = b
                    }
                }
            }
            // 只在这里交换两个既有动作的手势入口；传输校验、入队和预览逻辑保持单一来源。
            .combinedClickable(
                enabled = !exiting,
                onClick = {
                    if (tapToPreview) cellBounds?.let { onPreview(file, it) }
                    else onTapFile(file)
                },
                onLongClick = {
                    if (tapToPreview) onTapFile(file)
                    else cellBounds?.let { onPreview(file, it) }
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
        if (inBurst) {
            Surface(
                shape = RoundedCornerShape(bottomStart = 6.dp),
                color = BurstBadgeColor.copy(alpha = 0.85f),
                modifier = Modifier.align(Alignment.TopEnd)
            ) {
                // 叠帧图标 + 三条渐短速度线；与筛选面板的连拍胶囊共用 BurstGlyph，保证一致。
                BurstGlyph(
                    tint = colors.onAccent,
                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp)
                )
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

        // 已入队：遮罩 + 状态角标。入队/移出时淡入淡出（网格上唯一的硬切，抹掉它）；
        // lastTask 保留最后一次的任务，退场动画期间角标仍有内容可渲染。
        var lastTask by remember(file.handle) { mutableStateOf(task) }
        LaunchedEffect(task) { if (task != null) lastTask = task }
        AnimatedVisibility(
            visible = task != null,
            enter = fadeIn(tween(150)),
            exit = fadeOut(tween(150)),
            modifier = Modifier.matchParentSize()
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(colors.background.copy(alpha = 0.35f))
            ) {
                (task ?: lastTask)?.let { t ->
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .padding(4.dp)
                    ) {
                        TransferStatusIndicator(task = t)
                    }
                }
            }
        }
        if (alreadyExported && task == null) {
            Box(modifier = Modifier.align(Alignment.BottomEnd).padding(4.dp)) {
                AlreadyExportedIndicator()
            }
        }
    }
}

@Composable
private fun AlreadyExportedIndicator() {
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

/**
 * 类型/标记/日期筛选浮层。主面板保持紧凑；日期页上下同时展示开始、结束两组三波轮，
 * 编辑期间只改草稿，完成时才一次提交，避免滚动波轮时反复重排列表与后台请求。
 * 类型语义：勾"全部"= 不过滤（未来出现的新类型也放行）；点具体类型自动脱离"全部"；
 * 全不选或凑齐全部现有类型时自动归位"全部"（不允许空集）。
 * 面板随开合重建，每次打开都从当前设置初始化。
 */
@Composable
private fun FilterOverlay(
    anchorBounds: Rect?,
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
    val panelWidth = minOf(FILTER_PANEL_WIDTH, screenWidth - 24.dp)
    // 顶边贴按钮下缘 + 8dp；左缘对齐按钮，但不许超出屏幕右缘（信号条展开把按钮推得很靠右/
    // 窄屏时，面板整体向左钳制到贴边 12dp）。
    val panelTop = anchorBounds?.let { with(density) { it.bottom.toDp() } + 8.dp } ?: 76.dp
    val panelStart = (anchorBounds?.let { with(density) { it.left.toDp() } } ?: 12.dp)
        .coerceAtMost(screenWidth - panelWidth - 12.dp)
        .coerceAtLeast(12.dp)

    var working by remember { mutableStateOf(current) }

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
                                    selected = working.storageSlot == slot,
                                    onClick = {
                                        commit(
                                            working.copy(
                                                storageSlot = if (working.storageSlot == slot) null else slot
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
private fun FilterChip(
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
            Text(
                text = stringResource(R.string.burst_collection_count, count),
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

/**
 * 缩略图右下角传输状态角标:统一的暗色圆片承载各状态图形——圆片给图形提供
 * 恒定的对比度,不再让裸图标的可读性赌照片内容的深浅(旧版即是如此,观感过时)。
 * 等待=时钟、传输中=【确定型】进度环(与队列卡片同一进度语义,不再放空转圈)、
 * 完成=绿钩、失败=红色感叹、取消=灰叉;状态切换交叉淡化不硬切。
 * 与左下保护角标同底色,四角的"状态类"标识(左下/右下)共享一种安静的暗片语言,
 * 与"分类类"的彩色角贴(左上类型/右上连拍)分层。
 */
@Composable
private fun TransferStatusIndicator(task: TransferTask) {
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
                    // 传输中在列表用确定型进度环（卡片那侧改用下载字形，见 statusGlyph 说明）。
                    // 平滑追值：进度环随进度缓缓扫过，而非一段段硬跳。
                    val animatedProgress by animateFloatAsState(
                        targetValue = task.progress,
                        animationSpec = Motion.progress,
                        label = "cellProgress"
                    )
                    CircularProgressIndicator(
                        progress = animatedProgress,
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
    val topThumb: ImageBitmap?
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
private val FlightEasing = CubicBezierEasing(0.5f, 0f, 0.8f, 0.35f)

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
        progress.animateTo(1f, tween(560, easing = FlightEasing))
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
                val dx = abs(ex - sx)
                // 弧高随行程自适应(短程小弧、长程大弧,上限 90dp);
                // 控制点下界钳制峰值 y ≥ 12dp:峰值 = (sy + 2·cy + ey)/4,不飞出屏幕顶。
                val lift = (0.35f * dx + 36.dp.toPx()).coerceAtMost(90.dp.toPx())
                val cy = maxOf(minOf(sy, ey) - lift, (4f * 12.dp.toPx() - sy - ey) / 2f)
                // 水平行程 < 160dp 时控制点向左偏(行程越小偏得越多,至多 52dp)。
                val bow = 52.dp.toPx() * (1f - (dx / 160.dp.toPx()).coerceAtMost(1f))
                val cx = (sx + ex) / 2f - bow
                val mt = 1f - t
                translationX = mt * mt * sx + 2f * mt * t * cx + t * t * ex - size.width / 2f
                translationY = mt * mt * sy + 2f * mt * t * cy + t * t * ey - size.height / 2f
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
    if (files.size < 3) return emptyList()

    class Shot(
        val file: NikonCamera.FileInfo,
        val num: Int,
        val daySec: Int,
        val date: String
    )

    val result = ArrayList<BurstPhotoGroup>()
    files.groupBy { it.extension }.forEach { (extension, group) ->
        val shots = group.mapNotNull { f ->
            // 时间：PTP DateTime "YYYYMMDDThhmmss…"，取日期串 + 当日秒数。
            val d = f.captureDate ?: return@mapNotNull null
            if (d.length < 15 || !d.substring(9, 15).all { it.isDigit() }) return@mapNotNull null
            val daySec = d.substring(9, 11).toInt() * 3600 +
                    d.substring(11, 13).toInt() * 60 + d.substring(13, 15).toInt()
            // 编号：文件名主干末尾的数字段（"DSC_1234" → 1234）；无编号不参与。
            val dot = f.fileName.lastIndexOf('.')
            val stem = if (dot < 0) f.fileName else f.fileName.substring(0, dot)
            val digits = stem.takeLastWhile { it.isDigit() }
            if (digits.isEmpty() || digits.length > 9) return@mapNotNull null
            Shot(f, digits.toInt(), daySec, d.substring(0, 8))
        }.sortedWith(compareBy({ it.date }, { it.num }))

        var runStart = 0
        for (i in 1..shots.size) {
            val timeGap = if (i < shots.size) {
                shots[i].daySec - shots[i - 1].daySec
            } else {
                Int.MAX_VALUE
            }
            val broke = i == shots.size ||
                    shots[i].date != shots[i - 1].date ||
                    shots[i].num != shots[i - 1].num + 1 ||
                    timeGap !in 0..1
            if (broke) {
                if (i - runStart >= 3) {
                    val first = shots[runStart]
                    result += BurstPhotoGroup(
                        // handle 保证双卡/同名序列也不会撞 key；最早帧不变时，末尾续拍仍稳定。
                        id = "${extension}_${first.date}_${first.num}_${first.file.handle}",
                        files = shots.subList(runStart, i).map { it.file }
                    )
                }
                runStart = i
            }
        }
    }
    return result
}
