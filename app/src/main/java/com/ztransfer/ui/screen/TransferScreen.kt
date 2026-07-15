package com.ztransfer.ui.screen

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.PtpConstants
import com.ztransfer.ui.theme.*
import com.ztransfer.ui.util.formatDuration
import com.ztransfer.ui.util.formatFileSize
import com.ztransfer.ui.util.formatSpeed
import com.ztransfer.ui.util.rememberHaptics
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TransferScreen(
    transferViewModel: TransferViewModel,
    cameraViewModel: CameraViewModel,
    onNavigateBack: () -> Unit
) {
    val transferState by transferViewModel.state.collectAsState()
    // 响应式连接状态：断开/重连即时反映到重试按钮的可用性（getCamera() 不是快照状态，不能作 gating）。
    val cameraState by cameraViewModel.state.collectAsState()
    val colors = AppTheme.colors
    // 清空/重试二次确认的展开状态（提到这层，便于全屏遮罩接管"点击外部关闭"）。
    var showClearConfirm by remember { mutableStateOf(false) }
    var showRetryConfirm by remember { mutableStateOf(false) }
    // 正在播放移除动画的任务：卡片收合完毕后才真正从队列删除。
    // 等待中的任务在标记的同时已被 withdraw（置 CANCELLED），动画期间队列不会开始传它。
    val removingHandles = remember { mutableStateMapOf<Int, Unit>() }
    val clearScope = rememberCoroutineScope()
    // 触感反馈（与"Z传"页同一开关）；本页胶囊负责传输全部完成时的成功震动。
    val haptics = rememberHaptics(transferState.hapticsEnabled)
    // 卡片顶部 sheen 高光刷（与玻璃面板同族材质）；提升到列表外，所有卡片共用一个实例。
    // 透明度封顶 10%：面板用的 glassSheen 在浅色主题高达 55%（白面板上白高光看不出来），
    // 直接叠在蓝/绿调的状态卡上会把卡片上半部洗白；深色主题 8% 原样通过。
    val cardSheen = remember(colors) {
        val sheen = colors.glassSheen.copy(alpha = minOf(colors.glassSheen.alpha, 0.10f))
        Brush.verticalGradient(listOf(sheen, Color.Transparent))
    }

    // 存在可重试任务（失败/取消）且未在传输：右下角显示"重试全部"FAB。
    val hasRetryable = !transferState.isTransferring && transferState.tasks.any {
        it.status == TransferStatus.FAILED || it.status == TransferStatus.CANCELLED
    }
    // 清空队列只作用于"不在传输中"的任务（正在传的文件会传完，中途打断会让相机关 Wi-Fi）：
    // 有可清的卡片才显示扫帚 FAB；确认后卡片集体收合退场、FAB 随之消失。
    val hasClearable = transferState.tasks.any { it.status != TransferStatus.TRANSFERING }

    val topInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val bottomInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    // 内容 edge-to-edge（与 "Z传" 页一致，无顶部黑条）：顶部让出状态栏 + 悬浮控件；
    // 底部让出导航栏 + 右下角悬浮按钮（清空/重试，可能同时叠放两颗）的高度。
    val fabCount = (if (hasClearable) 1 else 0) + (if (hasRetryable) 1 else 0)
    val listPadding = PaddingValues(
        start = 12.dp,
        end = 12.dp,
        top = topInset + 58.dp,
        bottom = bottomInset + when (fabCount) {
            2 -> 168.dp
            1 -> 96.dp
            else -> 12.dp
        }
    )

    // 根需不透明底色：与"Z传"页左右滑动转场期间两页同屏层叠，透明根会让底层页面透出。
    // 用全局背景渐变刷（而非纯 background 色），与 Scaffold 底的纵深一致。
    Box(modifier = Modifier.fillMaxSize().background(rememberAppBackgroundBrush())) {
        // ---------- 内容（铺满，延伸到系统栏后面）----------
        if (transferState.tasks.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    // 空状态图标缓慢呼吸：页面此时无其它动态，一点"活感"不至于死板。
                    val breathe = rememberInfiniteTransition(label = "emptyQueue")
                    val breatheAlpha by breathe.animateFloat(
                        initialValue = 0.35f, targetValue = 0.6f,
                        animationSpec = infiniteRepeatable(tween(1600), RepeatMode.Reverse),
                        label = "emptyQueueAlpha"
                    )
                    Icon(
                        Icons.Default.CloudDownload, contentDescription = null,
                        modifier = Modifier.size(64.dp),
                        tint = colors.onSurfaceVariant.copy(alpha = breatheAlpha)
                    )
                    Spacer(modifier = Modifier.height(16.dp))
                    Text(stringResource(R.string.no_transfer_tasks), color = colors.onSurfaceVariant)
                }
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = listPadding
                // 行距烘焙在条目底部（8dp），随移除收合动画一起消失；
                // 用 spacedBy 的话卡片收合到 0 后仍残留间距，真正删除瞬间会跳一下。
            ) {
                // 倒序显示：最新加入队列的排在最上方（asReversed 是视图，不复制列表）。
                items(transferState.tasks.asReversed(), key = { it.file.handle }) { task ->
                    val handle = task.file.handle
                    val removing = removingHandles.containsKey(handle)
                    // 移除动画：真实高度收合 + 淡出（collapseHeight，与列表页分组收合同款），
                    // 收合完毕才从队列删除，下方卡片随布局逐帧上移，无跳变。
                    val removeProgress = remember(handle) { Animatable(1f) }
                    LaunchedEffect(removing) {
                        if (removing) {
                            removeProgress.animateTo(0f, tween(280, easing = FastOutSlowInEasing))
                            // 先清标记再删数据：同 handle 之后重新入队时不会误播移除动画。
                            removingHandles.remove(handle)
                            if (!transferViewModel.removeTask(handle)) {
                                // 竞态兜底：动画期间任务已开始传输/被重试回等待，不可移除——
                                // 卡片弹回原高继续显示（成功移除时本条目已随删除离场，走不到这）。
                                removeProgress.animateTo(1f, tween(200, easing = FastOutSlowInEasing))
                            }
                        }
                    }
                    // 动画中途条目被外因移出组合（如同时点了重试）：清掉标记，
                    // 该任务保留在队列里（安全侧），用户可再操作。
                    DisposableEffect(handle) {
                        onDispose { removingHandles.remove(handle) }
                    }
                    Box(
                        modifier = Modifier
                            // 上方卡片增删/长矮时，本卡平滑让位而不是硬跳。
                            .animateItemPlacement(Motion.itemPlacement)
                            .collapseHeight { removeProgress.value }
                            .padding(bottom = 8.dp)
                    ) {
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        // 14dp 与列表页卡片/监看页 tile 的中型控件圆角一致（原 12dp 家族外）。
                        shape = RoundedCornerShape(14.dp),
                        // 浅色下白卡浮在浅灰背景上需要发丝线定界；深色 token 为透明，视觉不变。
                        border = BorderStroke(1.dp, colors.cardHairline),
                        colors = CardDefaults.cardColors(
                            containerColor = when (task.status) {
                                TransferStatus.TRANSFERING -> colors.accentBlue.copy(alpha = 0.1f)
                                TransferStatus.COMPLETED -> colors.statusConnected.copy(alpha = 0.1f)
                                TransferStatus.FAILED -> colors.statusError.copy(alpha = 0.1f)
                                TransferStatus.CANCELLED -> colors.surfaceVariant
                                TransferStatus.WAITING -> colors.surface
                            }
                        )
                    ) {
                        // 进度条/重试按钮随状态出现消失时，卡片高度平滑过渡，
                        // 卡内图标与文字不再瞬移。顶部 sheen 高光与玻璃面板同族材质。
                        Column(
                            modifier = Modifier
                                .background(cardSheen)
                                .animateContentSize(tween(250, easing = FastOutSlowInEasing))
                                .padding(12.dp)
                        ) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                // 前导状态标志：独立成卡片最左的"状态列"，与右侧操作按钮分居
                                // 两端——状态归状态、操作归操作。换状态交叉淡化不硬切；
                                // 传输→完成的瞬间弹一下（事件驱动、只在真在传时触发——
                                // 已完成卡片滚回屏幕不会重播），与全局"确认"手感一致。
                                val iconPop = remember(handle) { Animatable(1f) }
                                var prevStatus by remember(handle) { mutableStateOf(task.status) }
                                LaunchedEffect(task.status) {
                                    val was = prevStatus
                                    prevStatus = task.status
                                    if (task.status == TransferStatus.COMPLETED && was == TransferStatus.TRANSFERING) {
                                        iconPop.snapTo(0.5f)
                                        iconPop.animateTo(1f, Motion.bouncy())
                                    }
                                }
                                Box(
                                    Modifier.graphicsLayer {
                                        scaleX = iconPop.value
                                        scaleY = iconPop.value
                                    }
                                ) {
                                    Crossfade(targetState = task.status, animationSpec = tween(220), label = "taskIcon") { st ->
                                        TaskStatusIcon(st, size = 20.dp)
                                    }
                                }
                                Spacer(modifier = Modifier.width(10.dp))

                                // 缩略图：屏幕内的卡片始终允许取图（传输中请求排到
                                // 文件间隙执行），isTransferring 仅作传输结束后的补载重试键。
                                QueueThumbnail(
                                    file = task.file,
                                    retryNudge = transferState.isTransferring,
                                    cameraViewModel = cameraViewModel
                                )

                                Spacer(modifier = Modifier.width(12.dp))

                                // 中部两行：文件名 + 状态副信息，撑满前导高度，充分利用竖向空间。
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = task.file.fileName,
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontWeight = FontWeight.Medium,
                                        color = if (task.status == TransferStatus.CANCELLED) colors.onSurfaceVariant else colors.onBackground,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    Spacer(modifier = Modifier.height(3.dp))
                                    val (subText, subColor) = when (task.status) {
                                        TransferStatus.WAITING -> stringResource(R.string.status_waiting) to colors.onSurfaceVariant
                                        TransferStatus.TRANSFERING -> {
                                            // >4GB 对象的 file.size 只是 SIZE_UNKNOWN 哨兵，别显示假总量。
                                            val base = if (task.file.size == PtpConstants.SIZE_UNKNOWN) {
                                                formatFileSize(task.downloaded)
                                            } else {
                                                "${formatFileSize(task.downloaded)} / ${formatFileSize(task.file.size)}"
                                            }
                                            (if (task.speed > 0) "$base · ${formatSpeed(task.speed)}" else base) to colors.accentBlue
                                        }
                                        TransferStatus.COMPLETED ->
                                            (when {
                                                task.skipped -> stringResource(R.string.status_skipped)
                                                // 大小 · 速度 · 耗时：一眼看出快慢与用时。大小取真实落盘字节数
                                                //（>4GB 对象的 file.size 只是哨兵值）；耗时完成后填入。
                                                else -> buildString {
                                                    append(formatFileSize(task.downloaded))
                                                    if (task.downloadMBps > 0f) append(" · %.1f MB/s".format(task.downloadMBps))
                                                    task.elapsedMs?.let { append(" · ${formatDuration(it)}") }
                                                }
                                            }) to colors.statusConnected
                                        TransferStatus.FAILED -> (task.error ?: stringResource(R.string.transfer_failed)) to colors.statusError
                                        TransferStatus.CANCELLED -> stringResource(R.string.status_cancelled) to colors.onSurfaceVariant
                                    }
                                    Text(
                                        text = subText,
                                        style = MaterialTheme.typography.labelMedium,
                                        color = subColor,
                                        // 失败原因带具体诊断信息（如"保存失败：复制不完整…"），
                                        // 放宽到两行让用户截图即含完整线索；其余状态保持单行紧凑。
                                        maxLines = if (task.status == TransferStatus.FAILED) 2 else 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                }

                                // 尾部操作列：重试(仅失败时,断开置灰) + 移除,同规格图标圆钮
                                // 并排——同为"对这张卡的操作",与最左的状态列互不混淆。
                                AnimatedVisibility(
                                    visible = task.status == TransferStatus.FAILED,
                                    enter = fadeIn() + expandHorizontally(expandFrom = Alignment.Start),
                                    exit = fadeOut() + shrinkHorizontally(shrinkTowards = Alignment.Start)
                                ) {
                                    Row {
                                        Spacer(modifier = Modifier.width(10.dp))
                                        val connected = cameraState.isConnectedToCamera
                                        GlassButton(
                                            onClick = { transferViewModel.retrySingleTask(task.file.handle, cameraViewModel::getCamera) },
                                            enabled = connected,
                                            shape = CircleShape,
                                            contentPadding = PaddingValues(6.dp)
                                        ) {
                                            Icon(
                                                Icons.Default.Refresh,
                                                contentDescription = stringResource(R.string.retry),
                                                tint = if (connected) colors.accentBlue else colors.onSurfaceVariant,
                                                modifier = Modifier.size(16.dp)
                                            )
                                        }
                                    }
                                }

                                // 最尾：毛玻璃移除按钮——把本卡从队列移除。正在传输的
                                // 不可移除（中途打断会让相机关 Wi-Fi），传完变可移除时淡入。
                                AnimatedVisibility(
                                    visible = task.status != TransferStatus.TRANSFERING,
                                    // 水平展开/收起：出现消失时行内其它内容平滑让位，不硬跳。
                                    enter = fadeIn() + expandHorizontally(expandFrom = Alignment.Start),
                                    exit = fadeOut() + shrinkHorizontally(shrinkTowards = Alignment.Start)
                                ) {
                                    Row {
                                        Spacer(modifier = Modifier.width(10.dp))
                                        GlassButton(
                                            onClick = {
                                                // 等待中的先撤下（置 CANCELLED），动画期间队列不会开始传它。
                                                transferViewModel.withdrawTask(handle)
                                                removingHandles[handle] = Unit
                                            },
                                            shape = CircleShape,
                                            contentPadding = PaddingValues(6.dp)
                                        ) {
                                            // 与右下角"清空队列"同款自绘扫帚——同一动作同一符号。
                                            BroomMark(
                                                modifier = Modifier.size(16.dp),
                                                color = colors.onSurfaceVariant,
                                                contentDescription = stringResource(R.string.cd_remove_from_queue)
                                            )
                                        }
                                    }
                                }
                            }

                            if (task.status == TransferStatus.TRANSFERING) {
                                Spacer(modifier = Modifier.height(10.dp))
                                LinearProgressIndicator(
                                    progress = task.progress,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .height(4.dp)
                                        // 圆角进度条，与卡片圆角语言一致
                                        .clip(RoundedCornerShape(2.dp)),
                                    color = colors.accentBlue,
                                    // 轨道用主题蓝的极淡版而非灰色：与蓝调传输卡同色系，
                                    // "已走/未走"读作同一根条的深浅，而不是两种材质。
                                    trackColor = colors.accentBlue.copy(alpha = 0.18f),
                                )
                            }

                        }
                    }
                    }
                }
            }
        }

        // ---------- 顶部渐变 scrim：与"Z传"页同款，保证状态栏与悬浮控件在内容上可读 ----------
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

        // ---------- 悬浮顶部控件（毛玻璃，浮在内容上，与 "Z传" 页同款）----------
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // 左：返回（毛玻璃按钮，仅返回图标）。顶栏按钮统一 36dp 高。
            GlassButton(onClick = onNavigateBack, modifier = Modifier.height(36.dp)) {
                Icon(
                    Icons.Default.ArrowBack,
                    contentDescription = stringResource(R.string.cd_back),
                    tint = colors.onBackground,
                    modifier = Modifier.size(22.dp)
                )
            }

            // 返回键右侧："Z传"页同款信号按钮（常驻）——传输中最关心信号强弱，断开也一眼可见。
            Spacer(modifier = Modifier.width(8.dp))
            SignalPill(
                rssi = cameraState.wifiRssi,
                connected = cameraState.isConnectedToCamera
            )

            // 右：胶囊（传输中显速度/数量，完成后 done→图标）；队列被清空后随之淡出，
            // 不留一颗没有指代的图标。
            Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
                // 顶层重载需显式限定：嵌套的外层 RowScope 会把无限定调用解析到行内专用重载。
                androidx.compose.animation.AnimatedVisibility(
                    visible = transferState.tasks.isNotEmpty(),
                    enter = fadeIn() + scaleIn(initialScale = 0.6f),
                    exit = fadeOut() + scaleOut(targetScale = 0.6f)
                ) {
                    QueuePill(transferState = transferState, haptics = haptics, onClick = {})
                }
            }
        }

        // ---------- 右下角悬浮控件（毛玻璃）+ 二次确认：清空队列（扫帚，常驻于有可清卡片时），
        // 有可重试任务且空闲时在其上方叠放"重试全部" ----------
        val confirmOpen = (hasClearable && showClearConfirm) ||
                (hasRetryable && showRetryConfirm)
        // 全屏遮罩：确认卡展开时接管"点击外部任意处关闭"，淡入淡出，位于卡片之下、内容之上。
        AnimatedVisibility(
            visible = confirmOpen,
            enter = fadeIn(),
            exit = fadeOut()
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(colors.scrim)
                    .pointerInput(Unit) {
                        detectTapGestures {
                            showClearConfirm = false
                            showRetryConfirm = false
                        }
                    }
                    // 连拖动一起消费：否则手指在遮罩上滑动会穿透，底下列表照样滚。
                    .pointerInput(Unit) { detectDragGestures { change, _ -> change.consume() } }
            )
        }
        Column(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .navigationBarsPadding()
                .padding(end = 20.dp, bottom = 24.dp),
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            // 断开时重试置灰禁用而非消失（配合顶栏红色断连图标，用户能看懂"等重连"）。
            val connected = cameraState.isConnectedToCamera
            AnimatedVisibility(
                visible = hasRetryable,
                enter = fadeIn() + scaleIn(initialScale = 0.6f),
                exit = fadeOut() + scaleOut(targetScale = 0.6f)
            ) {
                ConfirmFab(
                    expanded = showRetryConfirm,
                    icon = {
                        Icon(
                            Icons.Default.Refresh,
                            contentDescription = stringResource(R.string.cd_retry_failed),
                            tint = if (connected) colors.accentBlue else colors.onSurfaceVariant,
                            modifier = Modifier.size(26.dp)
                        )
                    },
                    title = stringResource(R.string.retry_failed_title),
                    confirmText = stringResource(R.string.retry),
                    confirmColor = colors.accentBlue,
                    enabled = connected,
                    onToggle = {
                        showRetryConfirm = !showRetryConfirm
                        showClearConfirm = false   // 两张确认卡互斥
                    },
                    onConfirm = {
                        showRetryConfirm = false
                        transferViewModel.retryFailed(cameraViewModel::getCamera)
                    },
                    onDismiss = { showRetryConfirm = false }
                )
            }
            AnimatedVisibility(
                visible = hasClearable,
                enter = fadeIn() + scaleIn(initialScale = 0.6f),
                exit = fadeOut() + scaleOut(targetScale = 0.6f)
            ) {
                ConfirmFab(
                    expanded = showClearConfirm,
                    icon = {
                        // 自绘斜握扫帚（CleaningServices 官方图标像叉子，弃用）。
                        BroomMark(
                            modifier = Modifier.size(26.dp),
                            color = colors.onBackground,
                            contentDescription = stringResource(R.string.cd_clear_queue)
                        )
                    },
                    title = stringResource(R.string.clear_queue_title),
                    subtitle = stringResource(R.string.clear_queue_subtitle),
                    confirmText = stringResource(R.string.clear),
                    confirmColor = colors.statusError,
                    onToggle = {
                        showClearConfirm = !showClearConfirm
                        showRetryConfirm = false   // 两张确认卡互斥
                    },
                    onConfirm = {
                        showClearConfirm = false
                        // 先把等待中的任务撤下（队列不会再开始它们），
                        // 再给所有非传输中卡片打移除标记——可见卡片集体播放收合动画。
                        transferViewModel.withdrawPending()
                        transferState.tasks.forEach {
                            if (it.status != TransferStatus.TRANSFERING) {
                                removingHandles[it.file.handle] = Unit
                            }
                        }
                        // 兜底：LazyColumn 只组合可见卡片，屏幕外的卡没有条目协程替它做
                        // "动画后移除"。等可见卡片收完（280ms）统一清掉所有已终结任务，
                        // 并回收无主标记——否则同 handle 之后重新入队会误播移除动画。
                        clearScope.launch {
                            delay(320)
                            transferViewModel.removeCleared()
                            val alive = transferViewModel.state.value.tasks
                                .mapTo(HashSet()) { it.file.handle }
                            removingHandles.keys.toList().forEach {
                                if (it !in alive) removingHandles.remove(it)
                            }
                        }
                    },
                    onDismiss = { showClearConfirm = false }
                )
            }
        }
    }
}

/**
 * 右下角悬浮的"图标 FAB + 二次确认"控件（清空/重试全部共用）：毛玻璃圆形按钮，
 * 点击后在其左上方弹出确认卡片（缩放动画以 FAB 所在的右下角为原点，向左上放大），
 * 确认后才真正执行。外边距由调用方的叠放容器统一提供（可能同时叠两颗）。
 */
@Composable
private fun ConfirmFab(
    expanded: Boolean,
    icon: @Composable () -> Unit,
    title: String,
    confirmText: String,
    confirmColor: Color,
    onToggle: () -> Unit,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    subtitle: String? = null,
    enabled: Boolean = true,
    modifier: Modifier = Modifier
) {
    Column(horizontalAlignment = Alignment.End, modifier = modifier) {
        AnimatedVisibility(
            visible = expanded,
            // 以右下角为原点缩放弹出，视觉上从 FAB 位置向左上方展开。
            enter = scaleIn(transformOrigin = TransformOrigin(1f, 1f)) + fadeIn(),
            exit = scaleOut(transformOrigin = TransformOrigin(1f, 1f)) + fadeOut()
        ) {
            ConfirmCard(
                title = title,
                subtitle = subtitle,
                confirmText = confirmText,
                confirmColor = confirmColor,
                onConfirm = onConfirm,
                onDismiss = onDismiss
            )
        }

        Spacer(modifier = Modifier.height(12.dp))

        GlassButton(
            onClick = onToggle,
            enabled = enabled,
            shape = CircleShape,
            contentPadding = PaddingValues(16.dp),
            modifier = Modifier.align(Alignment.End)
        ) {
            icon()
        }
    }
}

@Composable
private fun ConfirmCard(
    title: String,
    confirmText: String,
    confirmColor: Color,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    subtitle: String? = null
) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        // 与设置面板/提示条同一"重毛玻璃"面板语言，深浅主题下观感统一。
        color = AppTheme.colors.glassSurfaceHeavy,
        shadowElevation = 8.dp,
        border = BorderStroke(1.dp, confirmColor.copy(alpha = 0.4f)),
        // 消费卡片区域的点击，避免穿透到背后的全屏遮罩而被误关闭。
        modifier = Modifier
            .widthIn(max = 260.dp)
            .pointerInput(Unit) { detectTapGestures { } }
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold,
                color = AppTheme.colors.onBackground
            )
            if (subtitle != null) {
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = AppTheme.colors.onSurfaceVariant
                )
            }
            Spacer(modifier = Modifier.height(12.dp))
            Row(
                modifier = Modifier.align(Alignment.End),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                TextButton(onClick = onDismiss) {
                    Text(stringResource(R.string.cancel), color = AppTheme.colors.onSurfaceVariant)
                }
                Button(
                    onClick = onConfirm,
                    colors = ButtonDefaults.buttonColors(containerColor = confirmColor),
                    shape = RoundedCornerShape(10.dp)
                ) {
                    Text(confirmText)
                }
            }
        }
    }
}

/**
 * 传输队列行内的小缩略图。命中缓存即显示，未命中即发 GetThumb（传输中请求排到文件
 * 间隙执行，不拖慢传输中的文件）。[retryNudge] 变化时对加载失败的缩略图再补一次
 *（传输结束是自然的补载时机）。
 */
@Composable
private fun QueueThumbnail(
    file: NikonCamera.FileInfo,
    retryNudge: Boolean,
    cameraViewModel: CameraViewModel
) {
    var thumbnail by remember(file.handle) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(file.handle, retryNudge) {
        if (thumbnail == null) {
            thumbnail = cameraViewModel.loadThumbnail(file)
        }
    }
    Box(
        modifier = Modifier
            .size(52.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(AppTheme.colors.thumbPlaceholder),
        contentAlignment = Alignment.Center
    ) {
        val image = thumbnail
        if (image != null) {
            Image(
                bitmap = image,
                contentDescription = null,
                // 黑边已在解码时精确裁除（与列表页同源，见 CameraViewModel.cropLetterbox）。
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
        } else {
            Icon(
                Icons.Default.Image,
                contentDescription = null,
                tint = AppTheme.colors.onSurfaceVariant,
                modifier = Modifier.size(22.dp)
            )
        }
    }
}

/** 队列任务状态图标（等待/传输/完成/失败/取消）。前导或尾部复用。 */
@Composable
private fun TaskStatusIcon(status: TransferStatus, size: Dp = 20.dp) {
    val colors = AppTheme.colors
    Icon(
        imageVector = when (status) {
            TransferStatus.WAITING -> Icons.Default.Schedule
            TransferStatus.TRANSFERING -> Icons.Default.Downloading
            TransferStatus.COMPLETED -> Icons.Default.CheckCircle
            TransferStatus.FAILED -> Icons.Default.Error
            TransferStatus.CANCELLED -> Icons.Default.Cancel
        },
        contentDescription = null,
        tint = when (status) {
            TransferStatus.WAITING -> colors.statusWaiting
            TransferStatus.TRANSFERING -> colors.accentBlue
            TransferStatus.COMPLETED -> colors.statusConnected
            TransferStatus.FAILED -> colors.statusError
            TransferStatus.CANCELLED -> colors.onSurfaceVariant
        },
        modifier = Modifier.size(size)
    )
}

