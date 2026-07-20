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
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.ui.theme.*
import com.ztransfer.ui.util.Haptics
import com.ztransfer.ui.util.formatSpeed
import com.ztransfer.ui.util.rememberHaptics
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.ConnectionMode
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import com.ztransfer.viewmodel.TransferViewModel
import com.ztransfer.viewmodel.currentFileProgress
import com.ztransfer.viewmodel.remainingCount
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch

data class FileGroup(
    val date: String,
    val files: List<NikonCamera.FileInfo>
)

/** 队列胶囊的三种内容形态：入口图标 / 完成短标 / 计数（速度+剩余数）。 */
private enum class PillMode { ICON, DONE, COUNTING }

// 缩略图后台填充没有任何窗口/视口参数：未传输=从新到旧全量填充；传输中=完全停止。
// 填充逻辑住在 CameraViewModel.startThumbnailFill（与页面无关）。

// 类型筛选下拉面板宽度（位置钳制计算需要显式宽度）。
private val FILTER_PANEL_WIDTH = 180.dp

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

    // 筛选（类型/保护标记）：纯前端过滤——原始 state.files 不动、不触发任何重新读取；
    // 预览翻页/分组/网格全部基于过滤后的数据，自然一致。
    //（曾有"横竖构图"筛选,已摘除:ObjectInfo 的宽高是传感器原生方向,竖拍的方向
    // 只在 EXIF Orientation 里且依赖机内"自动旋转图像"设置——ObjectInfo 这条路
    // 判不出构图。将来若做,走 EXIF 头懒采集 + 磁盘缓存,可顺带修显示旋转。）
    val filterExts = transferState.filterExtensions
    val filterProtected = transferState.filterProtectedOnly
    val filterBurst = transferState.filterBurstOnly
    val filterActive = filterExts != null || filterProtected || filterBurst
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
    // 连拍检测:基于原始列表计算,只在文件列表变化时重算。
    // 驱动缩略图右上角的连拍角标 + "连拍"筛选(同一数据源,标记与筛选天然一致)。
    val burstHandles = remember(state.files) { computeBurstHandles(state.files) }
    // 分组 / 扁平列表（供长按预览翻页）/ 传输忙碌（缩略图让路）——提到顶层，供内容区与预览层共用。
    val groups = remember(state.files, filterExts, filterProtected, filterBurst) {
        val files = state.files.asSequence()
            .filter { filterExts == null || it.extension in filterExts }
            .filter { !filterProtected || it.isProtected }
            .filter { !filterBurst || it.handle in burstHandles }
            .toList()
        groupFilesByDate(files)
    }
    val flatFiles = remember(groups) { groups.flatMap { it.files } }
    val transfersBusy = transferState.tasks.any {
        it.status == TransferStatus.WAITING || it.status == TransferStatus.TRANSFERING
    }
    // 触感反馈（开关在设置里，默认开）。
    val haptics = rememberHaptics(transferState.hapticsEnabled)

    // 长按预览：全屏翻页 + 从被长按格子的位置放大展开。
    var previewIndex by remember { mutableStateOf<Int?>(null) }
    var previewAnchor by remember { mutableStateOf<Rect?>(null) }
    val onPreview: (NikonCamera.FileInfo, Rect) -> Unit = { file, rect ->
        val idx = flatFiles.indexOfFirst { it.handle == file.handle }
        if (idx >= 0) {
            haptics.longPress()
            previewIndex = idx
            previewAnchor = rect
        }
    }

    // 队列 handle → 任务：列表角标与预览页"已入队"态共用。
    val queuedByHandle = remember(transferState.tasks) {
        transferState.tasks.associateBy { it.file.handle }
    }
    // 单文件入队：列表轻触 + 预览页传输按钮共用。gating 与整组传输一致。
    val onTapFile: (NikonCamera.FileInfo) -> Unit = onTapFile@{ file ->
        if (transferState.transferDirUri == null) {
            // 预览层盖在设置面板之上，先关掉预览再弹设置，否则用户看不见。
            previewIndex = null
            showSettings = true; return@onTapFile
        }
        if (!state.isConnectedToCamera) {
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

        if (!state.isLoadingFiles && state.files.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.padding(horizontal = 32.dp)
                ) {
                    if (!state.isConnectedToCamera) {
                        // 兜底：断开且列表从未加载成功（掉线不再清列表，正常断开时网格保留、
                        // 由顶栏信号按钮指示状态，不会走到这里）。
                        Icon(Icons.Default.WifiOff, contentDescription = null, modifier = Modifier.size(64.dp), tint = colors.accentOrange)
                        Spacer(modifier = Modifier.height(16.dp))
                        Text(stringResource(R.string.connection_lost), color = colors.onBackground, style = MaterialTheme.typography.titleMedium)
                        Spacer(modifier = Modifier.height(6.dp))
                        Text(
                            stringResource(R.string.connect_camera_wifi),
                            color = colors.onSurfaceVariant,
                            style = MaterialTheme.typography.bodySmall,
                            textAlign = TextAlign.Center
                        )
                        // 一键直达系统 Wi-Fi 设置（与连接页同款按钮），不必退回连接页。
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
                if (!state.isConnectedToCamera) {
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
            if (groups.isEmpty()) {
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
                columns = transferState.thumbnailColumns,
                isLoading = state.isLoadingFiles,
                transfersBusy = transfersBusy,
                collapsedDates = collapsedDates,
                cameraViewModel = cameraViewModel,
                onTransferGroup = onTransferGroup,
                onTapFile = onTapFile,
                onPreview = onPreview,
                cellBoundsRegistry = cellBoundsRegistry,
                burstHandles = burstHandles,
                contentPadding = listPadding,
                gridState = gridState,
                filterRevealTick = filterRevealTick,
                filterRevealWindow = filterRevealWindow,
                modifier = Modifier.fillMaxSize()
            )
        }

        // ---------- 遥控入口（左下角毛玻璃圆钮）：仅当列表停在最顶部时出现——
        // 用户翻到深处时不显示，杜绝翻页误触；点击播放与横滑相同的左侧滑入转场 ----------
        val atTop by remember {
            derivedStateOf {
                gridState.firstVisibleItemIndex == 0 && gridState.firstVisibleItemScrollOffset < 8
            }
        }
        // 传输进行中禁止进入监看：监看要独占相机通道（LV 取帧连续占锁），与下载抢锁会两败俱伤。
        // 图标压暗示意不可用，点击给出提示而非静默无响应。
        val remoteBlockedHint = stringResource(R.string.remote_blocked_transfer)
        AnimatedVisibility(
            visible = atTop,
            enter = fadeIn() + scaleIn(initialScale = 0.6f),
            exit = fadeOut() + scaleOut(targetScale = 0.6f),
            modifier = Modifier
                .align(Alignment.BottomStart)
                .navigationBarsPadding()
                .padding(start = 20.dp, bottom = 24.dp)
        ) {
            GlassButton(
                onClick = {
                    if (transfersBusy) showHint(remoteBlockedHint)
                    // 免费版当日监看时长已用完:入口处直接提示,不进页再弹回。
                    else if (LicenseManager.remoteTimeLeftMs() <= 0L) showHint(remoteEndedHint)
                    else onNavigateToRemote()
                },
                shape = CircleShape,
                contentPadding = PaddingValues(14.dp)
            ) {
                RemoteMark(
                    modifier = Modifier.size(24.dp),
                    color = if (transfersBusy) colors.onSurfaceVariant.copy(alpha = 0.5f) else colors.accentBlue,
                    contentDescription = stringResource(R.string.cd_remote_entry)
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
                forceFullSignal = state.connectionMode == ConnectionMode.PHONE_HOTSPOT,
                pulseTrigger = signalPulse
            )

            // 信号按钮右侧：类型筛选按钮。信号条展开/收起的宽度动画是逐帧真实布局，
            // 本按钮随 Row 重排平滑让位，位置天然跟随动画。已设筛选时图标高亮。
            Spacer(modifier = Modifier.width(8.dp))
            GlassButton(
                onClick = { showFilter = !showFilter },
                shape = RoundedCornerShape(22.dp),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
                modifier = Modifier
                    .height(36.dp)
                    .onGloballyPositioned { filterAnchor = it.boundsInRoot() }
            ) {
                // 自绘筛选标志（与信号条同族的圆头杆件语言）；已设筛选时高亮。
                FilterMark(
                    modifier = Modifier.size(19.dp),
                    color = if (filterActive) colors.accentBlue else colors.onBackground,
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
                current = filterExts,
                currentProtected = filterProtected,
                currentBurst = filterBurst,
                onConfirm = { sel, prot, burst ->
                    // 筛选真的变了才开入场窗口：在事件回调里【同步】置起（与分组展开在
                    // onClick 里设 recentlyExpanded 同理），下一帧组成的新列表才带动画;
                    // 原样确定不重播,免得无变化也整屏闪一遍。
                    if (sel != filterExts || prot != filterProtected || burst != filterBurst) {
                        filterRevealTick++
                        filterRevealWindow = true
                    }
                    transferViewModel.setFilters(sel, prot, burst)
                    showFilter = false
                },
                onDismiss = { showFilter = false }
            )
        }

        // 设置面板（点击 "Z传" 或未设目录时弹出），从 "Z传" 按钮位置变形展开。
        if (showSettings) {
            SettingsOverlay(
                viewModel = transferViewModel,
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
            if (idx in flatFiles.indices) {
                PhotoPreviewOverlay(
                    files = flatFiles,
                    initialIndex = idx,
                    anchorRect = previewAnchor,
                    cameraViewModel = cameraViewModel,
                    hapticsEnabled = transferState.hapticsEnabled,
                    burstHandles = burstHandles,
                    queuedHandles = queuedByHandle.keys,
                    onTransfer = onTapFile,
                    onDismiss = { previewIndex = null }
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
        FireworksOverlay(fireworks)
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
    val hasActive = transferState.tasks.any { it.status == TransferStatus.TRANSFERING }
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

    // 弹性宽度动画：测量内容的自然宽度，用 spring 驱动一个显式宽度；内容靠右对齐、左侧溢出被圆角裁掉。
    // 于是任何内容变化（图标/done/数量/速度）都平滑有弹性，而右边缘由外层 Box(CenterEnd) 钉死不动。
    val density = LocalDensity.current
    var contentWidthPx by remember { mutableStateOf(0) }
    val widthAnim = remember { Animatable(0f) }
    var firstMeasure by remember { mutableStateOf(true) }
    LaunchedEffect(contentWidthPx) {
        if (contentWidthPx > 0) {
            if (firstMeasure) {
                widthAnim.snapTo(contentWidthPx.toFloat())   // 首次出现直接就位，不从 0 弹出
                firstMeasure = false
            } else {
                widthAnim.animateTo(contentWidthPx.toFloat(), Motion.bouncy())
            }
        }
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
                    // 三态内容（图标 / done / 计数）切换用交叉淡化 + 轻微缩放过渡，不硬切。
                    // 尺寸动画交给外层的弹性宽度弹簧（snap 禁用 AnimatedContent 自带的尺寸
                    // 动画，避免两套叠加）；计数态内部的数字/速度更新不触发转场，原地刷新。
                    val mode = when {
                        collapsedToIcon -> PillMode.ICON
                        allDone -> PillMode.DONE
                        else -> PillMode.COUNTING
                    }
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
                            PillMode.ICON ->
                                // 传输入口图标：清单勾选，直观表示"传输"。
                                Icon(
                                    imageVector = Icons.Default.Checklist,
                                    contentDescription = stringResource(R.string.cd_transfer),
                                    tint = colors.statusConnected,
                                    modifier = Modifier
                                        .padding(horizontal = 12.dp)
                                        .size(22.dp)
                                )
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
 * Wi-Fi 信号毛玻璃按钮：相机已连接时显示 4 格信号条（点击展开具体 dBm）；
 * 连接断开（含不在相机 Wi-Fi）时显示红色断连图标——断开状态一眼可见，
 * 此时点击直接跳系统 Wi-Fi 设置（与连接页的 Wi-Fi 按钮同款行为）。
 * [pulseTrigger] 递增时按钮轻微放大再弹性缩回（断开时点缩略图的"病因指向"反馈）。
 * "Z传"页与队列页顶栏共用。
 */
@Composable
fun SignalPill(rssi: Int?, connected: Boolean, forceFullSignal: Boolean = false, pulseTrigger: Int = 0) {
    val colors = AppTheme.colors
    var expanded by remember { mutableStateOf(false) }
    // 手机作为热点 AP 时，Android 公共 API 不提供单个热点客户端的 RSSI；PTP 会话
    // 已连接但 rssi=null 仍然是在线，不能误画成红色断网。只有 STA（原相机热点）
    // 能取得真实 dBm 时才按强弱着色。
    val online = connected
    val hasSignalReading = rssi != null
    val r = rssi ?: -999
    // dBm 越接近 0 越强。判定从严：满格只给极好信号，稍差立刻掉格。
    //  -30↑ 满格 / -45↑ 三格 / -55↑ 两格 / -65↑ 一格 / 更弱 0 格。
    val level = when {
        forceFullSignal && online -> 4 // 仅手机热点 AP 模式按产品约定固定满格。
        r >= -30 -> 4
        r >= -45 -> 3
        r >= -55 -> 2
        r >= -65 -> 1
        else -> 0
    }
    val color = when {
        forceFullSignal && online -> colors.statusConnected
        !hasSignalReading -> colors.accentBlue
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
            else try {
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
            Crossfade(targetState = online, animationSpec = tween(220), label = "signalMode") { on ->
                if (on) {
                    Row(
                        modifier = Modifier.fillMaxHeight(),
                        verticalAlignment = Alignment.Bottom,
                        horizontalArrangement = Arrangement.spacedBy(2.5.dp)
                    ) {
                        repeat(4) { i ->
                            val lit = if (forceFullSignal) true else if (hasSignalReading) i < level.coerceAtLeast(1) else i == 0
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
                    text = if (hasSignalReading) "$r dBm" else stringResource(R.string.camera_link_connected),
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
    queuedByHandle: Map<Int, TransferTask>,
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
        val remainingGroupFiles = group.files.filter { it.handle !in queuedByHandle }
        // 整组传输：图标化（+ 加入队列 / ✓ 已全部加入），无文字更简约；与日期胶囊同规格。
        // 按钮在根坐标系的 bounds 供"整组吸入"动画定位起飞点。
        var plusBounds by remember { mutableStateOf<Rect?>(null) }
        GlassButton(
            onClick = { onTransferGroup(remainingGroupFiles, plusBounds) },
            enabled = remainingGroupFiles.isNotEmpty(),
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
            val allQueued = remainingGroupFiles.isEmpty()
            Icon(
                if (allQueued) Icons.Default.Check else Icons.Default.Add,
                contentDescription = stringResource(if (allQueued) R.string.cd_all_queued else R.string.cd_transfer_group),
                tint = if (allQueued) colors.statusConnected else colors.accentBlue,
                modifier = Modifier.size(18.dp)
            )
        }
    }
}

@Composable
private fun ThumbnailGrid(
    groups: List<FileGroup>,
    queuedByHandle: Map<Int, TransferTask>,
    columns: Int,
    isLoading: Boolean,
    transfersBusy: Boolean,
    collapsedDates: MutableMap<String, Boolean>,
    cameraViewModel: CameraViewModel,
    onTransferGroup: (List<NikonCamera.FileInfo>, Rect?) -> Unit,
    onTapFile: (NikonCamera.FileInfo) -> Unit,
    onPreview: (NikonCamera.FileInfo, Rect) -> Unit,
    cellBoundsRegistry: MutableMap<Int, Rect>,
    burstHandles: Set<Int>,
    contentPadding: PaddingValues,
    gridState: LazyGridState,
    // 筛选入场：确定筛选的瞬间 tick 递增、window 开启 600ms（都在事件回调里同步置起，
    // 晚一帧格子就先以终态闪现穿帮）。窗口内组成的格子重播级联入场——复用分组展开的
    // "瞬时重排 + 级联入场"方案；条目位移动画不可用的原因见下方手风琴注释。
    filterRevealTick: Int = 0,
    filterRevealWindow: Boolean = false,
    modifier: Modifier = Modifier
) {

    // 展开/收起动画（手风琴方案；不用条目位移动画——它对"被推出屏幕的条目"有框架级
    // 边缘悬停，对"从屏外移入"的条目又根本不生效，大分组收起时什么动画都看不到）：
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
            // 分组头整行跨列，保持与列表模式一致的分组语义
            item(
                span = { GridItemSpan(maxLineSpan) },
                key = "header_${group.date}",
                contentType = "header"
            ) {
                Column {
                    Spacer(modifier = Modifier.height(4.dp))
                    GroupHeader(
                        group = group,
                        queuedByHandle = queuedByHandle,
                        // 收合动画进行中箭头即刻转向，不等动画结束。
                        collapsed = collapsed || collapsingThis,
                        onToggleCollapse = {
                            if (collapsing == null) {   // 收合动画期间忽略再次点击
                                if (collapsed) {
                                    // 展开：瞬时重排 + 该组格子级联入场。
                                    recentlyExpanded = group.date
                                    collapsedDates[group.date] = false
                                } else {
                                    recentlyExpanded = null
                                    toggleScope.launch {
                                        // 只保留当前可见的格子（+一行缓冲）参与收合动画。
                                        val visibleKeys = gridState.layoutInfo.visibleItemsInfo
                                            .mapNotNull { it.key as? Int }
                                            .toHashSet()
                                        val lastVisible = group.files.indexOfLast { it.handle in visibleKeys }
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
                val files = if (collapsingThis) {
                    group.files.take(collapsing?.keep ?: 0)
                } else group.files
                itemsIndexed(
                    files,
                    key = { _, f -> f.handle },
                    contentType = { _, _ -> "cell" }
                ) { index, file ->
                    ThumbnailCell(
                        file = file,
                        task = queuedByHandle[file.handle],
                        transfersBusy = transfersBusy,
                        cameraViewModel = cameraViewModel,
                        onTapFile = onTapFile,
                        onPreview = onPreview,
                        cellBoundsRegistry = cellBoundsRegistry,
                        inBurst = file.handle in burstHandles,
                        reveal = group.date == recentlyExpanded || filterRevealWindow,
                        // 级联错峰：组内前 18 格按 15ms 递增，其余同批（基本都在屏外）。
                        revealDelayMs = (index.coerceAtMost(18) * 15).toLong(),
                        revealKey = filterRevealTick,
                        modifier = if (collapsingThis) {
                            Modifier.collapseHeight { collapseProgress.value }
                        } else Modifier
                    )
                }
            }
        }

        if (isLoading) {
            item(span = { GridItemSpan(maxLineSpan) }) { LoadingMoreRow() }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ThumbnailCell(
    file: NikonCamera.FileInfo,
    task: TransferTask?,
    transfersBusy: Boolean,
    cameraViewModel: CameraViewModel,
    onTapFile: (NikonCamera.FileInfo) -> Unit,
    onPreview: (NikonCamera.FileInfo, Rect) -> Unit,
    cellBoundsRegistry: MutableMap<Int, Rect>,
    inBurst: Boolean = false,
    reveal: Boolean = false,
    revealDelayMs: Long = 0L,
    // 变化即重播入场动画（筛选确定时存量格子也要重播）；平时保持不变。
    revealKey: Any? = null,
    modifier: Modifier = Modifier
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
    // 已加载的缩略图按 handle 记住，transfersBusy 变化不会让它闪回占位。
    var thumbnail by remember(file.handle) { mutableStateOf<ImageBitmap?>(null) }
    // 可见格子始终允许取图（传输中请求排到文件间隙执行，见 loadThumbnail 注释）。
    // transfersBusy 仅作为重试键：传输结束时对瞬时失败（如短暂掉线）的格子再补一次。
    LaunchedEffect(file.handle, transfersBusy) {
        if (thumbnail == null) {
            thumbnail = cameraViewModel.loadThumbnail(file)
        }
    }
    // 记录本格子在根坐标系中的位置，供长按预览"从格子位置放大"用。
    var cellBounds by remember { mutableStateOf<Rect?>(null) }

    Box(
        modifier = modifier
            // 行距烘焙在格子底部：收合动画缩放整个条目（含间距），结束零跳变。
            .padding(bottom = 6.dp)
            .aspectRatio(1f)
            .graphicsLayer {
                val p = revealProgress.value
                alpha = p
                val s = 0.94f + 0.06f * p
                scaleX = s
                scaleY = s
            }
            .clip(RoundedCornerShape(8.dp))
            .background(colors.thumbPlaceholder)
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
            // 轻触加入队列（已入队则无操作），长按预览大图（任何状态都可预览）。
            .combinedClickable(
                onClick = { if (task == null) onTapFile(file) },
                onLongClick = { cellBounds?.let { onPreview(file, it) } }
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
        // "这一串是按住快门快速扫出来的"。算法见 computeBurstHandles。
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
 * 类型/标记筛选浮层：从筛选按钮变形弹出、关闭缩回按钮（复用 [AnchorPopup]，与设置面板同款观感）。
 * 类型（自动列出设备上实际存在的，多选 + "全部"）与标记（保护/连拍）分两组紧凑胶囊，
 * 细线分隔，底部玻璃"应用"按钮；点应用才一次性提交生效。
 * 类型语义：勾"全部"= 不过滤（未来出现的新类型也放行）；点具体类型自动脱离"全部"；
 * 全不选或凑齐全部现有类型时自动归位"全部"（不允许空集）。
 * 工作副本确定前不生效；面板随开合重建，每次打开都从当前设置初始化。
 */
@Composable
private fun FilterOverlay(
    anchorBounds: Rect?,
    availableExts: List<String>,
    current: Set<String>?,
    currentProtected: Boolean,
    currentBurst: Boolean,
    onConfirm: (Set<String>?, Boolean, Boolean) -> Unit,
    onDismiss: () -> Unit
) {
    val colors = AppTheme.colors
    val density = LocalDensity.current
    // 顶边贴按钮下缘 + 8dp；左缘对齐按钮，但不许超出屏幕右缘（信号条展开把按钮推得很靠右/
    // 窄屏时，面板整体向左钳制到贴边 12dp）。
    val panelTop = anchorBounds?.let { with(density) { it.bottom.toDp() } + 8.dp } ?: 76.dp
    val screenWidth = LocalConfiguration.current.screenWidthDp.dp
    val panelStart = (anchorBounds?.let { with(density) { it.left.toDp() } } ?: 12.dp)
        .coerceAtMost(screenWidth - FILTER_PANEL_WIDTH - 12.dp)
        .coerceAtLeast(12.dp)

    var working by remember { mutableStateOf(current) }
    var workingProtected by remember { mutableStateOf(currentProtected) }
    var workingBurst by remember { mutableStateOf(currentBurst) }

    val otherLabel = stringResource(R.string.filter_other)
    fun extLabel(ext: String) = ext.removePrefix(".").uppercase().ifEmpty { otherLabel }
    fun toggle(ext: String) {
        val cur = working ?: availableExts.toSet()
        val next = if (ext in cur) cur - ext else cur + ext
        working = when {
            next.isEmpty() -> null                       // 全不选无意义，归位"全部"
            next.containsAll(availableExts) -> null      // 凑齐全部现有类型 = 全部
            else -> next
        }
    }

    AnchorPopup(
        anchorBounds = anchorBounds,
        onDismiss = onDismiss,
        panelModifier = Modifier
            .padding(start = panelStart, top = panelTop)
            .width(FILTER_PANEL_WIDTH),
        shape = RoundedCornerShape(16.dp),
        dim = false   // 小下拉不压暗全屏（遮罩仍拦点击/滚动）
    ) { _ ->
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            // ---- 类型：全部 + 各扩展名，两列胶囊 ----
            val typeChips: List<Triple<String, Boolean, () -> Unit>> = buildList {
                add(Triple(stringResource(R.string.filter_all), working == null) { working = null })
                availableExts.forEach { ext ->
                    add(Triple(extLabel(ext), working?.contains(ext) ?: true) { toggle(ext) })
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                typeChips.chunked(2).forEach { rowChips ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        rowChips.forEach { (label, selected, onClick) ->
                            FilterChip(label, selected, onClick, Modifier.weight(1f))
                        }
                        // 奇数个时补一个占位，保证末行左对齐、胶囊等宽。
                        if (rowChips.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
            }

            // 分隔线
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 2.dp)
                    .height(1.dp)
                    .background(colors.glassPanelBorder)
            )

            // ---- 标记：保护 / 连拍（独立开关，与类型叠加生效）----
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(
                    label = stringResource(R.string.filter_protected),
                    selected = workingProtected,
                    onClick = { workingProtected = !workingProtected },
                    modifier = Modifier.weight(1f),
                    icon = Icons.Default.Key   // 钥匙 + "保护"
                )
                FilterChip(
                    label = stringResource(R.string.burst_label),
                    selected = workingBurst,
                    onClick = { workingBurst = !workingBurst },
                    modifier = Modifier.weight(1f),
                    // 叠帧 + 三条速度线（与缩略图角标同一 BurstGlyph）+ "连拍"
                    leading = { tint -> BurstGlyph(tint = tint) }
                )
            }

            // ---- 应用：毛玻璃对号按钮（与全局悬浮控件同语言）----
            GlassButton(
                onClick = { onConfirm(working, workingProtected, workingBurst) },
                shape = RoundedCornerShape(10.dp),
                contentPadding = PaddingValues(vertical = 8.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Spacer(modifier = Modifier.weight(1f))
                Icon(
                    Icons.Default.Check,
                    contentDescription = stringResource(R.string.cd_apply_filter),
                    tint = colors.statusConnected,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(modifier = Modifier.weight(1f))
            }
        }
    }
}

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
private fun BurstGlyph(tint: Color, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp)
    ) {
        Icon(
            Icons.Default.BurstMode,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(11.dp)
        )
        // 三条渐短的速度线（拖尾越短越靠下）：细、压低到与图标齐高。
        Column(
            verticalArrangement = Arrangement.spacedBy(1.25.dp),
            horizontalAlignment = Alignment.Start
        ) {
            listOf(7.dp, 5.dp, 3.dp).forEach { w ->
                Box(
                    modifier = Modifier
                        .width(w)
                        .height(1.dp)
                        .clip(RoundedCornerShape(0.5.dp))
                        .background(tint)
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
 * 连拍检测（试验期，当前仅驱动缩略图右上角的连拍角标）：
 * 同扩展名内按「拍摄日期 + 文件编号」排序，"编号连续 且 相邻拍摄间隔 ≤1 秒"的
 * 连续段长度 ≥3 视为一组连拍，返回全部成员 handle。
 * 不依赖 ObjectInfo.SequenceNumber（机型可能恒填 0），只用文件名编号 + 秒级时间戳,
 * 对 RAW+JPG 双格式连拍两条轨各自成组。O(n log n)，仅在文件列表变化时重算。
 * 已知边界：编号 9999 回卷、跨零点的连拍会被切成两段——都只影响标记完整性，可接受。
 */
private fun computeBurstHandles(files: List<NikonCamera.FileInfo>): Set<Int> {
    if (files.size < 3) return emptySet()

    class Shot(val handle: Int, val num: Int, val daySec: Int, val date: String)

    val result = HashSet<Int>()
    files.groupBy { it.extension }.forEach { (_, group) ->
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
            Shot(f.handle, digits.toInt(), daySec, d.substring(0, 8))
        }.sortedWith(compareBy({ it.date }, { it.num }))

        var runStart = 0
        for (i in 1..shots.size) {
            val broke = i == shots.size ||
                    shots[i].date != shots[i - 1].date ||
                    shots[i].num != shots[i - 1].num + 1 ||
                    shots[i].daySec - shots[i - 1].daySec > 1
            if (broke) {
                if (i - runStart >= 3) {
                    for (j in runStart until i) result.add(shots[j].handle)
                }
                runStart = i
            }
        }
    }
    return result
}
