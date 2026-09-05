package com.ztransfer.ui

import com.ztransfer.ui.screen.TransferQueueUiText
import com.ztransfer.ui.screen.SignalPillText

/** Original Android text, checked against res/values*. Do not edit translations independently. */
data class NativeQueuePageText(
    val queue: TransferQueueUiText,
    val back: String, val start: String, val pause: String, val pauseScheduled: String, val failed: String,
    val signal: SignalPillText,
    val connectionHelpTitle: String, val connectionHelpMessage: String, val openAppSettings: String,
)

object NativeQueueTextCatalog {
    fun forLanguage(languageTag: String): NativeQueuePageText {
        val parts = languageTag.lowercase().replace('_', '-').split('-')
        return when {
            parts.firstOrNull() != "zh" -> english
            "hant" in parts || ("hans" !in parts && parts.any { it in setOf("tw", "hk", "mo") }) -> traditional
            else -> simplified
        }
    }

    private val english = NativeQueuePageText(
        queue = TransferQueueUiText(
            removeFromQueue = "Remove from queue",
            retryFailedDescription = "Retry failed tasks",
            retryFailedTitle = "Retry failed tasks?",
            retry = "Retry",
            clearQueueDescription = "Clear queue",
            clearQueueTitle = "Clear the queue?",
            clearQueueSubtitle = "Removes all cards; the file currently transferring is not affected",
            clear = "Clear",
            cancel = "Cancel",
        ),
        back = "Back",
        start = "Start transfers",
        pause = "Pause after the current item",
        pauseScheduled = "Will pause after the current item",
        failed = "Transfer failed",
        signal = SignalPillText(
            notConnected = "Camera not connected", usb = "USB",
            staConnected = "STA camera connected", staDisconnected = "Camera not connected",
            signalUnavailable = "Connected; Wi-Fi signal strength unavailable",
        ),
        connectionHelpTitle = "Reconnect the camera",
        connectionHelpMessage = "For AP, join the camera's Wi-Fi in iOS Settings. For STA, keep the camera and phone on the same network. Return to the connection page to reconnect. App Settings below manages permissions, not Wi-Fi selection.",
        openAppSettings = "App Settings",
    )

    private val simplified = NativeQueuePageText(
        queue = TransferQueueUiText(
            removeFromQueue = "移出队列",
            retryFailedDescription = "重试失败任务",
            retryFailedTitle = "重试失败任务？",
            retry = "重试",
            clearQueueDescription = "清空队列",
            clearQueueTitle = "清空队列？",
            clearQueueSubtitle = "移除全部卡片；正在传输的不受影响",
            clear = "清空",
            cancel = "取消",
        ),
        back = "返回",
        start = "开始传输",
        pause = "传完当前任务后暂停",
        pauseScheduled = "将在当前任务完成后暂停",
        failed = "传输失败",
        signal = SignalPillText(
            notConnected = "相机未连接", usb = "USB",
            staConnected = "STA 相机已连接", staDisconnected = "相机未连接",
            signalUnavailable = "相机已连接，Wi-Fi 信号强度不可用",
        ),
        connectionHelpTitle = "重新连接相机",
        connectionHelpMessage = "AP 模式请在 iOS 系统设置中加入相机 Wi-Fi；STA 模式请确保相机与手机在同一网络，再返回连接页重新连接。下方应用设置用于管理权限，不是 Wi-Fi 选择页。",
        openAppSettings = "应用设置",
    )

    private val traditional = NativeQueuePageText(
        queue = TransferQueueUiText(
            removeFromQueue = "移出佇列",
            retryFailedDescription = "重試失敗任務",
            retryFailedTitle = "重試失敗任務？",
            retry = "重試",
            clearQueueDescription = "清空佇列",
            clearQueueTitle = "清空佇列？",
            clearQueueSubtitle = "移除全部卡片；正在傳輸的不受影響",
            clear = "清空",
            cancel = "取消",
        ),
        back = "返回",
        start = "開始傳輸",
        pause = "傳完目前任務後暫停",
        pauseScheduled = "將在目前任務完成後暫停",
        failed = "傳輸失敗",
        signal = SignalPillText(
            notConnected = "相機未連線", usb = "USB",
            staConnected = "STA 相機已連線", staDisconnected = "相機未連線",
            signalUnavailable = "相機已連線，Wi-Fi 訊號強度不可用",
        ),
        connectionHelpTitle = "重新連線相機",
        connectionHelpMessage = "AP 模式請在 iOS 系統設定中加入相機 Wi-Fi；STA 模式請確保相機與手機在同一網路，再返回連線頁重新連線。下方應用設定用於管理權限，不是 Wi-Fi 選擇頁。",
        openAppSettings = "應用設定",
    )
}
