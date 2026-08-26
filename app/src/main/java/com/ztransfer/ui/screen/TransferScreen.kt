package com.ztransfer.ui.screen

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableLongStateOf
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
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.filter.BuiltInPhotoFilters
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.PtpConstants
import com.ztransfer.ui.theme.*
import com.ztransfer.ui.util.formatDuration
import com.ztransfer.ui.util.formatFileSize
import com.ztransfer.ui.util.formatSpeed
import com.ztransfer.ui.util.rememberHaptics
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import com.ztransfer.viewmodel.TransferViewModel
import com.ztransfer.viewmodel.isTransferredOriginal
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private const val TRANSFER_CARD_WAVE_CYCLE_MS = 2_600
private const val TRANSFER_CARD_WAVE_SEGMENTS = 12
private const val TRANSFER_CARD_WAVE_SPATIAL_SCALE = 0.55f
private const val TRANSFER_CARD_PROGRESS_ALPHA = 0.14f
private val TRANSFER_CARD_WAVE_AMPLITUDE = 3.dp

private enum class TransferCardPillTone { SIZE, SPEED, EFFECT, TRANSFER_DURATION, GENERATION_DURATION }

private enum class TransferCardVisualState { WAITING, TRANSFERRING, GENERATING, COMPLETED, FAILED, CANCELLED }

internal enum class QueueExecutionControl { START, PAUSE }

internal fun queueExecutionControl(
    isTransferring: Boolean,
    waitingCount: Int,
): QueueExecutionControl? = when {
    isTransferring -> QueueExecutionControl.PAUSE
    waitingCount > 0 -> QueueExecutionControl.START
    else -> null
}

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
    val removingTaskIds = remember { mutableStateMapOf<Long, Unit>() }
    val clearScope = rememberCoroutineScope()
    // 触感反馈（与"Z传"页同一开关）；本页胶囊负责传输全部完成时的成功震动。
    val haptics = rememberHaptics(transferState.hapticsEnabled)
    val pauseAfterCurrentHint = stringResource(R.string.pause_after_current_hint)
    var pauseHintVisible by remember { mutableStateOf(false) }
    var pauseHintNonce by remember { mutableLongStateOf(0L) }
    LaunchedEffect(pauseHintNonce) {
        if (pauseHintNonce > 0L && pauseHintVisible) {
            delay(2_200)
            pauseHintVisible = false
        }
    }
    // 队列清空后再加入任务时从顶部开始，避免沿用上一批任务的滚动位置与遮罩状态。
    val listState = key(transferState.tasks.isEmpty()) { rememberLazyListState() }
    val listAtTop by remember {
        derivedStateOf {
            listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset < 8
        }
    }
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
    val retryNeedsCamera = transferState.tasks.any {
        (it.status == TransferStatus.FAILED || it.status == TransferStatus.CANCELLED) &&
            !isTransferredOriginal(
                it.file,
                transferState.existingExportIndex,
                it.destinationFolderName,
            )
    }
    // 清空队列只作用于"不在传输中"的任务（正在传的文件会传完，中途打断会让相机关 Wi-Fi）：
    // 有可清的卡片才显示扫帚 FAB；确认后卡片集体收合退场、FAB 随之消失。
    val hasClearable = transferState.tasks.any {
        it.status != TransferStatus.TRANSFERING && !it.isGeneratingFrame
    }
    val waitingCount = transferState.tasks.count { it.status == TransferStatus.WAITING }
    val executionControl = queueExecutionControl(
        isTransferring = transferState.isTransferring,
        waitingCount = waitingCount,
    )
    val waitingNeedsCamera = transferState.tasks.any {
        it.status == TransferStatus.WAITING &&
            !isTransferredOriginal(
                it.file,
                transferState.existingExportIndex,
                it.destinationFolderName,
            )
    }
    // AnimatedVisibility keeps its content during exit. Retain the last real control so hiding a
    // finished pause button cannot briefly swap in a play icon while it fades out.
    var retainedExecutionControl by remember {
        mutableStateOf(executionControl ?: QueueExecutionControl.START)
    }
    LaunchedEffect(executionControl) {
        executionControl?.let { retainedExecutionControl = it }
    }

    val topInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val bottomInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    // 内容 edge-to-edge（与 "Z传" 页一致，无顶部黑条）：顶部让出状态栏 + 悬浮控件；
    // 底部让出导航栏 + 右下角悬浮按钮（重试、开始/暂停、清空）的实际叠放高度。
    val fabCount = (if (hasClearable) 1 else 0) +
        (if (hasRetryable) 1 else 0) +
        (if (executionControl != null) 1 else 0)
    val listPadding = PaddingValues(
        start = 12.dp,
        end = 12.dp,
        top = topInset + 58.dp,
        bottom = bottomInset + when {
            fabCount >= 3 -> 240.dp
            fabCount == 2 -> 168.dp
            fabCount == 1 -> 96.dp
            else -> 12.dp
        }
    )

    // 根需不透明底色：与"Z传"页左右滑动转场期间两页同屏层叠，透明根会让底层页面透出。
    // 与 Scaffold 共用全局背景刷（浅色纯色/深色微渐变）。
    Box(modifier = Modifier.fillMaxSize().background(rememberAppBackgroundBrush())) {
        // ---------- 内容（铺满，延伸到系统栏后面）----------
        if (transferState.tasks.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    // 空状态只保留品牌双 Z 的低对比度剪影。透明度与尺寸做极轻的慢呼吸，
                    // 文案保持稳定，避免整个空状态像加载中一样闪烁。
                    val breathe = rememberInfiniteTransition(label = "emptyQueue")
                    val breatheAlpha by breathe.animateFloat(
                        initialValue = 0.42f,
                        targetValue = 0.54f,
                        animationSpec = infiniteRepeatable(
                            tween(2400, easing = FastOutSlowInEasing),
                            RepeatMode.Reverse
                        ),
                        label = "emptyQueueAlpha"
                    )
                    val breatheScale by breathe.animateFloat(
                        initialValue = 0.985f,
                        targetValue = 1.015f,
                        animationSpec = infiniteRepeatable(
                            tween(2400, easing = FastOutSlowInEasing),
                            RepeatMode.Reverse
                        ),
                        label = "emptyQueueScale"
                    )
                    ZMark(
                        modifier = Modifier
                            .height(58.dp)
                            .graphicsLayer {
                                alpha = breatheAlpha
                                scaleX = breatheScale
                                scaleY = breatheScale
                        },
                        color = colors.onSurfaceVariant
                    )
                }
            }
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = listPadding
                // 行距烘焙在条目底部（8dp），随移除收合动画一起消失；
                // 用 spacedBy 的话卡片收合到 0 后仍残留间距，真正删除瞬间会跳一下。
            ) {
                // 倒序显示：最新加入队列的排在最上方（asReversed 是视图，不复制列表）。
                items(transferState.tasks.asReversed(), key = { it.taskId }) { task ->
                    val taskId = task.taskId
                    // 只有唯一的活动任务卡订阅高频进度；其它卡片和整个页面不随 200ms
                    // 回调重组。任务进入终态后改读低频列表中的最终快照。
                    val activeProgress = if (task.status == TransferStatus.TRANSFERING) {
                        val progress by transferViewModel.activeTransferProgress.collectAsState()
                        progress?.takeIf { it.taskId == taskId }
                    } else {
                        null
                    }
                    val displayedProgress = activeProgress?.fraction ?: task.progress
                    val displayedSpeed = activeProgress?.bytesPerSecond ?: task.speed
                    var generationClockMs by remember(taskId) {
                        mutableLongStateOf(android.os.SystemClock.elapsedRealtime())
                    }
                    LaunchedEffect(
                        task.isGeneratingFrame,
                        task.frameGenerationStartedAtElapsedMs,
                    ) {
                        while (
                            task.isGeneratingFrame &&
                            task.frameGenerationStartedAtElapsedMs != null
                        ) {
                            generationClockMs = android.os.SystemClock.elapsedRealtime()
                            delay(200L)
                        }
                    }
                    val displayedFrameGenerationElapsedMs = if (task.isGeneratingFrame) {
                        task.frameGenerationStartedAtElapsedMs?.let { startedAt ->
                            (generationClockMs - startedAt).coerceAtLeast(0L)
                        }
                    } else {
                        task.frameGenerationElapsedMs
                    }
                    val removing = removingTaskIds.containsKey(taskId)
                    // 移除动画：真实高度收合 + 淡出（collapseHeight，与列表页分组收合同款），
                    // 收合完毕才从队列删除，下方卡片随布局逐帧上移，无跳变。
                    val removeProgress = remember(taskId) { Animatable(1f) }
                    LaunchedEffect(removing) {
                        if (removing) {
                            removeProgress.animateTo(0f, tween(280, easing = FastOutSlowInEasing))
                            // 先清标记再删数据：同一照片的其它边框任务不受影响。
                            removingTaskIds.remove(taskId)
                            if (!transferViewModel.removeTask(taskId)) {
                                // 竞态兜底：动画期间任务已开始传输/被重试回等待，不可移除——
                                // 卡片弹回原高继续显示（成功移除时本条目已随删除离场，走不到这）。
                                removeProgress.animateTo(1f, tween(200, easing = FastOutSlowInEasing))
                            }
                        }
                    }
                    // 动画中途条目被外因移出组合（如同时点了重试）：清掉标记，
                    // 该任务保留在队列里（安全侧），用户可再操作。
                    DisposableEffect(taskId) {
                        onDispose { removingTaskIds.remove(taskId) }
                    }
                    val cardContainerColor by animateColorAsState(
                        targetValue = lerp(
                            colors.surface,
                            transferCardStateColor(task, colors),
                            0.055f,
                        ),
                        animationSpec = tween(240, easing = FastOutSlowInEasing),
                        label = "transferCardStateColor",
                    )
                    val cardBorderColor by animateColorAsState(
                        targetValue = lerp(
                            colors.cardHairline,
                            transferCardStateColor(task, colors),
                            0.15f,
                        ),
                        animationSpec = tween(240, easing = FastOutSlowInEasing),
                        label = "transferCardStateBorderColor",
                    )
                    Box(
                        modifier = Modifier
                            // 上方卡片增删/长矮时，本卡平滑让位而不是硬跳。
                            .animateItemPlacement(Motion.itemPlacement)
                            .collapseHeight { removeProgress.value }
                            .padding(bottom = 8.dp)
                    ) {
                    Card(
                        modifier = Modifier
                            .fillMaxWidth()
                            .then(
                                if (task.status == TransferStatus.TRANSFERING) {
                                    Modifier.semantics {
                                        progressBarRangeInfo = ProgressBarRangeInfo(
                                            current = normalizedTransferProgress(displayedProgress),
                                            range = 0f..1f,
                                        )
                                    }
                                } else {
                                    Modifier
                                },
                            ),
                        // 14dp 与列表页卡片/监看页 tile 的中型控件圆角一致（原 12dp 家族外）。
                        shape = RoundedCornerShape(14.dp),
                        // 浅色下白卡浮在浅灰背景上需要发丝线定界；深色 token 为透明，视觉不变。
                        border = BorderStroke(1.dp, cardBorderColor),
                        colors = CardDefaults.cardColors(
                            containerColor = cardContainerColor,
                        )
                    ) {
                        Box(modifier = Modifier.fillMaxWidth()) {
                            androidx.compose.animation.AnimatedVisibility(
                                visible = task.status == TransferStatus.TRANSFERING,
                                enter = fadeIn(tween(180)),
                                exit = if (task.status == TransferStatus.COMPLETED) {
                                    // 先给平滑进度一点补满时间，再让蓝色液面退入绿色完成底。
                                    fadeOut(tween(durationMillis = 220, delayMillis = 100))
                                } else {
                                    fadeOut(tween(180))
                                },
                                modifier = Modifier.matchParentSize(),
                            ) {
                                // 完成时顺滑补满再淡入绿色底；失败/取消只淡出当前进度，
                                // 不把未完成任务错误表达成 100%。
                                val animatedProgress = rememberSmoothTransferProgress(
                                    targetProgress = transferCardProgressTarget(
                                        status = task.status,
                                        progress = displayedProgress,
                                    ),
                                    resetKey = taskId,
                                )
                                LiquidProgressFill(
                                    progress = { animatedProgress.value },
                                    waveEligible = transferCardWaveEligible(task.status),
                                    seedKey = taskId,
                                    color = colors.accentBlue.copy(
                                        alpha = TRANSFER_CARD_PROGRESS_ALPHA,
                                    ),
                                    modifier = Modifier.fillMaxSize(),
                                    amplitude = TRANSFER_CARD_WAVE_AMPLITUDE,
                                    cycleMillis = TRANSFER_CARD_WAVE_CYCLE_MS,
                                    segments = TRANSFER_CARD_WAVE_SEGMENTS,
                                    spatialScale = TRANSFER_CARD_WAVE_SPATIAL_SCALE,
                                    label = "transferCardWave",
                                )
                            }

                        // 信息胶囊出现可能改变高度，继续柔和过渡；顶部 sheen 位于进度层之上，
                        // 让液态填充仍属于卡片材质，而不是覆盖内容的色块。
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
                                // 缩略图：屏幕内的卡片始终允许取图（传输中请求排到
                                // 文件间隙执行），isTransferring 仅作传输结束后的补载重试键。
                                Box(modifier = Modifier.size(56.dp)) {
                                    QueueThumbnail(
                                        file = task.file,
                                        retryNudge = transferState.isTransferring,
                                        cameraViewModel = cameraViewModel,
                                        modifier = Modifier.align(Alignment.Center),
                                    )
                                    TaskStatusBadge(
                                        task = task,
                                        taskId = taskId,
                                        modifier = Modifier.align(Alignment.BottomEnd),
                                    )
                                }

                                Spacer(modifier = Modifier.width(12.dp))

                                Box(modifier = Modifier.weight(1f)) {
                                    TransferTaskCardContent(
                                        task = task,
                                        displayedSpeed = displayedSpeed,
                                        displayedFrameGenerationElapsedMs = displayedFrameGenerationElapsedMs,
                                        modifier = Modifier.fillMaxWidth(),
                                    )
                                    TransferRetryButton(
                                        visible = task.status == TransferStatus.FAILED,
                                        enabled = cameraState.isConnectedToCamera || isTransferredOriginal(
                                            task.file,
                                            transferState.existingExportIndex,
                                            task.destinationFolderName,
                                        ),
                                        onClick = {
                                            transferViewModel.retrySingleTask(
                                                taskId,
                                                cameraViewModel::getCamera,
                                            )
                                        },
                                        modifier = Modifier.align(Alignment.TopEnd),
                                    )
                                }

                                // 最尾：毛玻璃移除按钮——把本卡从队列移除。正在传输的
                                // 不可移除（中途打断会让相机关 Wi-Fi），传完变可移除时淡入。
                                AnimatedVisibility(
                                    visible =
                                        task.status != TransferStatus.TRANSFERING &&
                                            !task.isGeneratingFrame,
                                    // 水平展开/收起：出现消失时行内其它内容平滑让位，不硬跳。
                                    enter = fadeIn() + expandHorizontally(expandFrom = Alignment.Start),
                                    exit = fadeOut() + shrinkHorizontally(shrinkTowards = Alignment.Start)
                                ) {
                                    Row {
                                        Spacer(modifier = Modifier.width(10.dp))
                                        GlassButton(
                                            onClick = {
                                                // 等待中的先撤下（置 CANCELLED），动画期间队列不会开始传它。
                                                transferViewModel.withdrawTask(taskId)
                                                removingTaskIds[taskId] = Unit
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

                        }
                        }
                    }
                    }
                }
            }
        }

        // ---------- 顶部渐变 scrim：与"Z传"页同款，保证状态栏与悬浮控件在内容上可读 ----------
        if (!listAtTop && transferState.tasks.isNotEmpty()) {
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
                connected = cameraState.isConnectedToCamera,
                connectionType = cameraState.connectionType,
                staMode = cameraState.isStaConnection,
                onStaDisconnectedClick = cameraViewModel::retryStaConnection,
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
                    QueuePill(
                        transferState = transferState,
                        activeProgressFlow = transferViewModel.activeTransferProgress,
                        haptics = haptics,
                        onClick = {},
                    )
                }
            }
        }

        // ---------- 右下角悬浮控件（毛玻璃）：从下到上依次为清空、开始/暂停、重试；
        // 清空与重试沿用二次确认，开始/暂停直接响应 ----------
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
                    enabled = connected || !retryNeedsCamera,
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
                visible = executionControl != null,
                enter = fadeIn(tween(180)) + scaleIn(
                    initialScale = 0.72f,
                    animationSpec = Motion.bouncy(),
                ),
                exit = fadeOut(tween(140)) + scaleOut(
                    targetScale = 0.72f,
                    animationSpec = tween(160),
                ),
            ) {
                QueueExecutionFab(
                    control = retainedExecutionControl,
                    pauseRequested = transferState.pauseAfterCurrent,
                    startEnabled = connected || !waitingNeedsCamera,
                    onStart = {
                        showRetryConfirm = false
                        showClearConfirm = false
                        haptics.tick()
                        transferViewModel.startPendingTransfers(cameraViewModel::getCamera)
                    },
                    onPause = {
                        if (transferState.isTransferring && !transferState.pauseAfterCurrent) {
                            showRetryConfirm = false
                            showClearConfirm = false
                            haptics.tick()
                            transferViewModel.requestPauseAfterCurrent()
                            pauseHintVisible = true
                            pauseHintNonce++
                        }
                    },
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
                            if (it.status != TransferStatus.TRANSFERING && !it.isGeneratingFrame) {
                                removingTaskIds[it.taskId] = Unit
                            }
                        }
                        // 兜底：LazyColumn 只组合可见卡片，屏幕外的卡没有条目协程替它做
                        // "动画后移除"。等可见卡片收完（280ms）统一清掉所有已终结任务，
                        // 并回收无主标记——否则同 handle 之后重新入队会误播移除动画。
                        clearScope.launch {
                            delay(320)
                            transferViewModel.removeCleared()
                            val alive = transferViewModel.state.value.tasks
                                .mapTo(HashSet()) { it.taskId }
                            removingTaskIds.keys.toList().forEach {
                                if (it !in alive) removingTaskIds.remove(it)
                            }
                        }
                    },
                    onDismiss = { showClearConfirm = false }
                )
            }
        }

        // 暂停不会打断 PTP 对象传输；点击后用底部轻提示明确这一点，避免用户误以为失效。
        AnimatedVisibility(
            visible = pauseHintVisible,
            enter = fadeIn() + slideInVertically { it / 2 },
            exit = fadeOut() + slideOutVertically { it / 2 },
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 28.dp),
        ) {
            Surface(
                modifier = Modifier.widthIn(max = 340.dp),
                shape = RoundedCornerShape(22.dp),
                color = colors.glassSurfaceHeavy,
                shadowElevation = 6.dp,
                border = BorderStroke(1.dp, colors.glassPanelBorder),
            ) {
                Text(
                    text = pauseAfterCurrentHint,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
                    textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.labelLarge,
                    color = colors.onBackground,
                )
            }
        }
    }
}

@Composable
private fun QueueExecutionFab(
    control: QueueExecutionControl,
    pauseRequested: Boolean,
    startEnabled: Boolean,
    onStart: () -> Unit,
    onPause: () -> Unit,
) {
    val colors = AppTheme.colors
    val accent by animateColorAsState(
        targetValue = if (control == QueueExecutionControl.START) {
            colors.accentBlue
        } else {
            colors.accentYellow
        },
        animationSpec = tween(180),
        label = "queueControlAccent",
    )
    GlassButton(
        onClick = if (control == QueueExecutionControl.START) onStart else onPause,
        enabled = control == QueueExecutionControl.PAUSE || startEnabled,
        shape = CircleShape,
        contentPadding = PaddingValues(15.dp),
        // 与相邻 FAB 固定为同一 58dp 外径；图标切换时按钮轮廓不会跟着缩放 2dp。
        modifier = Modifier.size(58.dp),
        active = control == QueueExecutionControl.START || pauseRequested,
        activeColor = accent,
        activeOutline = true,
        materialContentColor = accent,
    ) {
        AnimatedContent(
            targetState = control,
            transitionSpec = {
                (fadeIn(tween(170, delayMillis = 45)) +
                    scaleIn(initialScale = 0.72f, animationSpec = tween(190, delayMillis = 35)))
                    .togetherWith(
                        fadeOut(tween(110)) +
                            scaleOut(targetScale = 0.72f, animationSpec = tween(130))
                    )
            },
            contentAlignment = Alignment.Center,
            label = "queueControlIcon",
        ) { current ->
            Icon(
                imageVector = if (current == QueueExecutionControl.START) {
                    Icons.Default.PlayArrow
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
                tint = accent,
                modifier = Modifier.size(
                    if (current == QueueExecutionControl.START) 28.dp else 26.dp
                ),
            )
        }
    }
}

private fun transferCardVisualState(task: TransferTask): TransferCardVisualState = when {
    task.isGeneratingFrame -> TransferCardVisualState.GENERATING
    task.status == TransferStatus.WAITING -> TransferCardVisualState.WAITING
    task.status == TransferStatus.TRANSFERING -> TransferCardVisualState.TRANSFERRING
    task.status == TransferStatus.COMPLETED -> TransferCardVisualState.COMPLETED
    task.status == TransferStatus.FAILED -> TransferCardVisualState.FAILED
    else -> TransferCardVisualState.CANCELLED
}

@Composable
private fun TransferRetryButton(
    visible: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    AnimatedVisibility(
        visible = visible,
        enter = fadeIn() + scaleIn(
            initialScale = 0.75f,
            transformOrigin = TransformOrigin(1f, 0f),
        ),
        exit = fadeOut() + scaleOut(
            targetScale = 0.75f,
            transformOrigin = TransformOrigin(1f, 0f),
        ),
        modifier = modifier,
    ) {
        GlassButton(
            onClick = onClick,
            enabled = enabled,
            shape = CircleShape,
            contentPadding = PaddingValues(6.dp),
        ) {
            Icon(
                Icons.Default.Refresh,
                contentDescription = stringResource(R.string.retry),
                tint = AppTheme.colors.accentBlue,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

private fun transferCardStateColor(task: TransferTask, colors: AppColors): Color = when (
    transferCardVisualState(task)
) {
    TransferCardVisualState.WAITING -> colors.accentYellow
    TransferCardVisualState.TRANSFERRING -> colors.accentBlue
    TransferCardVisualState.GENERATING -> colors.accentPurple
    TransferCardVisualState.COMPLETED -> colors.statusConnected
    TransferCardVisualState.FAILED -> colors.statusError
    TransferCardVisualState.CANCELLED -> colors.onSurfaceVariant
}

@Composable
private fun TaskStatusBadge(
    task: TransferTask,
    taskId: Long,
    modifier: Modifier = Modifier,
) {
    val colors = AppTheme.colors
    val visualState = transferCardVisualState(task)
    val badgeColor = transferCardStateColor(task, colors)
    val iconPop = remember(taskId) { Animatable(1f) }
    var previousState by remember(taskId) { mutableStateOf(visualState) }
    LaunchedEffect(visualState) {
        val was = previousState
        previousState = visualState
        if (was != visualState) {
            iconPop.snapTo(0.62f)
            iconPop.animateTo(1f, Motion.bouncy())
        }
    }
    Surface(
        modifier = modifier.graphicsLayer {
            scaleX = iconPop.value
            scaleY = iconPop.value
        },
        shape = CircleShape,
        color = badgeColor,
        border = BorderStroke(2.dp, colors.surface),
    ) {
        Box(
            modifier = Modifier.size(22.dp),
            contentAlignment = Alignment.Center,
        ) {
            Crossfade(
                targetState = visualState,
                animationSpec = tween(180),
                label = "taskStatusBadge",
            ) { state ->
                Icon(
                    imageVector = when (state) {
                        TransferCardVisualState.WAITING -> Icons.Default.Schedule
                        TransferCardVisualState.TRANSFERRING -> Icons.Default.Downloading
                        TransferCardVisualState.GENERATING -> Icons.Default.AutoAwesome
                        TransferCardVisualState.COMPLETED -> Icons.Default.Check
                        TransferCardVisualState.FAILED -> Icons.Default.PriorityHigh
                        TransferCardVisualState.CANCELLED -> Icons.Default.Close
                    },
                    contentDescription = null,
                    tint = colors.onAccent,
                    modifier = Modifier.size(13.dp),
                )
            }
        }
    }
}
@Composable
private fun TransferTaskCardContent(
    task: TransferTask,
    displayedSpeed: Long,
    displayedFrameGenerationElapsedMs: Long?,
    modifier: Modifier = Modifier,
) {
    val colors = AppTheme.colors
    val isFailed = task.status == TransferStatus.FAILED
    val transferred = task.status == TransferStatus.COMPLETED
    val speedText = when {
        task.status == TransferStatus.TRANSFERING && displayedSpeed > 0L -> formatSpeed(displayedSpeed)
        transferred && task.downloadMBps > 0f -> "%.1f MB/s".format(task.downloadMBps)
        else -> null
    }
    val transferDuration = task.elapsedMs?.let(::formatDuration)
    val generationDuration = displayedFrameGenerationElapsedMs?.let(::formatDuration)
    val effectText = transferTaskEffectText(task)
    val animateTransferPills = task.status == TransferStatus.TRANSFERING
    val animateGenerationPills = task.isGeneratingFrame

    Column(modifier = modifier) {
        Text(
            text = task.file.fileName,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.Medium,
            color = if (task.status == TransferStatus.CANCELLED) {
                colors.onSurfaceVariant
            } else {
                colors.onBackground
            },
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = if (isFailed) Modifier.padding(end = 42.dp) else Modifier,
        )

        Spacer(modifier = Modifier.height(6.dp))
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            TransferInfoPill(
                text = transferTaskFileSizeText(task),
                tone = TransferCardPillTone.SIZE,
                respond = animateTransferPills && speedText != null,
            )
            TransferPillVisibility(
                visible = speedText != null,
                delayMillis = 60,
            ) {
                speedText?.let {
                    TransferInfoPill(
                        text = it,
                        tone = TransferCardPillTone.SPEED,
                        respond = transferDuration != null,
                    )
                }
            }
            TransferPillVisibility(
                visible = transferDuration != null,
                delayMillis = 150,
            ) {
                transferDuration?.let {
                    TransferInfoPill(text = it, tone = TransferCardPillTone.TRANSFER_DURATION)
                }
            }
        }

        if (isFailed) {
            Spacer(modifier = Modifier.height(7.dp))
            Text(
                text = task.error ?: stringResource(R.string.transfer_failed),
                style = MaterialTheme.typography.labelMedium,
                color = colors.statusError,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        } else if (effectText != null) {
            Spacer(modifier = Modifier.height(7.dp))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                TransferInfoPill(
                    text = effectText,
                    tone = TransferCardPillTone.EFFECT,
                    respond = animateGenerationPills && generationDuration != null,
                    modifier = Modifier.weight(1f, fill = false),
                )
                TransferPillVisibility(
                    visible = generationDuration != null,
                    delayMillis = 80,
                ) {
                    generationDuration?.let {
                        TransferInfoPill(text = it, tone = TransferCardPillTone.GENERATION_DURATION)
                    }
                }
            }
        }
    }
}

@Composable
private fun TransferPillVisibility(
    visible: Boolean,
    delayMillis: Int,
    content: @Composable () -> Unit,
) {
    // 初次组合时直接采用真实状态；只有当前卡片留在组合内发生 false → true，才播放
    // “从左侧胶囊分裂”动画。LazyColumn 滚出再滚回不会重播，速度数值更新也不会触发。
    val visibilityState = remember {
        MutableTransitionState(visible).apply { targetState = visible }
    }
    LaunchedEffect(visible) {
        visibilityState.targetState = visible
    }
    AnimatedVisibility(
        visibleState = visibilityState,
        enter = transferCardPillEnter(delayMillis),
        exit = fadeOut(tween(100)) + shrinkHorizontally(shrinkTowards = Alignment.Start),
    ) { content() }
}

private fun transferCardPillEnter(delayMillis: Int) =
    fadeIn(tween(200, delayMillis = delayMillis)) +
        expandHorizontally(
            expandFrom = Alignment.Start,
            animationSpec = Motion.bouncy(),
        ) +
        slideInHorizontally(
            initialOffsetX = { -minOf(it, 8) },
            animationSpec = spring(
                dampingRatio = 0.62f,
                stiffness = 360f,
            ),
        ) +
        scaleIn(
            initialScale = 0.78f,
            transformOrigin = TransformOrigin(0f, 0.5f),
            animationSpec = tween(200, delayMillis = delayMillis),
        )

@Composable
private fun TransferInfoPill(
    text: String,
    tone: TransferCardPillTone,
    modifier: Modifier = Modifier,
    respond: Boolean = false,
) {
    val colors = AppTheme.colors
    val accent = when (tone) {
        TransferCardPillTone.SIZE -> colors.onSurfaceVariant
        TransferCardPillTone.SPEED -> colors.statusConnected
        TransferCardPillTone.EFFECT -> colors.accentPurple
        TransferCardPillTone.TRANSFER_DURATION -> colors.accentBlue
        TransferCardPillTone.GENERATION_DURATION -> colors.accentYellow
    }
    val sourceScale = remember { Animatable(1f) }
    var previouslyResponding by remember { mutableStateOf(respond) }
    LaunchedEffect(respond) {
        val shouldRespond = respond && !previouslyResponding
        previouslyResponding = respond
        if (shouldRespond) {
            sourceScale.snapTo(1f)
            sourceScale.animateTo(0.94f, tween(105, easing = FastOutSlowInEasing))
            sourceScale.animateTo(1f, Motion.bouncy())
        }
    }
    Box(
        modifier = modifier
            // 左侧为分裂锚点；仅改变 X 缩放，左边界始终固定，回弹发生在右缘。
            .graphicsLayer {
                transformOrigin = TransformOrigin(0f, 0.5f)
                scaleX = sourceScale.value
            }
            .clip(RoundedCornerShape(999.dp))
            .background(accent.copy(alpha = 0.10f))
            .border(1.dp, accent.copy(alpha = 0.22f), RoundedCornerShape(999.dp))
            .padding(horizontal = 7.dp, vertical = 3.dp),
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.labelSmall,
            color = accent,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun transferTaskEffectText(task: TransferTask): String? {
    val frameName = task.framePreset
        ?.takeIf { task.frameBorderRequested }
        ?.let { photoFramePresetLabel(it) }
    val filterName = task.photoFilterRequested?.let {
        "${photoFilterDisplayName(it.preset)} ${it.normalizedIntensityPercent}%"
    }
    val parts = listOfNotNull(frameName, filterName)
    return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}

private fun transferTaskFileSizeText(task: TransferTask): String = when {
    task.file.size != PtpConstants.SIZE_UNKNOWN -> formatFileSize(task.file.size)
    task.downloaded > 0L -> formatFileSize(task.downloaded)
    else -> "—"
}

@Composable
private fun photoFramePresetLabel(preset: PhotoFramePreset): String = stringResource(
    when (preset) {
        PhotoFramePreset.MIST -> R.string.photo_frame_mist
        PhotoFramePreset.CINEMA -> R.string.photo_frame_cinema
        PhotoFramePreset.MINIMAL -> R.string.photo_frame_minimal
        PhotoFramePreset.FROSTED -> R.string.photo_frame_frosted
        PhotoFramePreset.PLAQUE -> R.string.photo_frame_plaque
        PhotoFramePreset.IMMERSIVE -> R.string.photo_frame_immersive
        PhotoFramePreset.BRAND_INSET -> R.string.photo_frame_brand_inset
        PhotoFramePreset.BRAND_GALLERY -> R.string.photo_frame_brand_gallery
        PhotoFramePreset.CLASSIC_SIGNATURE -> R.string.photo_frame_classic_signature
        PhotoFramePreset.GALLERY_MAT -> R.string.photo_frame_gallery_mat
        PhotoFramePreset.COLOR_ARCHIVE -> R.string.photo_frame_color_archive
        PhotoFramePreset.FILM_GALLERY -> R.string.photo_frame_film_gallery
        PhotoFramePreset.FILM_EDGE -> R.string.photo_frame_film_edge
    }
)

@Composable
private fun photoFilterDisplayName(filter: PhotoFilterPreset): String =
    BuiltInPhotoFilters.nameResId(filter.id)?.let { stringResource(it) } ?: filter.name

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
    cameraViewModel: CameraViewModel,
    modifier: Modifier = Modifier,
) {
    var thumbnail by remember(file.handle) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(file.handle, retryNudge) {
        if (thumbnail == null) {
            thumbnail = cameraViewModel.loadThumbnail(file)
        }
    }
    Box(
        modifier = modifier
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

