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
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
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
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
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
import androidx.compose.ui.graphics.TransformOrigin
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
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.ui.theme.*
import com.ztransfer.ui.util.Haptics
import com.ztransfer.ui.util.formatSpeed
import com.ztransfer.ui.util.rememberHaptics
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import com.ztransfer.viewmodel.TransferViewModel
import com.ztransfer.viewmodel.currentFileProgress
import com.ztransfer.viewmodel.remainingCount
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
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
private val FILTER_PANEL_WIDTH = 148.dp

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

    // 文件列表是连接成功后的主页面：返回不回到连接页，而是"再按一次退出应用"。
    val context = LocalContext.current
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
    // 筛选下拉打开时，返回键先收起下拉（后注册的 BackHandler 优先于上面的退出确认）。
    BackHandler(enabled = showFilter) { showFilter = false }

    val topInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val bottomInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    // 列表内容内边距：顶部让出状态栏 + 悬浮控件高度；底部让出导航栏。内容本身 edge-to-edge。
    val listPadding = PaddingValues(
        start = 12.dp,
        end = 12.dp,
        top = topInset + 60.dp,
        bottom = bottomInset + 12.dp
    )

    // 类型筛选：纯前端过滤——原始 state.files 不动、不触发任何重新读取；
    // null = 全部。预览翻页/分组/网格全部基于过滤后的数据，自然一致。
    val filterExts = transferState.filterExtensions
    // 设备上实际存在的类型（从未过滤的原始列表提取，供下拉选项自动生成）。
    val availableExts = remember(state.files) {
        state.files.map { it.extension }.distinct().sorted()
    }
    // 分组 / 扁平列表（供长按预览翻页）/ 传输忙碌（缩略图让路）——提到顶层，供内容区与预览层共用。
    val groups = remember(state.files, filterExts) {
        val files = if (filterExts == null) state.files
        else state.files.filter { it.extension in filterExts }
        groupFilesByDate(files)
    }
    val flatFiles = remember(groups) { groups.flatMap { it.files } }
    val transfersBusy = transferState.tasks.any {
        it.status == TransferStatus.WAITING || it.status == TransferStatus.TRANSFERING
    }
    // 触感反馈（开关在设置里，默认关）。
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

    // 根需不透明底色：与队列页左右滑动转场期间两页同屏层叠，透明根会让底层页面透出。
    // 遥控页入口是左下角圆钮（曾试过横滑手势进入，误触率高已去掉）。
    Box(modifier = Modifier.fillMaxSize().background(colors.background)) {
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
                        Icon(Icons.Default.FolderOff, contentDescription = null, modifier = Modifier.size(64.dp), tint = colors.onSurfaceVariant)
                        Spacer(modifier = Modifier.height(16.dp))
                        Text(stringResource(R.string.no_photos_on_camera), color = colors.onSurfaceVariant)
                    }
                }
            }
        }

        if (state.files.isNotEmpty()) {
            val queuedByHandle = remember(transferState.tasks) {
                transferState.tasks.associateBy { it.file.handle }
            }
            // 各日期分组的收起状态（key=日期）。收起的组不渲染其条目/缩略图，
            // 因而缩略图不会加载；展开后条目重新 emit 才恢复加载。跨渐进加载持久保留。
            val collapsedDates = remember { mutableStateMapOf<String, Boolean>() }

            // 分组批量传输 / 单文件点击。gating 用响应式的 isConnectedToCamera；
            // 队列内部经 provider 现取当前相机实例，中途重连后续传任务自动用新连接。
            val onTransferGroup: (List<NikonCamera.FileInfo>) -> Unit = onTransferGroup@{ remaining ->
                if (transferState.transferDirUri == null) {
                    showSettings = true; return@onTransferGroup
                }
                if (!state.isConnectedToCamera) {
                    // 未连接：信号按钮放大强调 + 提示，而不是静默无响应。
                    signalPulse++
                    showHint(notConnectedHint)
                } else if (remaining.isNotEmpty()) {
                    haptics.tick()   // 整组入队只震一次
                    // 只加入队列、原地继续浏览，不跳转到队列页（想看进度可点右上角胶囊进入）。
                    transferViewModel.addToQueue(remaining, cameraViewModel::getCamera)
                }
            }
            val onTapFile: (NikonCamera.FileInfo) -> Unit = onTapFile@{ file ->
                if (transferState.transferDirUri == null) {
                    showSettings = true; return@onTapFile
                }
                if (!state.isConnectedToCamera) {
                    signalPulse++
                    showHint(notConnectedHint)
                } else {
                    haptics.tick()   // 只在真正入队时震（引导去设置时不震）
                    transferViewModel.addToQueue(listOf(file), cameraViewModel::getCamera)
                }
            }

            // 筛选后无匹配：给出指认原因的空态（原始列表非空，只是被筛掉了）。
            if (groups.isEmpty()) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        FilterMark(
                            modifier = Modifier.size(44.dp),
                            color = colors.onSurfaceVariant.copy(alpha = 0.6f)
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
                contentPadding = listPadding,
                gridState = gridState,
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
                onClick = onNavigateToRemote,
                shape = CircleShape,
                contentPadding = PaddingValues(14.dp)
            ) {
                RemoteMark(
                    modifier = Modifier.size(24.dp),
                    color = colors.accentBlue,
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
                    Brush.verticalGradient(
                        0f to colors.background.copy(alpha = 0.85f),
                        0.45f to colors.background.copy(alpha = 0.5f),
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
                    color = if (filterExts != null) colors.accentBlue else colors.onBackground,
                    contentDescription = stringResource(R.string.cd_filter_type)
                )
            }

            // 右：传输胶囊（悬浮）。用"占满剩余宽度 + 靠右对齐"的 Box 承载，
            // 保证胶囊宽度变化时右边缘固定、只向左伸缩，不会向右溢出屏幕。
            Box(
                modifier = Modifier.weight(1f),
                contentAlignment = Alignment.CenterEnd
            ) {
                if (transferState.tasks.isNotEmpty()) {
                    QueuePill(transferState = transferState, haptics = haptics, onClick = onNavigateToTransfer)
                }
            }
        }

        // ---------- 类型筛选下拉：贴筛选按钮下缘向下展开；点面板外任意处收起 ----------
        val filterTransition = remember { MutableTransitionState(false) }
        filterTransition.targetState = showFilter
        if (filterTransition.currentState || filterTransition.targetState) {
            // 透明捕获层：点击面板外任意处（含顶栏其它按钮区域）只收起下拉，不穿透。
            if (showFilter) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .pointerInput(Unit) { detectTapGestures { showFilter = false } }
                )
            }
            val density = LocalDensity.current
            val panelTop = filterAnchor?.let { with(density) { it.bottom.toDp() } + 8.dp } ?: 76.dp
            // 左缘对齐按钮，但不许超出屏幕右缘（信号条展开把按钮推得很靠右/窄屏时，
            // 面板整体向左钳制到贴边 12dp）。
            val screenWidth = LocalConfiguration.current.screenWidthDp.dp
            val panelStart = (filterAnchor?.let { with(density) { it.left.toDp() } } ?: 12.dp)
                .coerceAtMost(screenWidth - FILTER_PANEL_WIDTH - 12.dp)
                .coerceAtLeast(12.dp)
            Box(modifier = Modifier.padding(start = panelStart, top = panelTop)) {
                AnimatedVisibility(
                    visibleState = filterTransition,
                    enter = fadeIn(tween(180)) + expandVertically(expandFrom = Alignment.Top),
                    exit = fadeOut(tween(140)) + shrinkVertically(shrinkTowards = Alignment.Top)
                ) {
                    FilterDropdown(
                        availableExts = availableExts,
                        current = filterExts,
                        onConfirm = { sel ->
                            transferViewModel.setFilterExtensions(sel)
                            showFilter = false
                        }
                    )
                }
            }
        }

        // 底部通用玻璃提示条（退出确认 / 相机未连接等）。
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

        // 设置面板（点击 "Z传" 或未设目录时弹出），从 "Z传" 按钮位置变形展开。
        if (showSettings) {
            SettingsOverlay(
                viewModel = transferViewModel,
                anchorBounds = zAnchor,
                onDismiss = { showSettings = false }
            )
        }

        // 长按预览层（最上层）：全屏翻页，从被长按格子的位置放大展开/收回。
        previewIndex?.let { idx ->
            if (idx in flatFiles.indices) {
                PhotoPreviewOverlay(
                    files = flatFiles,
                    initialIndex = idx,
                    anchorRect = previewAnchor,
                    cameraViewModel = cameraViewModel,
                    onDismiss = { previewIndex = null }
                )
            }
        }
    }
}

@Composable
fun QueuePill(
    transferState: com.ztransfer.viewmodel.TransferState,
    haptics: Haptics,
    onClick: () -> Unit
) {
    val colors = AppTheme.colors
    val remaining = transferState.remainingCount
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

    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(22.dp),
        color = colors.glassSurface,   // 毛玻璃半透明底（与 "Z传" 一致）
        shadowElevation = 4.dp,
        modifier = Modifier
            .height(36.dp)
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
                                size = Size(size.width * barFraction, size.height)
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
                                    text = "done",
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
 * 连接断开（含不在相机 Wi-Fi）时显示红色断连图标——断开状态一眼可见。
 * [pulseTrigger] 递增时按钮轻微放大再弹性缩回（断开时点缩略图的"病因指向"反馈）。
 * "Z传"页与队列页顶栏共用。
 */
@Composable
fun SignalPill(rssi: Int?, connected: Boolean, pulseTrigger: Int = 0) {
    val colors = AppTheme.colors
    var expanded by remember { mutableStateOf(false) }
    val online = connected && rssi != null
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

    GlassButton(
        onClick = { expanded = !expanded },
        shape = RoundedCornerShape(22.dp),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 9.dp),
        // 顶栏按钮统一 36dp 高；信号条内容 15dp，在按钮内垂直居中。
        modifier = Modifier
            .height(36.dp)
            .graphicsLayer {
                scaleX = pulse.value
                scaleY = pulse.value
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
                    text = "$r dBm",
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
    onTransferGroup: (List<NikonCamera.FileInfo>) -> Unit
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
        GlassButton(
            onClick = { onTransferGroup(remainingGroupFiles) },
            enabled = remainingGroupFiles.isNotEmpty(),
            shape = RoundedCornerShape(14.dp),
            modifier = Modifier.height(28.dp),
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
    onTransferGroup: (List<NikonCamera.FileInfo>) -> Unit,
    onTapFile: (NikonCamera.FileInfo) -> Unit,
    onPreview: (NikonCamera.FileInfo, Rect) -> Unit,
    contentPadding: PaddingValues,
    gridState: LazyGridState,
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
                        reveal = group.date == recentlyExpanded,
                        // 级联错峰：组内前 18 格按 15ms 递增，其余同批（基本都在屏外）。
                        revealDelayMs = (index.coerceAtMost(18) * 15).toLong(),
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
    reveal: Boolean = false,
    revealDelayMs: Long = 0L,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    // 展开入场：本组刚被展开时淡入+轻微放大、按 revealDelayMs 级联错峰；
    // 平时（滚动进入）revealProgress 初始即 1，直接全显、零开销。
    val revealProgress = remember { Animatable(if (reveal) 0f else 1f) }
    LaunchedEffect(Unit) {
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
            .onGloballyPositioned { cellBounds = it.boundsInRoot() }
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
                ".mov" -> colors.accentOrange.copy(alpha = 0.85f)
                else -> colors.surfaceVariant.copy(alpha = 0.85f)
            },
            modifier = Modifier.align(Alignment.TopStart)
        ) {
            Text(
                text = file.extension.uppercase().removePrefix("."),
                modifier = Modifier.padding(horizontal = 4.dp, vertical = 1.dp),
                style = MaterialTheme.typography.labelSmall.copy(fontSize = 9.sp, lineHeight = 10.sp),
                fontWeight = FontWeight.Medium,
                color = if (file.extension in setOf(".jpg", ".nef", ".mov")) colors.onAccent else colors.onSurfaceVariant
            )
        }

        // 已入队：遮罩 + 状态角标
        if (task != null) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(colors.background.copy(alpha = 0.35f))
            )
            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(4.dp)
            ) {
                TransferStatusIndicator(status = task.status)
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
 * 类型筛选下拉面板：自动列出设备上实际存在的类型，多选 + "全部"；点确定才提交生效。
 * 语义：勾"全部"= 不过滤（未来出现的新类型也放行）；点具体类型自动脱离"全部"；
 * 全不选或凑齐全部现有类型时自动归位"全部"（不允许空集）。
 */
@Composable
private fun FilterDropdown(
    availableExts: List<String>,
    current: Set<String>?,
    onConfirm: (Set<String>?) -> Unit
) {
    val colors = AppTheme.colors
    // 工作副本：确定前不生效；面板随开合重建，每次打开都从当前设置初始化。
    var working by remember { mutableStateOf(current) }

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

    Surface(
        shape = RoundedCornerShape(16.dp),
        color = colors.glassSurfaceHeavy,
        border = BorderStroke(1.dp, colors.glassPanelBorder),
        shadowElevation = 6.dp,
        // 消费面板内点击，避免穿透到外部捕获层被误关闭。
        modifier = Modifier
            .width(FILTER_PANEL_WIDTH)
            .pointerInput(Unit) { detectTapGestures { } }
    ) {
        Column(
            modifier = Modifier.padding(8.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            FilterRow(label = stringResource(R.string.filter_all), selected = working == null, onClick = { working = null })
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 6.dp, vertical = 3.dp)
                    .height(1.dp)
                    .background(colors.glassPanelBorder)
            )
            availableExts.forEach { ext ->
                FilterRow(
                    label = extLabel(ext),
                    selected = working?.contains(ext) ?: true,
                    onClick = { toggle(ext) }
                )
            }
            Spacer(modifier = Modifier.height(4.dp))
            // 确认：毛玻璃对号按钮（与全局悬浮控件同语言，不再用实色大按钮）。
            GlassButton(
                onClick = { onConfirm(working) },
                shape = RoundedCornerShape(10.dp),
                contentPadding = PaddingValues(vertical = 7.dp),
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
 * 筛选面板的选项行：整行可点，选中态用高亮底色 + 主题蓝加粗文字表达（无勾选框）。
 */
@Composable
private fun FilterRow(label: String, selected: Boolean, onClick: () -> Unit) {
    val colors = AppTheme.colors
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(9.dp))
            .background(if (selected) colors.accentBlue.copy(alpha = 0.18f) else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 9.dp)
    ) {
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) colors.accentBlue else colors.onSurfaceVariant
        )
    }
}

/** 缩略图角标：已入队文件在缩略图右下角显示的传输状态小图标。 */
@Composable
private fun TransferStatusIndicator(status: TransferStatus) {
    val colors = AppTheme.colors
    when (status) {
        TransferStatus.COMPLETED -> Icon(
            imageVector = Icons.Default.CheckCircle,
            contentDescription = stringResource(R.string.cd_transferred),
            tint = colors.statusConnected,
            modifier = Modifier.size(18.dp)
        )
        TransferStatus.TRANSFERING -> CircularProgressIndicator(
            modifier = Modifier.size(16.dp),
            color = colors.accentBlue,
            strokeWidth = 2.dp
        )
        TransferStatus.WAITING -> Icon(
            imageVector = Icons.Default.HourglassEmpty,
            contentDescription = stringResource(R.string.cd_queued),
            tint = colors.accentBlue,
            modifier = Modifier.size(18.dp)
        )
        TransferStatus.FAILED -> Icon(
            imageVector = Icons.Default.Error,
            contentDescription = stringResource(R.string.cd_failed),
            tint = colors.statusError,
            modifier = Modifier.size(18.dp)
        )
        TransferStatus.CANCELLED -> Icon(
            imageVector = Icons.Default.Cancel,
            contentDescription = stringResource(R.string.cd_cancelled),
            tint = colors.onSurfaceVariant,
            modifier = Modifier.size(18.dp)
        )
    }
}
