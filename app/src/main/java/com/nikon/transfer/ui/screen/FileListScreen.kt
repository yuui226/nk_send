package com.nikon.transfer.ui.screen

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import com.nikon.transfer.protocol.NikonCamera
import com.nikon.transfer.ui.theme.*
import com.nikon.transfer.viewmodel.CameraViewModel
import com.nikon.transfer.viewmodel.TransferViewModel

data class FileGroup(
    val date: String,
    val files: List<NikonCamera.FileInfo>
)

fun groupFilesByDate(files: List<NikonCamera.FileInfo>): List<FileGroup> {
    val grouped = files.groupBy { it.captureDate?.take(8) ?: "未知日期" }
    return grouped.map { (date, groupFiles) ->
        FileGroup(date = date, files = groupFiles.sortedByDescending { it.captureDate ?: "" })
    }.sortedByDescending { it.date }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FileListScreen(
    cameraViewModel: CameraViewModel,
    transferViewModel: TransferViewModel,
    onNavigateToTransfer: () -> Unit
) {
    val state by cameraViewModel.state.collectAsState()
    val transferState by transferViewModel.state.collectAsState()
    val camera = cameraViewModel.getCamera()

    Column(modifier = Modifier.fillMaxSize()) {
        TopAppBar(
            title = {
                Column {
                    Text("文件列表", fontWeight = FontWeight.Bold)
                    if (state.files.isNotEmpty()) {
                        Text(
                            text = "${state.files.size} 个文件",
                            style = MaterialTheme.typography.bodySmall,
                            color = DarkOnSurfaceVariant
                        )
                    }
                }
            },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = DarkBackground),
            actions = {
                if (transferState.tasks.isNotEmpty()) {
                    val remaining = transferState.tasks.count {
                        it.status == com.nikon.transfer.viewmodel.TransferStatus.WAITING ||
                        it.status == com.nikon.transfer.viewmodel.TransferStatus.TRANSFERING
                    }
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .clickable { onNavigateToTransfer() }
                            .padding(horizontal = 12.dp, vertical = 8.dp)
                    ) {
                        // 传输速度
                        if (transferState.isTransferring && transferState.currentSpeed > 0) {
                            Text(
                                text = "${formatFileListSpeed(transferState.currentSpeed)}  ",
                                style = MaterialTheme.typography.labelMedium,
                                color = AccentBlue
                            )
                        }
                        Text(
                            text = "$remaining/${transferState.tasks.size}",
                            style = MaterialTheme.typography.labelMedium,
                            color = AccentBlue
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                        Icon(Icons.Default.CloudDownload, contentDescription = "传输队列", tint = AccentBlue)
                    }
                }
            }
        )

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
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Default.FolderOff, contentDescription = null, modifier = Modifier.size(64.dp), tint = DarkOnSurfaceVariant)
                    Spacer(modifier = Modifier.height(16.dp))
                    Text("相机中无文件", color = DarkOnSurfaceVariant)
                }
            }
        }

        if (state.files.isNotEmpty()) {
            val groups = groupFilesByDate(state.files)

            LazyColumn(
                modifier = Modifier.weight(1f),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                items(groups) { group ->
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(12.dp),
                        colors = CardDefaults.cardColors(containerColor = DarkSurface)
                    ) {
                        Column(modifier = Modifier.padding(16.dp)) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(
                                    Icons.Default.CalendarToday,
                                    contentDescription = null,
                                    tint = AccentBlue,
                                    modifier = Modifier.size(20.dp)
                                )
                                Spacer(modifier = Modifier.width(8.dp))
                                Text(
                                    text = formatDateHeader(group.date),
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.Bold,
                                    color = DarkOnBackground,
                                    modifier = Modifier.weight(1f)
                                )
                                Text(
                                    text = "${group.files.size}张",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = DarkOnSurfaceVariant
                                )
                                Spacer(modifier = Modifier.width(8.dp))
                                FilledTonalButton(
                                    onClick = {
                                        if (camera != null) {
                                            transferViewModel.addToQueue(group.files, camera)
                                            onNavigateToTransfer()
                                        }
                                    },
                                    shape = RoundedCornerShape(8.dp)
                                ) {
                                    Icon(Icons.Default.CloudDownload, contentDescription = null, modifier = Modifier.size(16.dp))
                                    Spacer(modifier = Modifier.width(4.dp))
                                    Text("传输", style = MaterialTheme.typography.labelMedium)
                                }
                            }

                            Spacer(modifier = Modifier.height(12.dp))

                            group.files.forEach { file ->
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable {
                                            if (camera != null) {
                                                transferViewModel.addToQueue(listOf(file), camera)
                                            }
                                        }
                                        .padding(vertical = 8.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Surface(
                                        shape = RoundedCornerShape(4.dp),
                                        color = when (file.extension) {
                                            ".jpg" -> AccentBlue.copy(alpha = 0.2f)
                                            ".nef" -> AccentPurple.copy(alpha = 0.2f)
                                            ".mov" -> AccentOrange.copy(alpha = 0.2f)
                                            else -> DarkSurfaceVariant
                                        }
                                    ) {
                                        Text(
                                            text = file.extension.uppercase().removePrefix("."),
                                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                                            style = MaterialTheme.typography.labelSmall,
                                            color = when (file.extension) {
                                                ".jpg" -> AccentBlue
                                                ".nef" -> AccentPurple
                                                ".mov" -> AccentOrange
                                                else -> DarkOnSurfaceVariant
                                            }
                                        )
                                    }

                                    Spacer(modifier = Modifier.width(8.dp))

                                    Text(
                                        text = file.fileName,
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = DarkOnBackground,
                                        modifier = Modifier.weight(1f)
                                    )

                                    Text(
                                        text = formatFileSize(file.size),
                                        style = MaterialTheme.typography.bodySmall,
                                        color = DarkOnSurfaceVariant
                                    )
                                }

                                Divider(
                                    modifier = Modifier.padding(start = 28.dp),
                                    color = DarkSurfaceVariant.copy(alpha = 0.5f)
                                )
                            }
                        }
                    }
                }

                if (state.isLoadingFiles) {
                    item {
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
                }
            }
        }
    }
}

private fun formatDateHeader(date: String): String {
    if (date.length < 8 || date == "未知日期") return date
    return "${date.substring(0, 4)}-${date.substring(4, 6)}-${date.substring(6, 8)}"
}

private fun formatFileSize(bytes: Long): String {
    return when {
        bytes < 1024 -> "$bytes B"
        bytes < 1024 * 1024 -> "${bytes / 1024} KB"
        bytes < 1024 * 1024 * 1024 -> String.format("%.1f MB", bytes / (1024.0 * 1024.0))
        else -> String.format("%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0))
    }
}

private fun formatFileListSpeed(bytesPerSec: Long): String {
    return when {
        bytesPerSec < 1024 -> "$bytesPerSec B/s"
        bytesPerSec < 1024 * 1024 -> String.format("%.1f KB/s", bytesPerSec / 1024.0)
        else -> String.format("%.1f MB/s", bytesPerSec / (1024.0 * 1024.0))
    }
}
