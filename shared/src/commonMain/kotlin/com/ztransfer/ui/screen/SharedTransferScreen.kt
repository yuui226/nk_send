package com.ztransfer.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
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
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.theme.*
import com.ztransfer.viewmodel.ActiveTransferProgress
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

private const val TRANSFER_CARD_WAVE_CYCLE_MS = 2_600
private const val TRANSFER_CARD_WAVE_SEGMENTS = 12
private const val TRANSFER_CARD_WAVE_SPATIAL_SCALE = 0.55f
private const val TRANSFER_CARD_PROGRESS_ALPHA = 0.14f
private val TRANSFER_CARD_WAVE_AMPLITUDE = 3.dp

/** One product queue body. Platform adapters retain services, text formatting and image I/O. */
@OptIn(ExperimentalFoundationApi::class, kotlin.experimental.ExperimentalObjCRefinement::class)
@kotlin.native.HiddenFromObjC
@Composable
fun SharedTransferScreen(
    transferState: TransferQueueUiState,
    connected: Boolean,
    queueControlActionNonce: Long,
    activeTransferProgress: StateFlow<ActiveTransferProgress?>,
    elapsedRealtimeMs: () -> Long,
    isOriginalTransferred: (TransferTask) -> Boolean,
    actions: TransferQueueUiActions,
    text: TransferQueueUiText,
    thumbnail: @Composable (CameraFileInfo, Boolean, Modifier) -> Unit,
    cardContent: @Composable (TransferTask, Long, Long?, Modifier) -> Unit,
) {
    val colors = AppTheme.colors
    // 清空/重试二次确认的展开状态（提到这层，便于全屏遮罩接管"点击外部关闭"）。
    var showClearConfirm by remember { mutableStateOf(false) }
    var showRetryConfirm by remember { mutableStateOf(false) }
    // 正在播放移除动画的任务：卡片收合完毕后才真正从队列删除。
    // 等待中的任务在标记的同时已被 withdraw（置 CANCELLED），动画期间队列不会开始传它。
    val removingTaskIds = remember { mutableStateMapOf<Long, Unit>() }
    var clearAllInProgress by remember { mutableStateOf(false) }
    val clearScope = rememberCoroutineScope()
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

    // 正在收合退场的任务不再参与按钮状态；特别是 WAITING 被 withdraw 成 CANCELLED 后，
    // 不能在删除前的 280ms 内让“重试全部”闪现。
    val actionVisibility = transferQueueActionVisibility(
        tasks = transferState.tasks,
        isTransferring = transferState.isTransferring,
        removingTaskIds = removingTaskIds.keys,
        suppressAll = clearAllInProgress,
    )
    val hasRetryable = actionVisibility.hasRetryable
    val retryNeedsCamera = transferState.tasks.any {
        it.taskId !in removingTaskIds &&
            (it.status == TransferStatus.FAILED || it.status == TransferStatus.CANCELLED) &&
            !isOriginalTransferred(it)
    }
    // 清空队列只作用于"不在传输中"的任务（正在传的文件会传完，中途打断会让相机关 Wi-Fi）：
    // 有可清的卡片才显示扫帚 FAB；确认后卡片集体收合退场、FAB 随之消失。
    val hasClearable = actionVisibility.hasClearable
    // 共用顶部控制按钮仍沿用本页原行为：操作时收起已展开的清空/重试确认卡。
    LaunchedEffect(queueControlActionNonce) {
        if (queueControlActionNonce > 0L) {
            showClearConfirm = false
            showRetryConfirm = false
        }
    }

    val topInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val bottomInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    // 内容 edge-to-edge（与 "Z传" 页一致，无顶部黑条）：顶部让出状态栏 + 悬浮控件；
    // 底部只需让出重试与清空；开始/暂停已经与顶部状态胶囊组成固定右缘的操作组。
    val fabCount = (if (hasClearable) 1 else 0) + (if (hasRetryable) 1 else 0)
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
                        val progress by activeTransferProgress.collectAsState()
                        progress?.takeIf { it.taskId == taskId }
                    } else {
                        null
                    }
                    val displayedProgress = activeProgress?.fraction ?: task.progress
                    val displayedSpeed = activeProgress?.bytesPerSecond ?: task.speed
                    var generationClockMs by remember(taskId) {
                        mutableLongStateOf(elapsedRealtimeMs())
                    }
                    LaunchedEffect(
                        task.isGeneratingFrame,
                        task.frameGenerationStartedAtElapsedMs,
                    ) {
                        while (
                            task.isGeneratingFrame &&
                            task.frameGenerationStartedAtElapsedMs != null
                        ) {
                            generationClockMs = elapsedRealtimeMs()
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
                    val cardActionsVisible = !removing && !clearAllInProgress
                    // 移除动画：真实高度收合 + 淡出（collapseHeight，与列表页分组收合同款），
                    // 收合完毕才从队列删除，下方卡片随布局逐帧上移，无跳变。
                    val removeProgress = remember(taskId) { Animatable(1f) }
                    LaunchedEffect(removing) {
                        if (removing) {
                            removeProgress.animateTo(0f, tween(280, easing = FastOutSlowInEasing))
                            // 先清标记再删数据：同一照片的其它边框任务不受影响。
                            removingTaskIds.remove(taskId)
                            if (!actions.removeTask(taskId)) {
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
                            .animateItem(
                                fadeInSpec = null,
                                placementSpec = Motion.itemPlacement,
                                fadeOutSpec = null,
                            )
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
                                    thumbnail(task.file, transferState.isTransferring, Modifier.align(Alignment.Center))
                                    TaskStatusBadge(
                                        task = task,
                                        taskId = taskId,
                                        modifier = Modifier.align(Alignment.BottomEnd),
                                    )
                                }

                                Spacer(modifier = Modifier.width(12.dp))

                                Box(modifier = Modifier.weight(1f)) {
                                    cardContent(task, displayedSpeed, displayedFrameGenerationElapsedMs, Modifier.fillMaxWidth())
                                    SharedTransferRetryButton(
                                        contentDescription = text.retry,
                                        visible = cardActionsVisible &&
                                            task.status == TransferStatus.FAILED,
                                        enabled = cardActionsVisible &&
                                            (connected || isOriginalTransferred(task)),
                                        onClick = {
                                            clearScope.launch(start = CoroutineStart.UNDISPATCHED) {
                                                actions.retrySingleTask(taskId)
                                            }
                                        },
                                        modifier = Modifier.align(Alignment.TopEnd),
                                    )
                                }

                                // 最尾：毛玻璃移除按钮——把本卡从队列移除。正在传输的
                                // 不可移除（中途打断会让相机关 Wi-Fi），传完变可移除时淡入。
                                AnimatedVisibility(
                                    visible = cardActionsVisible &&
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
                                                clearScope.launch(start = CoroutineStart.UNDISPATCHED) {
                                                    actions.withdrawTask(taskId)
                                                    removingTaskIds[taskId] = Unit
                                                }
                                            },
                                            enabled = cardActionsVisible,
                                            shape = CircleShape,
                                            contentPadding = PaddingValues(6.dp)
                                        ) {
                                            // 与右下角"清空队列"同款自绘扫帚——同一动作同一符号。
                                            BroomMark(
                                                modifier = Modifier.size(16.dp),
                                                color = colors.onSurfaceVariant,
                                                contentDescription = text.removeFromQueue
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

        // ---------- 右下角悬浮控件：只保留清空与重试，并继续沿用二次确认 ----------
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
            AnimatedVisibility(
                visible = hasRetryable,
                enter = fadeIn() + scaleIn(initialScale = 0.6f),
                exit = fadeOut() + scaleOut(targetScale = 0.6f)
            ) {
                SharedQueueConfirmFab(
                    cancelText = text.cancel,
                    expanded = showRetryConfirm,
                    icon = {
                        Icon(
                            Icons.Default.Refresh,
                            contentDescription = text.retryFailedDescription,
                            tint = if (connected) colors.accentBlue else colors.onSurfaceVariant,
                            modifier = Modifier.size(26.dp)
                        )
                    },
                    title = text.retryFailedTitle,
                    confirmText = text.retry,
                    confirmColor = colors.accentBlue,
                    enabled = hasRetryable && (connected || !retryNeedsCamera),
                    onToggle = {
                        showRetryConfirm = !showRetryConfirm
                        showClearConfirm = false   // 两张确认卡互斥
                    },
                    onConfirm = {
                        showRetryConfirm = false
                        clearScope.launch(start = CoroutineStart.UNDISPATCHED) {
                            actions.retryFailed(removingTaskIds.keys.toSet())
                        }
                    },
                    onDismiss = { showRetryConfirm = false }
                )
            }
            AnimatedVisibility(
                visible = hasClearable,
                enter = fadeIn() + scaleIn(initialScale = 0.6f),
                exit = fadeOut() + scaleOut(targetScale = 0.6f)
            ) {
                SharedQueueConfirmFab(
                    cancelText = text.cancel,
                    expanded = showClearConfirm,
                    icon = {
                        // 自绘斜握扫帚（CleaningServices 官方图标像叉子，弃用）。
                        BroomMark(
                            modifier = Modifier.size(26.dp),
                            color = colors.onBackground,
                            contentDescription = text.clearQueueDescription
                        )
                    },
                    title = text.clearQueueTitle,
                    subtitle = text.clearQueueSubtitle,
                    confirmText = text.clear,
                    confirmColor = colors.statusError,
                    enabled = hasClearable,
                    onToggle = {
                        showClearConfirm = !showClearConfirm
                        showRetryConfirm = false   // 两张确认卡互斥
                    },
                    onConfirm = {
                        showClearConfirm = false
                        clearScope.launch(start = CoroutineStart.UNDISPATCHED) {
                            clearAllInProgress = true
                            try {
                                // 先把等待中的任务撤下（队列不会再开始它们），
                                // 再给所有非传输中卡片打移除标记——可见卡片集体播放收合动画。
                                actions.withdrawPending()
                                transferState.tasks.forEach {
                                    if (it.status != TransferStatus.TRANSFERING && !it.isGeneratingFrame) {
                                        removingTaskIds[it.taskId] = Unit
                                    }
                                }
                                // 兜底：LazyColumn 只组合可见卡片，屏幕外的卡没有条目协程替它做
                                // "动画后移除"。等可见卡片收完（280ms）统一清掉所有已终结任务，
                                // 并回收无主标记——否则同 handle 之后重新入队会误播移除动画。
                                delay(320)
                                actions.removeCleared()
                                val alive = actions.currentTasks()
                                    .mapTo(HashSet()) { it.taskId }
                                removingTaskIds.keys.toList().forEach {
                                    if (it !in alive) removingTaskIds.remove(it)
                                }
                            } finally {
                                clearAllInProgress = false
                            }
                        }
                    },
                    onDismiss = { showClearConfirm = false }
                )
            }
        }
    }
}
