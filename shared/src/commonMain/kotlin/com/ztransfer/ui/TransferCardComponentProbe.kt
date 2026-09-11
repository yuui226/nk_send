package com.ztransfer.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.screen.*
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask

/** Explicit component fixture, never a camera/transfer status source for the product. */
@Composable
internal fun TransferCardComponentProbe() {
    var status by remember { mutableStateOf(TransferStatus.WAITING) }
    var generating by remember { mutableStateOf(false) }
    var confirmVisible by remember { mutableStateOf(false) }
    var confirmations by remember { mutableIntStateOf(0) }
    val colors = AppTheme.colors
    val task = remember(status, generating) {
        TransferTask(CameraFileInfo(1, 1024, "UI_SAMPLE.JPG", null), taskId = 1,
            status = status, isGeneratingFrame = generating)
    }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("队列组件样本（非真实传输）", color = colors.onBackground)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { status = TransferStatus.entries[(status.ordinal + 1) % TransferStatus.entries.size] }) {
                Text(status.name)
            }
            OutlinedButton(onClick = { generating = !generating }) { Text(if (generating) "停止生成态" else "生成态") }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            QueueThumbnailContent(null)
            SharedTransferTaskCardContent(task, TransferTaskCardText(
                speedText = if (status == TransferStatus.TRANSFERING) "1.0 MB/s" else null,
                transferDuration = if (status == TransferStatus.COMPLETED) "0:01" else null,
                generationDuration = if (generating) "0:02" else null,
                effectText = if (generating) "效果标签样本" else null,
                fileSizeText = "1 KB", failureText = "错误文案样本",
            ), Modifier.weight(1f))
            TaskStatusBadge(task, task.taskId)
        }
        SharedTransferRetryButton(visible = status == TransferStatus.FAILED,
            enabled = false, onClick = {}, contentDescription = "重试样本（禁用，不连接相机）")
        SharedQueueConfirmFab(expanded = confirmVisible,
            icon = { Icon(Icons.Default.Refresh, contentDescription = "确认组件样本") },
            title = "组件确认测试", confirmText = "确认", confirmColor = colors.accentBlue,
            onToggle = { confirmVisible = !confirmVisible },
            onConfirm = { confirmations++; confirmVisible = false }, onDismiss = { confirmVisible = false },
            cancelText = "取消", subtitle = "只记录点击，不执行清空或重试。")
        Text("确认次数：$confirmations", color = colors.onSurfaceVariant)
    }
}
