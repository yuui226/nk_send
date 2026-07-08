package com.nikon.transfer.ui.screen

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
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
import com.nikon.transfer.ui.util.formatSpeed
import com.nikon.transfer.viewmodel.CameraViewModel
import com.nikon.transfer.viewmodel.TransferStatus
import com.nikon.transfer.viewmodel.TransferTask
import com.nikon.transfer.viewmodel.TransferViewModel
import com.nikon.transfer.viewmodel.currentFileProgress
import com.nikon.transfer.viewmodel.remainingCount
import kotlinx.coroutines.delay

data class FileGroup(
    val date: String,
    val files: List<NikonCamera.FileInfo>
)

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
    // "Z传" 按钮在根坐标系中的中心，作为设置面板"从按钮变形展开"的动画原点。
    var zAnchor by remember { mutableStateOf<Offset?>(null) }

    // 文件列表是连接成功后的主页面：返回不回到连接页，而是"再按一次退出应用"。
    val context = LocalContext.current
    var lastBackTime by remember { mutableStateOf(0L) }
    BackHandler {
        val now = System.currentTimeMillis()
        if (now - lastBackTime < 2000L) {
            context.findActivity()?.finish()
        } else {
            lastBackTime = now
            Toast.makeText(context, "再按一次退出", Toast.LENGTH_SHORT).show()
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
    // 长按预览：全屏翻页 + 从被长按格子的位置放大展开。
    var previewIndex by remember { mutableStateOf<Int?>(null) }
    var previewAnchor by remember { mutableStateOf<Rect?>(null) }
    val onPreview: (NikonCamera.FileInfo, Rect) -> Unit = { file, rect ->
        val idx = flatFiles.indexOfFirst { it.handle == file.handle }
        if (idx >= 0) {
            previewIndex = idx
            previewAnchor = rect
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
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
                    // 只加入队列、原地继续浏览，不跳转到队列页（想看进度可点右上角胶囊进入）。
                    transferViewModel.addToQueue(remaining, cameraViewModel::getCamera)
                }
            }
            val onTapFile: (NikonCamera.FileInfo) -> Unit = onTapFile@{ file ->
                if (transferState.transferDirUri == null) {
                    showSettings = true; return@onTapFile
                }
                if (state.isConnectedToCamera) {
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

        // ---------- 悬浮顶部控件（不占高度，浮在内容上）----------
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // 左："Z传" 悬浮按钮，本身即为设置入口（点击打开设置弹窗）。毛玻璃观感复用 GlassButton。
            GlassButton(
                onClick = { showSettings = true },
                shape = RoundedCornerShape(22.dp),
                contentPadding = PaddingValues(horizontal = 18.dp, vertical = 9.dp),
                modifier = Modifier.onGloballyPositioned { zAnchor = it.boundsInRoot().center }
            ) {
                Text(
                    "Z传",
                    fontWeight = FontWeight.Bold,
                    style = MaterialTheme.typography.titleMedium,
                    color = DarkOnBackground
                )
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
                    QueuePill(transferState = transferState, onClick = onNavigateToTransfer)
                }
            }
        }

        // 设置面板（点击 "Z传" 或未设目录时弹出），从 "Z传" 按钮位置变形展开。
        if (showSettings) {
            SettingsOverlay(
                viewModel = transferViewModel,
                anchorCenter = zAnchor,
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
    onClick: () -> Unit
) {
    val remaining = transferState.remainingCount
    val allDone = remaining == 0
    val transferring = transferState.isTransferring
    // 进度条 = 当前单文件进度（复用传输页语义）；全部传完时填满。
    val barFraction = if (allDone) 1f else transferState.currentFileProgress

    // "done → 图标" 的转场只由"传输中 → 全部完成"触发。prevAllDone 初值取当前 allDone：
    // 若进入本页时已是完成态（例如从队列页返回），不再闪 done，直接显示图标（无转场动画）。
    var showDoneLabel by remember { mutableStateOf(false) }
    var prevAllDone by remember { mutableStateOf(allDone) }
    LaunchedEffect(allDone) {
        if (allDone && !prevAllDone) {
            showDoneLabel = true
            delay(1800)
            showDoneLabel = false
        }
        prevAllDone = allDone
    }
    val collapsedToIcon = allDone && !showDoneLabel

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
                widthAnim.animateTo(
                    contentWidthPx.toFloat(),
                    spring(dampingRatio = Spring.DampingRatioMediumBouncy, stiffness = Spring.StiffnessMediumLow)
                )
            }
        }
    }

    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(22.dp),
        color = DarkSurface.copy(alpha = 0.45f),   // 毛玻璃半透明底（与 "Z传" 一致）
        shadowElevation = 4.dp,
        modifier = Modifier
            .height(40.dp)
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
                    if (collapsedToIcon) {
                        // 传输入口图标：清单勾选，直观表示"传输"。
                        Icon(
                            imageVector = Icons.Default.Checklist,
                            contentDescription = "传输",
                            tint = StatusConnected,
                            modifier = Modifier
                                .padding(horizontal = 12.dp)
                                .size(22.dp)
                        )
                    } else {
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
                            // 剩余数量在后；刚全部完成的短暂窗口内显示 done。
                            Text(
                                text = if (allDone) "done" else "$remaining",
                                style = MaterialTheme.typography.labelLarge.copy(fontFeatureSettings = "tnum"),
                                color = if (allDone) StatusConnected else DarkOnBackground,
                                fontWeight = FontWeight.Bold
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * Wi-Fi 信号毛玻璃按钮（"Z传" 边上）：默认只显示 4 格信号条（图标样式），
 * 点击展开一并显示具体 dBm 数值，再点收起。数值实时刷新（数据源每 1.5s 更新一次）。
 */
@Composable
private fun SignalPill(rssi: Int) {
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
        else -> AccentRed
    }

    GlassButton(
        onClick = { expanded = !expanded },
        shape = RoundedCornerShape(22.dp),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 9.dp),
        // 展开/收起显示 dBm 时按钮宽度变化，复用胶囊同款弹性 spring。
        // 本按钮左对齐、向右伸进中间弹性空档，不存在胶囊那种右溢出问题，故直接用 animateContentSize。
        modifier = Modifier.animateContentSize(
            animationSpec = spring(
                dampingRatio = Spring.DampingRatioMediumBouncy,
                stiffness = Spring.StiffnessMediumLow
            )
        )
    ) {
        // 信号条：4 格递增高度，按等级点亮，颜色随强弱变化。
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(2.5.dp)) {
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
        if (expanded) {
            Text(
                text = "$rssi dBm",
                style = MaterialTheme.typography.labelMedium.copy(fontFeatureSettings = "tnum"),
                fontWeight = FontWeight.Medium,
                color = color
            )
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
        Text(
            text = formatDateHeader(group.date),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.Bold,
            color = DarkOnBackground
        )
        Spacer(modifier = Modifier.width(4.dp))
        // 展开/收起按钮：收起时朝下(可展开)，展开时朝上(可收起)。
        IconButton(
            onClick = onToggleCollapse,
            modifier = Modifier.size(28.dp)
        ) {
            Icon(
                if (collapsed) Icons.Default.ExpandMore else Icons.Default.ExpandLess,
                contentDescription = if (collapsed) "展开" else "收起",
                tint = AccentBlue,
                modifier = Modifier.size(22.dp)
            )
        }
        Spacer(modifier = Modifier.width(4.dp))
        Text(
            text = "${group.files.size}张",
            style = MaterialTheme.typography.bodySmall,
            color = DarkOnSurfaceVariant
        )
        Spacer(modifier = Modifier.weight(1f))
        val remainingGroupFiles = group.files.filter { it.handle !in queuedByHandle }
        FilledTonalButton(
            onClick = { onTransferGroup(remainingGroupFiles) },
            enabled = remainingGroupFiles.isNotEmpty(),
            shape = RoundedCornerShape(8.dp),
            modifier = Modifier.height(28.dp),
            contentPadding = PaddingValues(horizontal = 16.dp)
        ) {
            Text(
                if (remainingGroupFiles.isEmpty()) "已添加" else "传输",
                style = MaterialTheme.typography.bodySmall,
                color = DarkOnBackground
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
    modifier: Modifier = Modifier
) {
    LazyVerticalGrid(
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
                Column {
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
                        onPreview = onPreview
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
    onPreview: (NikonCamera.FileInfo, Rect) -> Unit
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
        modifier = Modifier
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
