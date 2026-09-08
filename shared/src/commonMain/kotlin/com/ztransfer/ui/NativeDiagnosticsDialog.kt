package com.ztransfer.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/** On-demand snapshot; no second subscription, persistent logger or network owner. */
@Composable
internal fun NativeDiagnosticsDialog(model: NativeConnectionHomeModel, language: String, onDismiss: () -> Unit) {
    fun text(cn: String, en: String, tw: String) = nativeActionText(language, cn, en, tw)
    var report by remember(model) { mutableStateOf(model.diagnosticReport()) }
    var clearing by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    AlertDialog(onDismissRequest = onDismiss,
        title = { Text(text("传图诊断", "Transfer diagnostics", "傳圖診斷")) },
        text = { Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
            Text(text("仅本次运行最近256条脱敏记录；分享前可检查。清理不影响照片、身份或任务。",
                "Last 256 redacted events from this run. Review before sharing. Clearing does not affect photos, identity or tasks.",
                "僅本次執行最近256筆去識別紀錄；分享前可檢查。清理不影響照片、身分或工作。"))
            Text(report, style = MaterialTheme.typography.bodySmall)
            if (failed) Text(text("无法打开分享，请关闭其他窗口后重试。",
                "Cannot open sharing. Close other windows and retry.", "無法開啟分享，請關閉其他視窗後重試。"))
            TextButton(onClick = { clearing = true }) { Text(text("清理诊断记录", "Clear diagnostics", "清理診斷紀錄")) }
        } },
        confirmButton = { TextButton(onClick = {
            if (model.shareDiagnostics()) onDismiss() else failed = true
        }) { Text(text("系统分享", "Share", "系統分享")) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(text("关闭", "Close", "關閉")) } })
    if (clearing) AlertDialog(onDismissRequest = { clearing = false },
        title = { Text(text("清理本次诊断记录？", "Clear diagnostics from this run?", "清理本次診斷紀錄？")) },
        confirmButton = { TextButton(onClick = {
            model.clearDiagnostics(); report = model.diagnosticReport(); clearing = false
        }) { Text(text("清理", "Clear", "清理")) } },
        dismissButton = { TextButton(onClick = { clearing = false }) { Text(text("取消", "Cancel", "取消")) } })
}
