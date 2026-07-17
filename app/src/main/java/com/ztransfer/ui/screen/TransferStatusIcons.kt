package com.ztransfer.ui.screen

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Downloading
import androidx.compose.material.icons.filled.PriorityHigh
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.viewmodel.TransferStatus

/**
 * 传输状态的统一字形 + 语义色（单一数据源）：传输页卡片 [TaskStatusIcon] 与
 * 列表缩略图角标 [TransferStatusIndicator] 共用，改一处两页同步。
 *
 * 字形一律用「裸符号」（勾/叹/叉/时钟），在卡面与列表黑圆片两种容器上都成立；
 * 颜色统一走语义色（等待琥珀 / 传输蓝 / 完成绿 / 失败红 / 取消灰）。
 *
 * 传输中(TRANSFERING)两处表现【有意不同】——卡片下方已有整宽进度条，故卡片左侧用
 * 下载字形（此处返回值）；列表角标改用确定型进度环，自行渲染、不取此处字形。
 */
@Composable
fun statusGlyph(status: TransferStatus): Pair<ImageVector, Color> {
    val c = AppTheme.colors
    return when (status) {
        TransferStatus.WAITING -> Icons.Default.Schedule to c.statusWaiting
        TransferStatus.TRANSFERING -> Icons.Default.Downloading to c.accentBlue
        TransferStatus.COMPLETED -> Icons.Default.Check to c.statusConnected
        TransferStatus.FAILED -> Icons.Default.PriorityHigh to c.statusError
        TransferStatus.CANCELLED -> Icons.Default.Close to c.onSurfaceVariant
    }
}
