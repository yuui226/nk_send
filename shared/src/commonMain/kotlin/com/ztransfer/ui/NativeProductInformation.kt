package com.ztransfer.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.screen.SharedAppearanceSettingsCard

@Composable
internal fun NativeProductInformation(appearance: NativeAppearanceModel, files: NativeFilesPageModel? = null) {
    val state by appearance.state.collectAsState()
    fun text(cn: String, en: String, tw: String = cn) = nativeActionText(state.resolvedLanguage, cn, en, tw)
    var detail by remember { mutableStateOf<String?>(null) }
    var reset by remember { mutableStateOf<String?>(null) }
    var feedback by remember { mutableStateOf<String?>(null) }
    Text(appearance.productVersion(), style = MaterialTheme.typography.bodySmall)
    Row {
        TextButton(onClick = { detail = "help" }) { Text(text("帮助", "Help", "說明")) }
        TextButton(onClick = { detail = "privacy" }) { Text(text("隐私说明", "Privacy", "隱私說明")) }
        TextButton(onClick = appearance::openSourceRepository) { Text(text("源码", "Source", "原始碼")) }
    }
    TextButton(onClick = {
        feedback = if (appearance.copyFeedbackContact()) text("反馈 QQ 953000922 已复制。", "Feedback QQ 953000922 copied.", "回饋 QQ 953000922 已複製。")
            else text("无法复制，请手动记录 QQ 953000922。", "Unable to copy. Feedback QQ: 953000922.", "無法複製，請手動記錄 QQ 953000922。")
    }) { Text(text("反馈", "Feedback", "回饋")) }
    feedback?.let { Text(it) }
    if (state.preferencesFailed) TextButton(onClick = { reset = "appearance" }) {
        Text(text("修复外观偏好", "Repair appearance preferences", "修復外觀偏好"))
    }
    val browseFailed = files?.preferencesFailed?.collectAsState()?.value == true
    if (browseFailed) TextButton(onClick = { reset = "browse" }) {
        Text(text("修复浏览偏好", "Repair browse preferences", "修復瀏覽偏好"))
    }
    if (detail != null) AlertDialog(onDismissRequest = { detail = null },
        title = { Text(if (detail == "help") text("传图帮助", "Transfer help", "傳圖說明") else text("隐私说明", "Privacy", "隱私說明")) },
        text = { Text(if (detail == "help")
            text("AP：加入相机热点；STA：相机与手机接入同一局域网并在相机确认电脑配对。允许本地网络。连接后点单张或日期/连拍组的传输按钮；设置中选择保存目录。图库与系统分享只处理已存原片。iOS 本轮不提供 USB、照片效果、会员、监看或 GPS 发送，后台传输不保证持续。",
                "AP: join the camera hotspot. STA: use the same LAN and confirm computer pairing on the camera. Allow Local Network. Transfer a photo or date/burst group, and choose a destination in settings. Photos and sharing use saved originals. USB, effects, membership, live view and GPS sending are outside this iOS scope; uninterrupted background transfer is not guaranteed.",
                "AP：加入相機熱點；STA：相機與手機接入同一區域網路並在相機確認電腦配對。允許本機網路。連接後點單張或日期/連拍組的傳輸按鈕；設定中選擇儲存目錄。圖庫與系統分享只處理已存原檔。此版不提供 USB、照片效果、會員、監看或 GPS 傳送，不保證持續背景傳輸。")
            else text("连接相机使用本地网络；选择 Files 目录会授予该目录访问权限。加入图库仅请求添加权限，不读取或管理相册。导出和分享由你明确发起，交给你选择的系统服务；原片及其中已有的 EXIF/GPS 元数据不会因导出而去除。配对身份、目录授权与界面偏好分别存放，重置界面偏好不删除照片或身份。",
                "Camera connections use the local network. Selecting a Files directory grants access to that directory. Photos requests add-only access, not library reading or album management. You initiate exports to your chosen system service. Original EXIF/GPS metadata remains in exported originals. Pairing identity, directory grants and UI preferences have separate owners; resetting UI preferences does not delete photos or identity.",
                "連接相機使用本機網路；選擇 Files 目錄會授予該目錄存取權。加入圖庫只請求新增權限，不讀取或管理相簿。匯出與分享由你明確發起；原檔既有 EXIF/GPS 中繼資料仍會保留。配對身分、目錄授權與介面偏好分開儲存，重置介面偏好不刪除照片或身分。")) },
        confirmButton = { TextButton(onClick = { detail = null }) { Text(text("关闭", "Close", "關閉")) } })
    if (reset != null) AlertDialog(onDismissRequest = { reset = null },
        title = { Text(text("备份并恢复默认值？", "Back up and restore defaults?", "備份並恢復預設值？")) },
        text = { Text(text("只重置所选界面偏好，保留一份旧值备份。不改照片、配对身份、目录授权、传输偏好或队列。", "Reset only the selected UI preferences and keep one backup. Photos, pairing, directory grants, transfer preferences and the queue are unchanged.", "只重置所選介面偏好並保留一份舊值。不更動照片、配對身分、目錄授權、傳輸偏好或佇列。")) },
        confirmButton = { TextButton(onClick = {
            val ok = if (reset == "appearance") appearance.resetAfterConfirmation() else files?.resetBrowseAfterConfirmation() == true
            feedback = if (ok) text("偏好已恢复。", "Preferences restored.", "偏好已恢復。") else text("未能恢复，请重试。", "Could not restore; retry.", "未能恢復，請重試。")
            reset = null
        }) { Text(text("确认恢复", "Restore", "確認恢復")) } },
        dismissButton = { TextButton(onClick = { reset = null }) { Text(text("取消", "Cancel", "取消")) } })
}

@Composable
internal fun NativeGeneralSettingsDialog(appearance: NativeAppearanceModel, onDismiss: () -> Unit) {
    val state by appearance.state.collectAsState()
    val text = NativeSettingsTextCatalog.forLanguage(state.resolvedLanguage)
    AlertDialog(onDismissRequest = onDismiss, title = { Text(text.title) },
        text = { Column(Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState())) {
            SharedAppearanceSettingsCard(state.theme, state.language, "system", state.skin, state.hapticsEnabled, state.keepScreenOn, text,
                onTheme = { appearance.setThemeName(it.name) }, onLanguage = appearance::setLanguage,
                onSkin = { appearance.setSkinName(it.name) }, onHaptics = appearance::setHapticsEnabled,
                onKeepScreenOn = appearance::setKeepScreenOn, close = onDismiss)
            Spacer(Modifier.height(12.dp))
            NativeProductInformation(appearance)
        } },
        confirmButton = { TextButton(onClick = onDismiss) { Text(text.close) } })
}
