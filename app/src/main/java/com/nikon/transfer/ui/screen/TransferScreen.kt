package com.nikon.transfer.ui.screen

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.nikon.transfer.ui.theme.*
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

    Column(modifier = Modifier.fillMaxSize()) {
        TopAppBar(
            title = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f, fill = false)) {
                        Text("传输队列", fontWeight = FontWeight.Bold)
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
                    // 速度显示在标题右侧
                    if (transferState.isTransferring && transferState.currentSpeed > 0) {
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(
                            text = formatSpeed(transferState.currentSpeed),
                            style = MaterialTheme.typography.bodyMedium,
                            color = AccentBlue,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
            },
            navigationIcon = {
                IconButton(onClick = onNavigateBack) {
                    Icon(Icons.Default.ArrowBack, contentDescription = "返回")
                }
            },
            actions = {},
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
                itemsIndexed(transferState.tasks) { index, task ->
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
                                            text = "${formatSize(task.downloaded)}/${formatSize(task.file.size)}",
                                            style = MaterialTheme.typography.labelMedium,
                                            color = AccentBlue
                                        )
                                    }
                                    TransferStatus.COMPLETED -> {
                                        Text(
                                            text = formatSize(task.file.size),
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
                                        onClick = { transferViewModel.retrySingleTask(index, camera) },
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

private fun formatSize(bytes: Long): String {
    return when {
        bytes < 1024 -> "$bytes B"
        bytes < 1024 * 1024 -> "${bytes / 1024} KB"
        bytes < 1024 * 1024 * 1024 -> String.format("%.1f MB", bytes / (1024.0 * 1024.0))
        else -> String.format("%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0))
    }
}

private fun formatSpeed(bytesPerSec: Long): String {
    return when {
        bytesPerSec < 1024 -> "$bytesPerSec B/s"
        bytesPerSec < 1024 * 1024 -> String.format("%.1f KB/s", bytesPerSec / 1024.0)
        else -> String.format("%.1f MB/s", bytesPerSec / (1024.0 * 1024.0))
    }
}
