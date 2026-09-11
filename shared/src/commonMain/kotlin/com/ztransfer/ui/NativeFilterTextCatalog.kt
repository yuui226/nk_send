package com.ztransfer.ui

import androidx.compose.runtime.Composable
import com.ztransfer.ui.screen.FilterOverlayText
import com.ztransfer.ui.screen.FilterTextKey

/** Generated/checked against Android values*. Only the numbered slot placeholder is substituted. */
internal class NativeFilterText(private val values: List<String>) : FilterOverlayText {
    @Composable override fun label(key: FilterTextKey, slot: Int): String = value(key, slot)
    fun value(key: FilterTextKey, slot: Int = 0): String = values[key.ordinal].replace("%1\$d", "$slot")
}

internal object NativeFilterTextCatalog {
    fun forLanguage(languageTag: String): NativeFilterText {
        val parts = languageTag.lowercase().replace('_', '-').split('-')
        return when {
            parts.firstOrNull() != "zh" -> english
            "hant" in parts || ("hans" !in parts && parts.any { it in setOf("tw", "hk", "mo") }) -> traditional
            else -> simplified
        }
    }

    private val english = NativeFilterText(listOf(
        "Other", // filter_other
        "Filter", // filter_title
        "File type", // filter_section_file_type
        "All", // filter_all
        "Status", // filter_section_status
        "Protected", // filter_protected
        "Burst", // burst_label
        "Pending", // filter_untransferred
        "Storage card", // filter_section_storage
        "Card %1\$d", // filter_storage_slot
        "Date taken", // filter_section_date
        "Date", // filter_date
        "Clear", // clear
        "Back", // cd_back
        "Date range", // date_range
        "Start", // date_start
        "End", // date_end
        "Done", // done
        "Year", // date_year
        "Month", // date_month
        "Day", // date_day
    ))

    private val simplified = NativeFilterText(listOf(
        "其他", // filter_other
        "筛选", // filter_title
        "文件类型", // filter_section_file_type
        "全部", // filter_all
        "状态", // filter_section_status
        "保护", // filter_protected
        "连拍", // burst_label
        "未传", // filter_untransferred
        "存储卡", // filter_section_storage
        "卡 %1\$d", // filter_storage_slot
        "拍摄日期", // filter_section_date
        "日期", // filter_date
        "清空", // clear
        "返回", // cd_back
        "日期范围", // date_range
        "开始", // date_start
        "结束", // date_end
        "完成", // done
        "年", // date_year
        "月", // date_month
        "日", // date_day
    ))

    private val traditional = NativeFilterText(listOf(
        "其他", // filter_other
        "篩選", // filter_title
        "檔案類型", // filter_section_file_type
        "全部", // filter_all
        "狀態", // filter_section_status
        "保護", // filter_protected
        "連拍", // burst_label
        "未傳", // filter_untransferred
        "記憶卡", // filter_section_storage
        "卡 %1\$d", // filter_storage_slot
        "拍攝日期", // filter_section_date
        "日期", // filter_date
        "清空", // clear
        "返回", // cd_back
        "日期範圍", // date_range
        "開始", // date_start
        "結束", // date_end
        "完成", // done
        "年", // date_year
        "月", // date_month
        "日", // date_day
    ))
}
