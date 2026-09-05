package com.ztransfer.ui

import androidx.compose.runtime.Composable
import com.ztransfer.ui.screen.SettingsControlsText
import com.ztransfer.ui.screen.SettingsTextKey
import com.ztransfer.ui.theme.SkinPreset

/** Original resource values; formatting and settings logic are not duplicated here. */
internal class NativeSettingsPageText(val title: String, val close: String,
    private val labels: Map<SettingsTextKey, String>, private val skins: Map<SkinPreset, String>,
) : SettingsControlsText {
    internal fun value(key: SettingsTextKey): String = labels.getValue(key)
    internal fun skinValue(skin: SkinPreset): String = skins.getValue(skin)
    @Composable override fun label(key: SettingsTextKey): String = value(key)
    @Composable override fun skinLabel(skin: SkinPreset): String = skinValue(skin)
}

internal object NativeSettingsTextCatalog {
    fun forLanguage(languageTag: String): NativeSettingsPageText {
        val parts = languageTag.lowercase().replace('_', '-').split('-')
        return when {
            parts.firstOrNull() != "zh" -> english
            "hant" in parts || ("hans" !in parts && parts.any { it in setOf("tw", "hk", "mo") }) -> traditional
            else -> simplified
        }
    }

    private val english = NativeSettingsPageText(
        title = "Settings", close = "Close",
        labels = mapOf(
            SettingsTextKey.auto_transfer_new_media to "Real-time transfer",
            SettingsTextKey.button_style to "Button style",
            SettingsTextKey.change_directory to "Change folder",
            SettingsTextKey.choose_directory to "Choose folder",
            SettingsTextKey.collapse_burst_photos to "Group bursts",
            SettingsTextKey.columns to "Items per row",
            SettingsTextKey.defer_transfer_start to "Transfer after selecting",
            SettingsTextKey.dir_not_set to "Not set",
            SettingsTextKey.dir_please_set to "Set a transfer folder",
            SettingsTextKey.haptic_feedback to "Haptic feedback",
            SettingsTextKey.keep_screen_on to "Keep screen on",
            SettingsTextKey.language to "Language",
            SettingsTextKey.language_system to "Auto",
            SettingsTextKey.light_dark_mode to "Light & dark",
            SettingsTextKey.organize_transfers_by_date to "Save by day",
            SettingsTextKey.photo_interaction to "Photo list actions",
            SettingsTextKey.setting_off to "Disabled",
            SettingsTextKey.setting_on to "Enabled",
            SettingsTextKey.tap_preview_hold_transfer to "Tap: preview\nHold: transfer",
            SettingsTextKey.tap_transfer_hold_preview to "Tap: transfer\nHold: preview",
            SettingsTextKey.theme_dark to "Dark",
            SettingsTextKey.theme_light to "Light",
            SettingsTextKey.theme_system to "Auto",
            SettingsTextKey.transfer_directory to "Transfer folder",
        ),
        skins = mapOf(
            SkinPreset.FROSTED_GLASS to "Frosted Glass",
            SkinPreset.TITANIUM to "Titanium",
            SkinPreset.WOOD to "Wood",
            SkinPreset.CAMERA_CONTROLS to "Camera Buttons",
        ),
    )

    private val simplified = NativeSettingsPageText(
        title = "设置", close = "关闭",
        labels = mapOf(
            SettingsTextKey.auto_transfer_new_media to "实时传输",
            SettingsTextKey.button_style to "按钮风格",
            SettingsTextKey.change_directory to "更改目录",
            SettingsTextKey.choose_directory to "选择目录",
            SettingsTextKey.collapse_burst_photos to "连拍成组",
            SettingsTextKey.columns to "每行数量",
            SettingsTextKey.defer_transfer_start to "选完再传",
            SettingsTextKey.dir_not_set to "未设置",
            SettingsTextKey.dir_please_set to "请设置传输目录",
            SettingsTextKey.haptic_feedback to "触感反馈",
            SettingsTextKey.keep_screen_on to "屏幕常亮",
            SettingsTextKey.language to "语言",
            SettingsTextKey.language_system to "自动",
            SettingsTextKey.light_dark_mode to "明暗",
            SettingsTextKey.organize_transfers_by_date to "按天保存",
            SettingsTextKey.photo_interaction to "照片列表操作",
            SettingsTextKey.setting_off to "关闭",
            SettingsTextKey.setting_on to "开启",
            SettingsTextKey.tap_preview_hold_transfer to "点击：预览\n长按：传输",
            SettingsTextKey.tap_transfer_hold_preview to "点击：传输\n长按：预览",
            SettingsTextKey.theme_dark to "深色",
            SettingsTextKey.theme_light to "浅色",
            SettingsTextKey.theme_system to "自动",
            SettingsTextKey.transfer_directory to "传输目录",
        ),
        skins = mapOf(
            SkinPreset.FROSTED_GLASS to "毛玻璃",
            SkinPreset.TITANIUM to "钛合金",
            SkinPreset.WOOD to "木纹",
            SkinPreset.CAMERA_CONTROLS to "相机按键",
        ),
    )

    private val traditional = NativeSettingsPageText(
        title = "設定", close = "關閉",
        labels = mapOf(
            SettingsTextKey.auto_transfer_new_media to "即時傳輸",
            SettingsTextKey.button_style to "按鈕風格",
            SettingsTextKey.change_directory to "變更目錄",
            SettingsTextKey.choose_directory to "選擇目錄",
            SettingsTextKey.collapse_burst_photos to "連拍成組",
            SettingsTextKey.columns to "每行數量",
            SettingsTextKey.defer_transfer_start to "選完再傳",
            SettingsTextKey.dir_not_set to "未設定",
            SettingsTextKey.dir_please_set to "請設定傳輸目錄",
            SettingsTextKey.haptic_feedback to "觸覺回饋",
            SettingsTextKey.keep_screen_on to "保持螢幕開啟",
            SettingsTextKey.language to "語言",
            SettingsTextKey.language_system to "自動",
            SettingsTextKey.light_dark_mode to "明暗",
            SettingsTextKey.organize_transfers_by_date to "按天儲存",
            SettingsTextKey.photo_interaction to "照片列表操作",
            SettingsTextKey.setting_off to "關閉",
            SettingsTextKey.setting_on to "開啟",
            SettingsTextKey.tap_preview_hold_transfer to "點擊：預覽\n長按：傳輸",
            SettingsTextKey.tap_transfer_hold_preview to "點擊：傳輸\n長按：預覽",
            SettingsTextKey.theme_dark to "深色",
            SettingsTextKey.theme_light to "淺色",
            SettingsTextKey.theme_system to "自動",
            SettingsTextKey.transfer_directory to "傳輸目錄",
        ),
        skins = mapOf(
            SkinPreset.FROSTED_GLASS to "毛玻璃",
            SkinPreset.TITANIUM to "鈦合金",
            SkinPreset.WOOD to "木紋",
            SkinPreset.CAMERA_CONTROLS to "相機按鍵",
        ),
    )
}
