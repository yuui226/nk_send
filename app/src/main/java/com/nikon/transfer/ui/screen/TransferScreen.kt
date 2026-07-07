package com.nikon.transfer.ui.screen

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.nikon.transfer.ui.theme.*
import com.nikon.transfer.ui.util.formatFileSize
import com.nikon.transfer.ui.util.formatSpeed
import com.nikon.transfer.viewmodel.CameraViewModel
import com.nikon.transfer.viewmodel.TransferStatus
import com.nikon.transfer.viewmodel.TransferViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TransferScreen(
    transferViewModel: TransferViewModel,
    cameraViewModel: CameraViewModel,
    onNavigateBack: () -> Unit
) {
    val transferState by transferViewModel.state.collectAsState()
    val camera = cameraViewModel.getCamera()

    Column(modifier = Modifier.fillMaxSize().systemBarsPadding()) {
        TopAppBar(
            title = {
                Column(modifier = Modifier.padding(start = 16.dp)) {
                    Text("传输队列", fontWeight = FontWeight.Bold, style = MaterialTheme.typography.headlineSmall)
                    if (transferState.tasks.isNotEmpty()) {
                        val completed = transferState.tasks.count { it.status == TransferStatus.COMPLETED }
                        val failed = transferState.tasks.count { it.status == TransferStatus.FAILED }
                        Text(
                            text = buildString {
                                append("$completed/${transferState.tasks.size}")
                                if (failed > 0) append(" · $failed 失败")
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = DarkOnSurfaceVariant
                        )
                    }
                }
            },
            navigationIcon = {
                IconButton(onClick = onNavigateBack) {
                    Icon(Icons.Default.ArrowBack, contentDescription = "返回")
                }
            },
            actions = {
                if (transferState.isTransferring) {
                    if (transferState.currentSpeed > 0) {
                        Text(
                            text = formatSpeed(transferState.currentSpeed),
                            style = MaterialTheme.typography.bodyMedium,
                            color = AccentBlue,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(end = 4.dp)
                        )
                    }
                    OutlinedIconButton(
                        onClick = { transferViewModel.cancelTransfer() },
                        border = BorderStroke(1.dp, StatusError),
                        modifier = Modifier.padding(end = 4.dp)
                    ) {
                        Icon(
                            Icons.Default.Stop,
                            contentDescription = "取消传输",
                            tint = StatusError
                        )
                    }
                } else {
                    val hasRetryable = transferState.tasks.any {
                        it.status == TransferStatus.FAILED || it.status == TransferStatus.CANCELLED
                    }
                    val hasFinished = transferState.tasks.any {
                        it.status == TransferStatus.COMPLETED ||
                        it.status == TransferStatus.FAILED ||
                        it.status == TransferStatus.CANCELLED
                    }
                    if (hasRetryable && camera != null) {
                        TextButton(onClick = { transferViewModel.retryFailed(camera) }) {
                            Text("重试全部")
                        }
                    }
                    if (hasFinished) {
                        IconButton(onClick = { transferViewModel.clearCompleted() }) {
                            Icon(Icons.Default.ClearAll, contentDescription = "清除已结束")
                        }
                    }
                }
            },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = DarkBackground)
        )

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
                modifier = Modifier.weight(1f),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                // 倒序显示：最新加入队列的排在最上方（asReversed 是视图，不复制列表）。
                items(transferState.tasks.asReversed(), key = { it.file.handle }) { task ->
                    Card(
                        modifier = Modifier.fillMaxWidth(),
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
                        Column(modifier = Modifier.padding(16.dp)) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(
                                    imageVector = when (task.status) {
                                        TransferStatus.WAITING -> Icons.Default.Schedule
                                        TransferStatus.TRANSFERING -> Icons.Default.Downloading
                                        TransferStatus.COMPLETED -> Icons.Default.CheckCircle
                                        TransferStatus.FAILED -> Icons.Default.Error
                                        TransferStatus.CANCELLED -> Icons.Default.Cancel
                                    },
                                    contentDescription = null,
                                    tint = when (task.status) {
                                        TransferStatus.WAITING -> StatusWaiting
                                        TransferStatus.TRANSFERING -> AccentBlue
                                        TransferStatus.COMPLETED -> StatusConnected
                                        TransferStatus.FAILED -> StatusError
                                        TransferStatus.CANCELLED -> DarkOnSurfaceVariant
                                    },
                                    modifier = Modifier.size(20.dp)
                                )

                                Spacer(modifier = Modifier.width(12.dp))

                                // 缩略图模式：状态图标后展示缩略图，行高随之略增。
                                // allowFetch=!isTransferring：传输中只读缓存，不发 GetThumb 抢带宽。
                                if (transferState.thumbnailMode) {
                                    QueueThumbnail(
                                        handle = task.file.handle,
                                        allowFetch = !transferState.isTransferring,
                                        cameraViewModel = cameraViewModel
                                    )
                                    Spacer(modifier = Modifier.width(12.dp))
                                }

                                Text(
                                    text = task.file.fileName,
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = DarkOnBackground,
                                    modifier = Modifier.weight(1f)
                                )

                                // 右侧：传输中显示已下载/总大小，完成显示大小，失败显示错误
                                when (task.status) {
                                    TransferStatus.TRANSFERING -> {
                                        Text(
                                            text = "${formatFileSize(task.downloaded)}/${formatFileSize(task.file.size)}",
                                            style = MaterialTheme.typography.labelMedium,
                                            color = AccentBlue
                                        )
                                    }
                                    TransferStatus.COMPLETED -> {
                                        Text(
                                            text = if (task.skipped) "已存在" else formatFileSize(task.file.size),
                                            style = MaterialTheme.typography.labelMedium,
                                            color = StatusConnected
                                        )
                                    }
                                    else -> {}
                                }
                            }

                            if (task.status == TransferStatus.TRANSFERING) {
                                Spacer(modifier = Modifier.height(8.dp))
                                LinearProgressIndicator(
                                    progress = task.progress,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .height(4.dp),
                                    color = AccentBlue,
                                    trackColor = DarkSurfaceVariant,
                                )
                            }

                            if (task.status == TransferStatus.FAILED) {
                                if (task.error != null) {
                                    Spacer(modifier = Modifier.height(8.dp))
                                    Text(
                                        text = task.error,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = StatusError
                                    )
                                }
                                if (camera != null) {
                                    Spacer(modifier = Modifier.height(8.dp))
                                    OutlinedButton(
                                        onClick = { transferViewModel.retrySingleTask(task.file.handle, camera) },
                                        shape = RoundedCornerShape(8.dp)
                                    ) {
                                        Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(16.dp))
                                        Spacer(modifier = Modifier.width(4.dp))
                                        Text("重新传输", style = MaterialTheme.typography.labelMedium)
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
            .size(44.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(DarkSurfaceVariant),
        contentAlignment = Alignment.Center
    ) {
        val image = thumbnail
        if (image != null) {
            Image(
                bitmap = image,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
        } else {
            Icon(
                Icons.Default.Image,
                contentDescription = null,
                tint = DarkOnSurfaceVariant,
                modifier = Modifier.size(20.dp)
            )
        }
    }
}

