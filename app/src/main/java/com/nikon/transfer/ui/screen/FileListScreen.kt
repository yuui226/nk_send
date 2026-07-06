package com.nikon.transfer.ui.screen

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.nikon.transfer.protocol.NikonCamera
import com.nikon.transfer.ui.theme.*
import com.nikon.transfer.ui.util.formatFileSize
import com.nikon.transfer.ui.util.formatSpeed
import com.nikon.transfer.viewmodel.CameraViewModel
import com.nikon.transfer.viewmodel.TransferStatus
import com.nikon.transfer.viewmodel.TransferTask
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
    onNavigateToTransfer: () -> Unit,
    onNavigateToSettings: () -> Unit
) {
    val state by cameraViewModel.state.collectAsState()
    val transferState by transferViewModel.state.collectAsState()
    val camera = cameraViewModel.getCamera()

    Column(modifier = Modifier.fillMaxSize()) {
        TopAppBar(
            title = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Z传", fontWeight = FontWeight.Bold, style = MaterialTheme.typography.headlineSmall)
                    IconButton(
                        onClick = onNavigateToSettings,
                        modifier = Modifier.size(40.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.Settings,
                            contentDescription = "设置",
                            tint = DarkOnSurfaceVariant
                        )
                    }
                }
            },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = DarkBackground),
            actions = {
                if (transferState.tasks.isNotEmpty()) {
                    val total = transferState.tasks.size
                    val remaining = transferState.tasks.count {
                        it.status == TransferStatus.WAITING ||
                        it.status == TransferStatus.TRANSFERING
                    }
                    val done = total - remaining
                    val progressFraction = if (total > 0) done.toFloat() / total else 0f

                    Surface(
                        onClick = onNavigateToTransfer,
                        shape = RoundedCornerShape(20.dp),
                        color = AccentBlue.copy(alpha = 0.12f),
                        modifier = Modifier
                            .height(36.dp)
                            .padding(end = 8.dp)
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            // 进度填充背景
                            Box(
                                modifier = Modifier
                                    .matchParentSize()
                                    .drawBehind {
                                        drawRect(
                                            color = AccentBlue.copy(alpha = 0.35f),
                                            size = Size(size.width * progressFraction, size.height)
                                        )
                                    }
                            )
                            Row(
                                modifier = Modifier.padding(horizontal = 14.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                if (transferState.isTransferring && transferState.currentSpeed > 0) {
                                    Text(
                                        text = "${formatSpeed(transferState.currentSpeed)} · ",
                                        style = MaterialTheme.typography.labelMedium,
                                        color = AccentBlue
                                    )
                                }
                                Text(
                                    text = "$done/$total",
                                    style = MaterialTheme.typography.labelMedium,
                                    color = AccentBlue,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                        }
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
            val groups = remember(state.files) { groupFilesByDate(state.files) }
            val queuedByHandle = remember(transferState.tasks) {
                transferState.tasks.associateBy { it.file.handle }
            }

            // 两种展示形态共享的交互：分组批量传输 / 单文件点击（分组逻辑不变，仅展示不同）。
            val onTransferGroup: (List<NikonCamera.FileInfo>) -> Unit = onTransferGroup@{ remaining ->
                if (transferState.transferDirUri == null) {
                    onNavigateToSettings(); return@onTransferGroup
                }
                if (camera != null && remaining.isNotEmpty()) {
                    transferViewModel.addToQueue(remaining, camera)
                    onNavigateToTransfer()
                }
            }
            val onTapFile: (NikonCamera.FileInfo) -> Unit = onTapFile@{ file ->
                if (transferState.transferDirUri == null) {
                    onNavigateToSettings(); return@onTapFile
                }
                if (camera != null) transferViewModel.addToQueue(listOf(file), camera)
            }

            if (transferState.thumbnailMode) {
                // 传输队列有未完成任务时，缩略图让路：只用缓存，不发起新的 GetThumb，避免抢占下载通道。
                val transfersBusy = transferState.tasks.any {
                    it.status == TransferStatus.WAITING || it.status == TransferStatus.TRANSFERING
                }
                ThumbnailGrid(
                    groups = groups,
                    queuedByHandle = queuedByHandle,
                    columns = transferState.thumbnailColumns,
                    isLoading = state.isLoadingFiles,
                    transfersBusy = transfersBusy,
                    cameraViewModel = cameraViewModel,
                    onTransferGroup = onTransferGroup,
                    onTapFile = onTapFile,
                    modifier = Modifier.weight(1f)
                )
            } else {
                FileList(
                    groups = groups,
                    queuedByHandle = queuedByHandle,
                    isLoading = state.isLoadingFiles,
                    onTransferGroup = onTransferGroup,
                    onTapFile = onTapFile,
                    modifier = Modifier.weight(1f)
                )
            }
        }
    }
}

@Composable
private fun GroupHeader(
    group: FileGroup,
    queuedByHandle: Map<Int, TransferTask>,
    onTransferGroup: (List<NikonCamera.FileInfo>) -> Unit
) {
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
            color = DarkOnBackground
        )
        Spacer(modifier = Modifier.width(8.dp))
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
private fun FileList(
    groups: List<FileGroup>,
    queuedByHandle: Map<Int, TransferTask>,
    isLoading: Boolean,
    onTransferGroup: (List<NikonCamera.FileInfo>) -> Unit,
    onTapFile: (NikonCamera.FileInfo) -> Unit,
    modifier: Modifier = Modifier
) {
    LazyColumn(
        modifier = modifier,
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
                    GroupHeader(group, queuedByHandle, onTransferGroup)

                    Spacer(modifier = Modifier.height(12.dp))

                    group.files.forEach { file ->
                        val task = queuedByHandle[file.handle]
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .then(
                                    if (task == null) Modifier.clickable { onTapFile(file) } else Modifier
                                )
                                .padding(vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            FileTypeBadge(file.extension)

                            Spacer(modifier = Modifier.width(8.dp))

                            Text(
                                text = file.fileName,
                                style = MaterialTheme.typography.bodyMedium,
                                color = if (task != null) DarkOnSurfaceVariant else DarkOnBackground,
                                modifier = Modifier.weight(1f)
                            )

                            Text(
                                text = formatFileSize(file.size),
                                style = MaterialTheme.typography.bodySmall,
                                color = DarkOnSurfaceVariant
                            )

                            if (task != null) {
                                Spacer(modifier = Modifier.width(10.dp))
                                TransferStatusIndicator(status = task.status)
                            }
                        }

                        Divider(
                            modifier = Modifier.padding(start = 28.dp),
                            color = DarkSurfaceVariant.copy(alpha = 0.5f)
                        )
                    }
                }
            }
        }

        if (isLoading) {
            item { LoadingMoreRow() }
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
    cameraViewModel: CameraViewModel,
    onTransferGroup: (List<NikonCamera.FileInfo>) -> Unit,
    onTapFile: (NikonCamera.FileInfo) -> Unit,
    modifier: Modifier = Modifier
) {
    LazyVerticalGrid(
        columns = GridCells.Fixed(columns.coerceIn(1, 4)),
        modifier = modifier,
        contentPadding = PaddingValues(12.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        groups.forEach { group ->
            // 分组头整行跨列，保持与列表模式一致的分组语义
            item(
                span = { GridItemSpan(maxLineSpan) },
                key = "header_${group.date}",
                contentType = "header"
            ) {
                Column {
                    Spacer(modifier = Modifier.height(4.dp))
                    GroupHeader(group, queuedByHandle, onTransferGroup)
                    Spacer(modifier = Modifier.height(4.dp))
                }
            }
            items(group.files, key = { it.handle }, contentType = { "cell" }) { file ->
                ThumbnailCell(
                    file = file,
                    task = queuedByHandle[file.handle],
                    transfersBusy = transfersBusy,
                    cameraViewModel = cameraViewModel,
                    onTapFile = onTapFile
                )
            }
        }

        if (isLoading) {
            item(span = { GridItemSpan(maxLineSpan) }) { LoadingMoreRow() }
        }
    }
}

@Composable
private fun ThumbnailCell(
    file: NikonCamera.FileInfo,
    task: TransferTask?,
    transfersBusy: Boolean,
    cameraViewModel: CameraViewModel,
    onTapFile: (NikonCamera.FileInfo) -> Unit
) {
    // 已加载的缩略图按 handle 记住，transfersBusy 变化不会让它闪回占位。
    var thumbnail by remember(file.handle) { mutableStateOf<ImageBitmap?>(null) }
    // 仅在尚未加载时才尝试取；传输进行中只读缓存(allowFetch=false)，队列空闲后本效应重跑自动补载。
    LaunchedEffect(file.handle, transfersBusy) {
        if (thumbnail == null) {
            thumbnail = cameraViewModel.loadThumbnail(file.handle, allowFetch = !transfersBusy)
        }
    }

    Box(
        modifier = Modifier
            .aspectRatio(1f)
            .clip(RoundedCornerShape(8.dp))
            .background(DarkSurface)
            .then(if (task == null) Modifier.clickable { onTapFile(file) } else Modifier)
    ) {
        val image = thumbnail
        if (image != null) {
            Image(
                bitmap = image,
                contentDescription = file.fileName,
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
                modifier = Modifier.padding(horizontal = 5.dp, vertical = 1.dp),
                style = MaterialTheme.typography.labelSmall,
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
private fun FileTypeBadge(extension: String) {
    Surface(
        shape = RoundedCornerShape(4.dp),
        color = when (extension) {
            ".jpg" -> AccentBlue.copy(alpha = 0.2f)
            ".nef" -> AccentPurple.copy(alpha = 0.2f)
            ".mov" -> AccentOrange.copy(alpha = 0.2f)
            else -> DarkSurfaceVariant
        }
    ) {
        Text(
            text = extension.uppercase().removePrefix("."),
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
            style = MaterialTheme.typography.labelSmall,
            color = when (extension) {
                ".jpg" -> AccentBlue
                ".nef" -> AccentPurple
                ".mov" -> AccentOrange
                else -> DarkOnSurfaceVariant
            }
        )
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
