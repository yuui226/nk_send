package com.ztransfer.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

internal data class NativeRecoveryRecord(val names: List<String> = emptyList(), val completed: Int = 0,
    val unavailable: Boolean = false, val truncated: Boolean = false)

@Composable
internal fun NativeRecoveryRecordCard(model: NativeConnectionHomeModel, language: String) {
    val state by model.state.collectAsState()
    val record = state.recoveryRecord
    if (record == NativeRecoveryRecord()) return
    var opened by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf(false) }
    fun text(cn: String, en: String, tw: String = cn) = nativeActionText(language, cn, en, tw)
    TextButton(onClick = { opened = true }) {
        Text(text("上次任务记录", "Previous transfer record", "上次工作記錄"))
    }
    if (opened) AlertDialog(onDismissRequest = { opened = false },
        title = { Text(text("上次任务记录", "Previous transfer record", "上次工作記錄")) },
        text = { Column(Modifier.heightIn(max = 400.dp).verticalScroll(rememberScrollState())) {
            Text(if (record.unavailable) text("记录无法读取，原数据未覆盖。", "Record unreadable; original data retained.", "記錄無法讀取，原資料未覆寫。")
            else text("未完成：", "Unfinished: ", "未完成：") + record.names.size +
                text("；上次确认完成：", "; previously completed: ", "；上次確認完成：") + record.completed)
            Text(text("此记录仅供核对，不会自动重放旧句柄或续写旧片段。请重新连接相机、核对卡槽与照片后选入队；已有完整原片按原规则复用。清除此记录不删除照片或配对身份。",
                "For reference only. Old handles and partial files are never replayed. Reconnect, verify the card and photos, then select again; complete originals follow the existing reuse rules. Clearing this record does not delete photos or pairing.",
                "此記錄只供核對，不會自動重播舊控制代碼或續寫舊片段。請重新連接相機、核對卡槽與照片後選入佇列；完整原檔按既有規則重用。清除記錄不刪除照片或配對身分。"))
            if (record.truncated) Text(text("仅保留前500项。", "First 500 items retained.", "只保留前500項。"))
            record.names.forEach { Text(it) }
        } },
        confirmButton = { TextButton(onClick = { opened = false }) { Text(text("关闭", "Close", "關閉")) } },
        dismissButton = { TextButton(enabled = !state.busy && !state.clearingRecovery, onClick = { confirm = true }) {
            Text(text("备份并清除记录", "Back up and clear record", "備份並清除記錄"))
        } })
    if (confirm) AlertDialog(onDismissRequest = { confirm = false },
        title = { Text(text("只清除任务记录？", "Clear only this record?", "只清除工作記錄？")) },
        text = { Text(text("旧记录将备份；原片、临时片段、目录授权及相机身份均保留。", "The record is backed up. Originals, partials, directory grants and camera identity remain.",
            "舊記錄將備份；原檔、暫存片段、目錄授權及相機身分均保留。")) },
        confirmButton = { TextButton(onClick = { model.clearRecoveryRecord(); confirm = false; opened = false }) { Text(text("确认", "Confirm", "確認")) } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text(text("取消", "Cancel", "取消")) } })
}
