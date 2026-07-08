package com.nikon.transfer.ui.screen

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nikon.transfer.protocol.NikonCamera
import com.nikon.transfer.ui.theme.*
import com.nikon.transfer.ui.util.Haptics
import com.nikon.transfer.ui.util.formatSpeed
import com.nikon.transfer.ui.util.rememberHaptics
import com.nikon.transfer.viewmodel.CameraViewModel
import com.nikon.transfer.viewmodel.TransferStatus
import com.nikon.transfer.viewmodel.TransferTask
import com.nikon.transfer.viewmodel.TransferViewModel
import com.nikon.transfer.viewmodel.currentFileProgress
import com.nikon.transfer.viewmodel.remainingCount
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest

data class FileGroup(
    val date: String,
    val files: List<NikonCamera.FileInfo>
)

/** 队列胶囊的三种内容形态：入口图标 / 完成短标 / 计数（速度+剩余数）。 */
private enum class PillMode { ICON, DONE, COUNTING }

// 缩略图预取窗口：可见区之后/之前各多拉多少张进缓存。向下开到 200（约十二屏，3 列时），
// 空闲时后台持续填充；串行排队 + 窗口变化即取消，不会挤占可见格子和传输。
// 内存缓存为堆的 1/8（典型可容 200~400 张），超出由 LRU 淘汰最远端，视口附近始终新鲜。
private const val PREFETCH_AHEAD = 200
private const val PREFETCH_BEHIND = 12

/** 从 Compose 的 Context 逐层向上找到宿主 Activity（用于返回键退出应用）。 */
private fun Context.findActivity(): Activity? {
    var ctx: Context? = this
    while (ctx is ContextWrapper) {
        if (ctx is Activity) return ctx
        ctx = ctx.baseContext
    }
    return null
}

fun groupFilesByDate(files: List<NikonCamera.FileInfo>): List<FileGroup> {
    val grouped = files.groupBy { it.captureDate?.take(8) ?: "未知日期" }
    return grouped.map { (date, groupFiles) ->
        FileGroup(date = date, files = groupFiles.sortedByDescending { it.captureDate ?: "" })
    }.sortedByDescending { it.date }
}

@Composable
fun FileListScreen(
    cameraViewModel: CameraViewModel,
    transferViewModel: TransferViewModel,
    onNavigateToTransfer: () -> Unit
) {
    val state by cameraViewModel.state.collectAsState()
    val transferState by transferViewModel.state.collectAsState()
    // 设置以轻量面板呈现（点击左上角 "Z传" 打开），不再跳转独立页面。
    var showSettings by remember { mutableStateOf(false) }
    // 双 Z 标按钮在根坐标系中的边界：设置面板贴其下缘展开（下拉弹窗），并以其中心为动画原点。
    var zAnchor by remember { mutableStateOf<Rect?>(null) }

    // 文件列表是连接成功后的主页面：返回不回到连接页，而是"再按一次退出应用"。
    // 提示用自绘玻璃条（见下方 exitHint），与深色玻璃语言一致，替代系统 Toast。
    val context = LocalContext.current
    var lastBackTime by remember { mutableStateOf(0L) }
    var exitHintVisible by remember { mutableStateOf(false) }
    BackHandler {
        val now = System.currentTimeMillis()
        if (now - lastBackTime < 2000L) {
            context.findActivity()?.finish()
        } else {
            lastBackTime = now
            exitHintVisible = true
        }
    }
    // 自动隐藏；期间再按返回会更新 lastBackTime 重启计时。
    LaunchedEffect(lastBackTime) {
        if (exitHintVisible) {
            delay(1800)
            exitHintVisible = false
        }
    }

    val topInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val bottomInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    // 列表内容内边距：顶部让出状态栏 + 悬浮控件高度；底部让出导航栏。内容本身 edge-to-edge。
    val listPadding = PaddingValues(
        start = 12.dp,
        end = 12.dp,
        top = topInset + 60.dp,
        bottom = bottomInset + 12.dp
    )

    // 分组 / 扁平列表（供长按预览翻页）/ 传输忙碌（缩略图让路）——提到顶层，供内容区与预览层共用。
    val groups = remember(state.files) { groupFilesByDate(state.files) }
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
    Box(modifier = Modifier.fillMaxSize().background(DarkBackground)) {
        // ---------- 内容（铺满，延伸到系统栏后面）----------
        if (state.isLoadingFiles && state.files.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(color = AccentBlue)
                    Spacer(modifier = Modifier.height(16.dp))
                    Text("正在获取文件列表...", color = DarkOnSurfaceVariant)
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
                        // 空列表更可能是连接断开（而非相机真的没照片）——如实提示并说明会自动重连。
                        Icon(Icons.Default.WifiOff, contentDescription = null, modifier = Modifier.size(64.dp), tint = AccentOrange)
                        Spacer(modifier = Modifier.height(16.dp))
                        Text("与相机的连接已断开", color = DarkOnBackground, style = MaterialTheme.typography.titleMedium)
                        Spacer(modifier = Modifier.height(6.dp))
                        Text(
                            "请连接到相机 Wi-Fi",
                            color = DarkOnSurfaceVariant,
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
                            Icon(Icons.Default.Wifi, contentDescription = null, tint = AccentBlue, modifier = Modifier.size(20.dp))
                            Text(
                                "打开 Wi-Fi 设置",
                                style = MaterialTheme.typography.labelLarge,
                                fontWeight = FontWeight.Medium,
                                color = DarkOnBackground
                            )
                        }
                    } else {
                        Icon(Icons.Default.FolderOff, contentDescription = null, modifier = Modifier.size(64.dp), tint = DarkOnSurfaceVariant)
                        Spacer(modifier = Modifier.height(16.dp))
                        Text("相机中没有照片", color = DarkOnSurfaceVariant)
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
                if (state.isConnectedToCamera && remaining.isNotEmpty()) {
                    haptics.tick()   // 整组入队只震一次
                    // 只加入队列、原地继续浏览，不跳转到队列页（想看进度可点右上角胶囊进入）。
                    transferViewModel.addToQueue(remaining, cameraViewModel::getCamera)
                }
            }
            val onTapFile: (NikonCamera.FileInfo) -> Unit = onTapFile@{ file ->
                if (transferState.transferDirUri == null) {
                    showSettings = true; return@onTapFile
                }
                if (state.isConnectedToCamera) {
                    haptics.tick()   // 只在真正入队时震（引导去设置/未连接时不震）
                    transferViewModel.addToQueue(listOf(file), cameraViewModel::getCamera)
                }
            }

            // transfersBusy 时缩略图让路：只用缓存，不发起新的 GetThumb，避免抢占下载通道。
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
                modifier = Modifier.fillMaxSize()
            )
        }

        // ---------- 顶部渐变 scrim：edge-to-edge 内容滚到状态栏后面时，保证状态栏图标
        // 与悬浮控件在任何内容上都可读，也让顶栏更有"浮在雾面上"的层次 ----------
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(topInset + 56.dp)
                .background(
                    Brush.verticalGradient(
                        0f to DarkBackground.copy(alpha = 0.85f),
                        0.45f to DarkBackground.copy(alpha = 0.5f),
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

            // "Z传" 边上的 Wi-Fi 信号按钮：默认只显示信号条，点击展开显示具体 dBm 数值。
            // 传输慢时一眼判断是不是信号弱（信号是 CameraViewModel 每 1.5s 顺带读取，无额外轮询开销）。
            state.wifiRssi?.let { rssi ->
                Spacer(modifier = Modifier.width(8.dp))
                SignalPill(rssi = rssi)
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

        // 底部"再按一次退出"玻璃提示条（替代系统 Toast，与深色玻璃语言一致）。
        AnimatedVisibility(
            visible = exitHintVisible,
            enter = fadeIn() + slideInVertically { it / 2 },
            exit = fadeOut() + slideOutVertically { it / 2 },
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 28.dp)
        ) {
            Surface(
                shape = RoundedCornerShape(22.dp),
                color = DarkSurface.copy(alpha = 0.9f),
                shadowElevation = 6.dp,
                border = BorderStroke(1.dp, Color.White.copy(alpha = 0.15f))
            ) {
                Text(
                    "再按一次退出",
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
                    style = MaterialTheme.typography.labelLarge,
                    color = DarkOnBackground
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
                    transfersBusy = transfersBusy,
                    cameraViewModel = cameraViewModel,
                    onDismiss = { previewIndex = null }
                )
            }
        }
    }
}

@Composable
fun QueuePill(
    transferState: com.nikon.transfer.viewmodel.TransferState,
    haptics: Haptics,
    onClick: () -> Unit
) {
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
    LaunchedEffect(allDone) {
        if (allDone && !prevAllDone) {
            if (sawTransfer) haptics.success()
            sawTransfer = false
            showDoneLabel = true
            delay(1800)
            showDoneLabel = false
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
        color = DarkSurface.copy(alpha = 0.45f),   // 毛玻璃半透明底（与 "Z传" 一致）
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
                                color = AccentBlue.copy(alpha = 0.35f),
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
                            listOf(Color.White.copy(alpha = 0.14f), Color.White.copy(alpha = 0.03f))
                        )
                    )
                    .border(
                        width = 1.dp,
                        brush = Brush.verticalGradient(
                            listOf(Color.White.copy(alpha = 0.4f), Color.White.copy(alpha = 0.08f))
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
                                    contentDescription = "传输",
                                    tint = StatusConnected,
                                    modifier = Modifier
                                        .padding(horizontal = 12.dp)
                                        .size(22.dp)
                                )
                            PillMode.DONE ->
                                Text(
                                    text = "done",
                                    style = MaterialTheme.typography.labelLarge.copy(fontFeatureSettings = "tnum"),
                                    color = StatusConnected,
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
                                            color = AccentBlue,
                                            fontWeight = FontWeight.Bold
                                        )
                                    }
                                    Text(
                                        text = "$remaining",
                                        style = MaterialTheme.typography.labelLarge.copy(fontFeatureSettings = "tnum"),
                                        color = DarkOnBackground,
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

/**
 * Wi-Fi 信号毛玻璃按钮：默认只显示 4 格信号条（图标样式），点击展开一并显示具体 dBm
 * 数值，再点收起。数值实时刷新（数据源每 1.5s 更新一次）。
 * "Z传"页（"Z传"按钮右侧）与队列页（返回按钮右侧）顶栏共用。
 */
@Composable
fun SignalPill(rssi: Int) {
    var expanded by remember { mutableStateOf(false) }
    // dBm 越接近 0 越强。判定从严：满格只给极好信号，稍差立刻掉格。
    //  -30↑ 满格 / -45↑ 三格 / -55↑ 两格 / -65↑ 一格 / 更弱 0 格。
    val level = when {
        rssi >= -30 -> 4
        rssi >= -45 -> 3
        rssi >= -55 -> 2
        rssi >= -65 -> 1
        else -> 0
    }
    val color = when {
        level == 4 -> StatusConnected
        level >= 2 -> AccentOrange
        else -> StatusError
    }

    GlassButton(
        onClick = { expanded = !expanded },
        shape = RoundedCornerShape(22.dp),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 9.dp),
        // 顶栏按钮统一 36dp 高；信号条内容 15dp，在按钮内垂直居中。
        modifier = Modifier.height(36.dp)
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
            // 信号条：4 格递增高度，按等级点亮，颜色随强弱变化。
            Row(
                modifier = Modifier.fillMaxHeight(),
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(2.5.dp)
            ) {
                repeat(4) { i ->
                    val on = i < level.coerceAtLeast(1)   // 至少亮一格，表示"在连接中"
                    Box(
                        modifier = Modifier
                            .width(4.dp)
                            .height((6 + i * 3).dp)
                            .clip(RoundedCornerShape(1.5.dp))
                            .background(if (on) color else DarkOnSurfaceVariant.copy(alpha = 0.28f))
                    )
                }
            }
            AnimatedVisibility(
                visible = expanded,
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
                    text = "$rssi dBm",
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
                text = formatDateHeader(group.date),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Bold,
                color = DarkOnBackground
            )
            Icon(
                Icons.Default.ExpandMore,
                contentDescription = if (collapsed) "展开" else "收起",
                tint = AccentBlue,
                modifier = Modifier
                    .size(18.dp)
                    .rotate(chevron)
            )
            // 仅数字（去掉"张"），tnum 等宽，界面更简约
            Text(
                text = "${group.files.size}",
                style = MaterialTheme.typography.bodySmall.copy(fontFeatureSettings = "tnum"),
                color = DarkOnSurfaceVariant
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
                contentDescription = if (allQueued) "已全部加入队列" else "传输整组",
                tint = if (allQueued) StatusConnected else AccentBlue,
                modifier = Modifier.size(18.dp)
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
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
    modifier: Modifier = Modifier
) {
    val gridState = rememberLazyGridState()

    // 预取可见区外的缩略图：向下 PREFETCH_AHEAD、向上 PREFETCH_BEHIND 张提前拉进缓存，
    // 格子滚进视野时直接命中，用户基本看不到黑格子。窗口按"可见的首/尾 cell key"去重，
    // 滚动一行才重发；collectLatest 让窗口变化即取消旧批次（"滚走剪枝"语义与格子一致）。
    LaunchedEffect(groups, transfersBusy) {
        snapshotFlow {
            val visible = gridState.layoutInfo.visibleItemsInfo
            Triple(
                visible.firstOrNull { it.key is Int }?.key as? Int,
                visible.lastOrNull { it.key is Int }?.key as? Int,
                // 展开状态变化也要重算预取窗口
                groups.filter { collapsedDates[it.date] != true }.map { it.date }
            )
        }.collectLatest { (firstKey, lastKey, _) ->
            if (lastKey == null) return@collectLatest
            val ordered = groups.filter { collapsedDates[it.date] != true }.flatMap { it.files }
            val lastIdx = ordered.indexOfFirst { it.handle == lastKey }
            if (lastIdx < 0) return@collectLatest
            val firstIdx = firstKey
                ?.let { k -> ordered.indexOfFirst { it.handle == k } }
                ?.takeIf { it >= 0 } ?: lastIdx
            val ahead = ordered.subList(
                (lastIdx + 1).coerceAtMost(ordered.size),
                (lastIdx + 1 + PREFETCH_AHEAD).coerceAtMost(ordered.size)
            )
            val behind = ordered.subList(
                (firstIdx - PREFETCH_BEHIND).coerceAtLeast(0),
                firstIdx
            )
            // 向下优先、由近及远；向上的按"离视口近的先取"倒序。
            for (file in ahead + behind.reversed()) {
                cameraViewModel.loadThumbnail(file.handle, allowFetch = !transfersBusy)
            }
        }
    }

    LazyVerticalGrid(
        state = gridState,
        columns = GridCells.Fixed(columns.coerceIn(1, 4)),
        modifier = modifier,
        contentPadding = contentPadding,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        groups.forEach { group ->
            val collapsed = collapsedDates[group.date] == true
            // 分组头整行跨列，保持与列表模式一致的分组语义
            item(
                span = { GridItemSpan(maxLineSpan) },
                key = "header_${group.date}",
                contentType = "header"
            ) {
                // 分组收起/展开时，本头（及其后所有内容）弹性滑到新位置而不是闪现。
                Column(modifier = Modifier.animateItemPlacement(Motion.itemPlacement)) {
                    Spacer(modifier = Modifier.height(4.dp))
                    GroupHeader(
                        group = group,
                        queuedByHandle = queuedByHandle,
                        collapsed = collapsed,
                        onToggleCollapse = { collapsedDates[group.date] = !collapsed },
                        onTransferGroup = onTransferGroup
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                }
            }
            // 收起的分组不 emit cell：ThumbnailCell 不 compose → 不触发 GetThumb，
            // 从而"锁起来"的缩略图不加载；展开后 cell 重新 emit 才恢复加载。
            if (!collapsed) {
                items(group.files, key = { it.handle }, contentType = { "cell" }) { file ->
                    ThumbnailCell(
                        file = file,
                        task = queuedByHandle[file.handle],
                        transfersBusy = transfersBusy,
                        cameraViewModel = cameraViewModel,
                        onTapFile = onTapFile,
                        onPreview = onPreview,
                        modifier = Modifier.animateItemPlacement(Motion.itemPlacement)
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
    modifier: Modifier = Modifier
) {
    // 已加载的缩略图按 handle 记住，transfersBusy 变化不会让它闪回占位。
    var thumbnail by remember(file.handle) { mutableStateOf<ImageBitmap?>(null) }
    // 仅在尚未加载时才尝试取；传输进行中只读缓存(allowFetch=false)，队列空闲后本效应重跑自动补载。
    LaunchedEffect(file.handle, transfersBusy) {
        if (thumbnail == null) {
            thumbnail = cameraViewModel.loadThumbnail(file.handle, allowFetch = !transfersBusy)
        }
    }
    // 记录本格子在根坐标系中的位置，供长按预览"从格子位置放大"用。
    var cellBounds by remember { mutableStateOf<Rect?>(null) }

    Box(
        modifier = modifier
            .aspectRatio(1f)
            .clip(RoundedCornerShape(8.dp))
            .background(DarkSurface)
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
                contentScale = ContentScale.Crop,
                // 相机缩略图常带上下黑边（3:2 画面塞进 4:3 缩略图）；轻微放大裁掉黑边。
                modifier = Modifier
                    .fillMaxSize()
                    .scale(1.12f)
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
                    tint = DarkOnSurfaceVariant.copy(alpha = 0.4f),
                    modifier = Modifier.size(28.dp)
                )
            }
        }

        // 左上角类型角标
        Surface(
            shape = RoundedCornerShape(bottomEnd = 6.dp),
            color = when (file.extension) {
                ".jpg" -> AccentBlue.copy(alpha = 0.85f)
                ".nef" -> AccentPurple.copy(alpha = 0.85f)
                ".mov" -> AccentOrange.copy(alpha = 0.85f)
                else -> DarkSurfaceVariant.copy(alpha = 0.85f)
            },
            modifier = Modifier.align(Alignment.TopStart)
        ) {
            Text(
                text = file.extension.uppercase().removePrefix("."),
                modifier = Modifier.padding(horizontal = 4.dp, vertical = 1.dp),
                style = MaterialTheme.typography.labelSmall.copy(fontSize = 9.sp, lineHeight = 10.sp),
                fontWeight = FontWeight.Medium,
                color = DarkBackground
            )
        }

        // 已入队：遮罩 + 状态角标
        if (task != null) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(DarkBackground.copy(alpha = 0.35f))
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
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically
    ) {
        CircularProgressIndicator(
            modifier = Modifier.size(20.dp),
            color = AccentBlue,
            strokeWidth = 2.dp
        )
        Spacer(modifier = Modifier.width(8.dp))
        Text("正在加载更多文件...", style = MaterialTheme.typography.bodySmall, color = DarkOnSurfaceVariant)
    }
}

private fun formatDateHeader(date: String): String {
    if (date.length < 8 || date == "未知日期") return date
    return "${date.substring(0, 4)}-${date.substring(4, 6)}-${date.substring(6, 8)}"
}

/** 缩略图角标：已入队文件在缩略图右下角显示的传输状态小图标。 */
@Composable
private fun TransferStatusIndicator(status: TransferStatus) {
    when (status) {
        TransferStatus.COMPLETED -> Icon(
            imageVector = Icons.Default.CheckCircle,
            contentDescription = "已传输",
            tint = StatusConnected,
            modifier = Modifier.size(18.dp)
        )
        TransferStatus.TRANSFERING -> CircularProgressIndicator(
            modifier = Modifier.size(16.dp),
            color = AccentBlue,
            strokeWidth = 2.dp
        )
        TransferStatus.WAITING -> Icon(
            imageVector = Icons.Default.HourglassEmpty,
            contentDescription = "排队中",
            tint = AccentBlue,
            modifier = Modifier.size(18.dp)
        )
        TransferStatus.FAILED -> Icon(
            imageVector = Icons.Default.Error,
            contentDescription = "传输失败",
            tint = StatusError,
            modifier = Modifier.size(18.dp)
        )
        TransferStatus.CANCELLED -> Icon(
            imageVector = Icons.Default.Cancel,
            contentDescription = "已取消",
            tint = DarkOnSurfaceVariant,
            modifier = Modifier.size(18.dp)
        )
    }
}
