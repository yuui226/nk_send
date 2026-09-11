"""Queue copy is derived from Android's three original language tables, never translated here."""
import json
from pathlib import Path
import xml.etree.ElementTree as ET

FIELDS = (
    ('removeFromQueue', 'cd_remove_from_queue'), ('retryFailedDescription', 'cd_retry_failed'),
    ('retryFailedTitle', 'retry_failed_title'), ('retry', 'retry'),
    ('clearQueueDescription', 'cd_clear_queue'), ('clearQueueTitle', 'clear_queue_title'),
    ('clearQueueSubtitle', 'clear_queue_subtitle'), ('clear', 'clear'), ('cancel', 'cancel'),
)
EXTRA = (('back', 'cd_back'), ('start', 'cd_start_transfers'), ('pause', 'cd_pause_after_current'),
         ('pauseScheduled', 'cd_pause_after_current_scheduled'), ('failed', 'transfer_failed'))

NATIVE_CONNECTION_COPY = {
    'english': ('Connected; Wi-Fi signal strength unavailable', 'Reconnect the camera',
        "For AP, join the camera's Wi-Fi in iOS Settings. For STA, keep the camera and phone on the same network. Return to the connection page to reconnect. App Settings below manages permissions, not Wi-Fi selection.", 'App Settings'),
    'simplified': ('相机已连接，Wi-Fi 信号强度不可用', '重新连接相机',
        'AP 模式请在 iOS 系统设置中加入相机 Wi-Fi；STA 模式请确保相机与手机在同一网络，再返回连接页重新连接。下方应用设置用于管理权限，不是 Wi-Fi 选择页。', '应用设置'),
    'traditional': ('相機已連線，Wi-Fi 訊號強度不可用', '重新連線相機',
        'AP 模式請在 iOS 系統設定中加入相機 Wi-Fi；STA 模式請確保相機與手機在同一網路，再返回連線頁重新連線。下方應用設定用於管理權限，不是 Wi-Fi 選擇頁。', '應用設定'),
}


def expected_catalog(root: Path):
    result = '''package com.ztransfer.ui

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

'''
    for name, folder in (('english', 'values'), ('simplified', 'values-zh'), ('traditional', 'values-b+zh+Hant')):
        values = {x.attrib['name']: ''.join(x.itertext()) for x in ET.parse(root / 'app/src/main/res' / folder / 'strings.xml').getroot() if x.tag == 'string'}
        def quoted(key):
            return json.dumps(values[key], ensure_ascii=False).replace('$', '\\$')
        result += f'    private val {name} = NativeQueuePageText(\n        queue = TransferQueueUiText(\n'
        result += ''.join(f'            {field} = {quoted(key)},\n' for field, key in FIELDS)
        result += '        ),\n' + ''.join(f'        {field} = {quoted(key)},\n' for field, key in EXTRA)
        unknown, title, message, settings = (json.dumps(x, ensure_ascii=False) for x in NATIVE_CONNECTION_COPY[name])
        result += ('        signal = SignalPillText(\n'
            f'            notConnected = {quoted("camera_not_connected")}, usb = {quoted("connection_usb")},\n'
            f'            staConnected = {quoted("sta_signal_connected")}, staDisconnected = {quoted("camera_not_connected")},\n'
            f'            signalUnavailable = {unknown},\n        ),\n'
            f'        connectionHelpTitle = {title},\n        connectionHelpMessage = {message},\n        openAppSettings = {settings},\n    )\n\n')
    return result.rstrip() + '\n}\n'
