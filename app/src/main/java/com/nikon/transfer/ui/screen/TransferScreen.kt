package com.nikon.transfer.ui.screen

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.nikon.transfer.protocol.PtpConstants
import com.nikon.transfer.ui.theme.*
import com.nikon.transfer.ui.util.formatFileSize
import com.nikon.transfer.ui.util.formatSpeed
import com.nikon.transfer.ui.util.rememberHaptics
import com.nikon.transfer.viewmodel.CameraViewModel
import com.nikon.transfer.viewmodel.TransferStatus
import com.nikon.transfer.viewmodel.TransferViewModel

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
    // 停止/重试二次确认的展开状态（提到这层，便于全屏遮罩接管"点击外部关闭"）。
    var showStopConfirm by remember { mutableStateOf(false) }
    var showRetryConfirm by remember { mutableStateOf(false) }
    // 触感反馈（与"Z传"页同一开关）；本页胶囊负责传输全部完成时的成功震动。
    val haptics = rememberHaptics(transferState.hapticsEnabled)

    // 存在可重试任务（失败/取消）且未在传输：右下角显示"重试全部"FAB（与停止同位同规格）。
    val hasRetryable = !transferState.isTransferring && transferState.tasks.any {
        it.status == TransferStatus.FAILED || it.status == TransferStatus.CANCELLED
    }

    val topInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val bottomInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    // 内容 edge-to-edge（与 "Z传" 页一致，无顶部黑条）：顶部让出状态栏 + 悬浮控件；
    // 底部让出导航栏 + 右下角悬浮按钮（停止/重试）的高度。
    val listPadding = PaddingValues(
        start = 12.dp,
        end = 12.dp,
        top = topInset + 58.dp,
        bottom = bottomInset + (if (transferState.isTransferring || hasRetryable) 96.dp else 12.dp)
    )

    // 根需不透明底色：与"Z传"页左右滑动转场期间两页同屏层叠，透明根会让底层页面透出。
    Box(modifier = Modifier.fillMaxSize().background(DarkBackground)) {
        // ---------- 内容（铺满，延伸到系统栏后面）----------
        if (transferState.tasks.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Default.CloudDownload, contentDescription = null, modifier = Modifier.size(64.dp), tint = DarkOnSurfaceVariant)
                    Spacer(modifier = Modifier.height(16.dp))
                    Text("暂无传输任务", color = DarkOnSurfaceVariant)
                }
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = listPadding,
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                // 倒序显示：最新加入队列的排在最上方（asReversed 是视图，不复制列表）。
                items(transferState.tasks.asReversed(), key = { it.file.handle }) { task ->
                    Card(
                        // 上方卡片因状态变化长高/缩矮时，本卡平滑让位而不是硬跳。
                        modifier = Modifier
                            .fillMaxWidth()
                            .animateItemPlacement(Motion.itemPlacement),
                        shape = RoundedCornerShape(12.dp),
                        colors = CardDefaults.cardColors(
                            containerColor = when (task.status) {
                                TransferStatus.TRANSFERING -> AccentBlue.copy(alpha = 0.1f)
                                TransferStatus.COMPLETED -> StatusConnected.copy(alpha = 0.1f)
                                TransferStatus.FAILED -> StatusError.copy(alpha = 0.1f)
                                TransferStatus.CANCELLED -> DarkSurfaceVariant
                                TransferStatus.WAITING -> DarkSurface
                            }
                        )
                    ) {
                        // 进度条/重试按钮随状态出现消失时，卡片高度平滑过渡，
                        // 卡内图标与文字不再瞬移。
                        Column(
                            modifier = Modifier
                                .animateContentSize(tween(250, easing = FastOutSlowInEasing))
                                .padding(12.dp)
                        ) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                // 前导缩略图。allowFetch=!isTransferring：传输中只读缓存，不发 GetThumb 抢带宽。
                                QueueThumbnail(
                                    handle = task.file.handle,
                                    allowFetch = !transferState.isTransferring,
                                    cameraViewModel = cameraViewModel
                                )

                                Spacer(modifier = Modifier.width(12.dp))

                                // 中部两行：文件名 + 状态副信息，撑满前导高度，充分利用竖向空间。
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = task.file.fileName,
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontWeight = FontWeight.Medium,
                                        color = if (task.status == TransferStatus.CANCELLED) DarkOnSurfaceVariant else DarkOnBackground,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    Spacer(modifier = Modifier.height(3.dp))
                                    val (subText, subColor) = when (task.status) {
                                        TransferStatus.WAITING -> "等待" to DarkOnSurfaceVariant
                                        TransferStatus.TRANSFERING -> {
                                            // >4GB 对象的 file.size 只是 SIZE_UNKNOWN 哨兵，别显示假总量。
                                            val base = if (task.file.size == PtpConstants.SIZE_UNKNOWN) {
                                                formatFileSize(task.downloaded)
                                            } else {
                                                "${formatFileSize(task.downloaded)} / ${formatFileSize(task.file.size)}"
                                            }
                                            (if (task.speed > 0) "$base · ${formatSpeed(task.speed)}" else base) to AccentBlue
                                        }
                                        TransferStatus.COMPLETED ->
                                            (when {
                                                task.skipped -> "跳过"
                                                // 单文件下载速度：一眼看出当前网络快慢。大小取真实落盘字节数
                                                //（>4GB 对象的 file.size 只是哨兵值）。
                                                task.downloadMBps > 0f -> "${formatFileSize(task.downloaded)} · %.1f MB/s".format(task.downloadMBps)
                                                else -> formatFileSize(task.downloaded)
                                            }) to StatusConnected
                                        TransferStatus.FAILED -> (task.error ?: "传输失败") to StatusError
                                        TransferStatus.CANCELLED -> "已取消" to DarkOnSurfaceVariant
                                    }
                                    Text(
                                        text = subText,
                                        style = MaterialTheme.typography.labelMedium,
                                        color = subColor,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                }

                                // 尾部：状态图标（前导已被缩略图占用），换状态时交叉淡化不硬切。
                                Spacer(modifier = Modifier.width(10.dp))
                                Crossfade(targetState = task.status, animationSpec = tween(220), label = "taskIcon") { st ->
                                    TaskStatusIcon(st, size = 22.dp)
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
                                    color = AccentBlue,
                                    trackColor = DarkSurfaceVariant,
                                )
                            }

                            if (task.status == TransferStatus.FAILED) {
                                Spacer(modifier = Modifier.height(10.dp))
                                // 单个重试（毛玻璃小胶囊，与日期胶囊同规格）；断开时置灰而非消失。
                                val connected = cameraState.isConnectedToCamera
                                GlassButton(
                                    onClick = { transferViewModel.retrySingleTask(task.file.handle, cameraViewModel::getCamera) },
                                    enabled = connected,
                                    shape = RoundedCornerShape(14.dp),
                                    contentPadding = PaddingValues(horizontal = 12.dp),
                                    modifier = Modifier.height(28.dp)
                                ) {
                                    Icon(
                                        Icons.Default.Refresh,
                                        contentDescription = null,
                                        tint = if (connected) AccentBlue else DarkOnSurfaceVariant,
                                        modifier = Modifier.size(16.dp)
                                    )
                                    Text(
                                        "重试",
                                        style = MaterialTheme.typography.labelMedium,
                                        color = if (connected) DarkOnBackground else DarkOnSurfaceVariant
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
                    Brush.verticalGradient(
                        0f to DarkBackground.copy(alpha = 0.85f),
                        0.45f to DarkBackground.copy(alpha = 0.5f),
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
                    contentDescription = "返回",
                    tint = DarkOnBackground,
                    modifier = Modifier.size(22.dp)
                )
            }

            // 返回键右侧："Z传"页同款信号按钮（常驻）——传输中最关心信号强弱，断开也一眼可见。
            Spacer(modifier = Modifier.width(8.dp))
            SignalPill(
                rssi = cameraState.wifiRssi,
                connected = cameraState.isConnectedToCamera
            )

            // 右：胶囊始终常驻（传输中显速度/数量，完成后 done→图标）。
            // "重试全部"移到右下角 FAB（与停止按钮同位同规格），不再占顶栏。
            Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
                QueuePill(transferState = transferState, haptics = haptics, onClick = {})
            }
        }

        // ---------- 右下角悬浮控件（毛玻璃）+ 二次确认：传输中=停止，停止后有可重试=重试全部 ----------
        val confirmOpen = (transferState.isTransferring && showStopConfirm) ||
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
                    .background(Color.Black.copy(alpha = 0.3f))
                    .pointerInput(Unit) {
                        detectTapGestures {
                            showStopConfirm = false
                            showRetryConfirm = false
                        }
                    }
                    // 连拖动一起消费：否则手指在遮罩上滑动会穿透，底下列表照样滚。
                    .pointerInput(Unit) { detectDragGestures { change, _ -> change.consume() } }
            )
        }
        if (transferState.isTransferring) {
            ConfirmFab(
                expanded = showStopConfirm,
                icon = Icons.Default.Stop,
                iconTint = StatusError,
                contentDescription = "停止传输",
                title = "停止全部传输？",
                confirmText = "停止",
                confirmColor = StatusError,
                onToggle = { showStopConfirm = !showStopConfirm },
                onConfirm = {
                    showStopConfirm = false
                    transferViewModel.cancelTransfer()
                },
                onDismiss = { showStopConfirm = false },
                modifier = Modifier.align(Alignment.BottomEnd)
            )
        } else if (hasRetryable) {
            // 断开时置灰禁用而非消失（取消走断开兜底时相机会短暂离线，
            // 配合顶栏红色断连图标，用户能看懂"等重连"；重连后自动恢复可点）。
            val connected = cameraState.isConnectedToCamera
            ConfirmFab(
                expanded = showRetryConfirm,
                icon = Icons.Default.Refresh,
                iconTint = if (connected) AccentBlue else DarkOnSurfaceVariant,
                contentDescription = "重试失败任务",
                title = "重试失败任务？",
                confirmText = "重试",
                confirmColor = AccentBlue,
                enabled = connected,
                onToggle = { showRetryConfirm = !showRetryConfirm },
                onConfirm = {
                    showRetryConfirm = false
                    transferViewModel.retryFailed(cameraViewModel::getCamera)
                },
                onDismiss = { showRetryConfirm = false },
                modifier = Modifier.align(Alignment.BottomEnd)
            )
        }
    }
}

/**
 * 右下角悬浮的"图标 FAB + 二次确认"控件（停止/重试全部共用）：毛玻璃圆形按钮，
 * 点击后在其左上方弹出确认卡片（缩放动画以 FAB 所在的右下角为原点，向左上放大），
 * 确认后才真正执行。
 */
@Composable
private fun ConfirmFab(
    expanded: Boolean,
    icon: ImageVector,
    iconTint: Color,
    contentDescription: String,
    title: String,
    confirmText: String,
    confirmColor: Color,
    onToggle: () -> Unit,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    enabled: Boolean = true,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .navigationBarsPadding()
            .padding(end = 20.dp, bottom = 24.dp)
    ) {
        Column(horizontalAlignment = Alignment.End) {
            AnimatedVisibility(
                visible = expanded,
                // 以右下角为原点缩放弹出，视觉上从 FAB 位置向左上方展开。
                enter = scaleIn(transformOrigin = TransformOrigin(1f, 1f)) + fadeIn(),
                exit = scaleOut(transformOrigin = TransformOrigin(1f, 1f)) + fadeOut()
            ) {
                ConfirmCard(
                    title = title,
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
                Icon(
                    icon,
                    contentDescription = contentDescription,
                    tint = iconTint,
                    modifier = Modifier.size(26.dp)
                )
            }
        }
    }
}

@Composable
private fun ConfirmCard(
    title: String,
    confirmText: String,
    confirmColor: Color,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit
) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = DarkSurface,
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
                color = DarkOnBackground
            )
            Spacer(modifier = Modifier.height(12.dp))
            Row(
                modifier = Modifier.align(Alignment.End),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                TextButton(onClick = onDismiss) {
                    Text("取消", color = DarkOnSurfaceVariant)
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
 * 传输队列行内的小缩略图。命中缓存即显示，未命中且 [allowFetch] 为真时才发 GetThumb；
 * 传输进行中传入 allowFetch=false 让路给下载，未缓存的等空闲后本效应重跑补载。
 */
@Composable
private fun QueueThumbnail(
    handle: Int,
    allowFetch: Boolean,
    cameraViewModel: CameraViewModel
) {
    var thumbnail by remember(handle) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(handle, allowFetch) {
        if (thumbnail == null) {
            thumbnail = cameraViewModel.loadThumbnail(handle, allowFetch = allowFetch)
        }
    }
    Box(
        modifier = Modifier
            .size(52.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(DarkSurfaceVariant),
        contentAlignment = Alignment.Center
    ) {
        val image = thumbnail
        if (image != null) {
            Image(
                bitmap = image,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                // 相机缩略图常带上下黑边（3:2 画面塞进 4:3）；轻微放大裁掉黑边（与列表页一致）。
                modifier = Modifier
                    .fillMaxSize()
                    .scale(1.12f)
            )
        } else {
            Icon(
                Icons.Default.Image,
                contentDescription = null,
                tint = DarkOnSurfaceVariant,
                modifier = Modifier.size(22.dp)
            )
        }
    }
}

/** 队列任务状态图标（等待/传输/完成/失败/取消）。前导或尾部复用。 */
@Composable
private fun TaskStatusIcon(status: TransferStatus, size: Dp = 20.dp) {
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
            TransferStatus.WAITING -> StatusWaiting
            TransferStatus.TRANSFERING -> AccentBlue
            TransferStatus.COMPLETED -> StatusConnected
            TransferStatus.FAILED -> StatusError
            TransferStatus.CANCELLED -> DarkOnSurfaceVariant
        },
        modifier = Modifier.size(size)
    )
}

