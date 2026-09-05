package com.ztransfer.ui

import androidx.compose.runtime.Composable
import com.ztransfer.catalog.UNKNOWN_CAPTURE_DATE_GROUP_KEY
import com.ztransfer.ui.screen.ThumbnailGridText

/** Generated/checked against Android values*. Native integration messages are explicitly separate. */
internal data class NativeFilesPageText(
    val unknownDate: String,
    val expandLabel: String,
    val collapseLabel: String,
    val transferGroupLabel: String,
    val burstAccessibilityTemplate: String,
    val burstCountTemplate: String,
    val protectedLabel: String,
    val loadingLabel: String,
    val loadingFiles: String,
    val empty: String,
    val columns: String,
    val collapseBursts: String,
    val noMatches: String,
    val clearFilters: String,
    val refresh: String, val queue: String, val integrationStatus: String,
    val notices: List<String>, val indexFailed: String, val indexPending: String, val preferencesFailed: String,
) : ThumbnailGridText {
    @Composable override fun date(value: String): String = when {
        value == UNKNOWN_CAPTURE_DATE_GROUP_KEY -> unknownDate
        value.length < 8 -> value
        else -> "${value.substring(0, 4)}-${value.substring(4, 6)}-${value.substring(6, 8)}"
    }
    @Composable override fun expand(collapsed: Boolean): String = if (collapsed) expandLabel else collapseLabel
    @Composable override fun transferGroup(): String = transferGroupLabel
    @Composable override fun burstAccessibility(count: Int): String = burstAccessibilityTemplate.replace("%1\$d", "$count")
    @Composable override fun burstCount(count: Int): String = burstCountTemplate.replace("%1\$d", "$count")
    @Composable override fun protectedPhoto(): String = protectedLabel
    @Composable override fun loading(): String = loadingLabel
    fun notice(value: NativeFilesNotice): String? = if (value == NativeFilesNotice.NONE) null else notices[value.ordinal - 1]
}

internal object NativeFilesTextCatalog {
    fun forLanguage(languageTag: String): NativeFilesPageText {
        val parts = languageTag.lowercase().replace('_', '-').split('-')
        return when {
            parts.firstOrNull() != "zh" -> english
            "hant" in parts || ("hans" !in parts && parts.any { it in setOf("tw", "hk", "mo") }) -> traditional
            else -> simplified
        }
    }

    private val english = NativeFilesPageText(
        unknownDate = "Unknown date",
        expandLabel = "Expand",
        collapseLabel = "Collapse",
        transferGroupLabel = "Transfer this group",
        burstAccessibilityTemplate = "Burst collection, %1\$d photos",
        burstCountTemplate = "%1\$d",
        protectedLabel = "Protected",
        loadingLabel = "Loading more…",
        loadingFiles = "Loading file list…",
        empty = "No photos on the camera",
        columns = "Items per row",
        collapseBursts = "Group bursts",
        noMatches = "No photos match the filter",
        clearFilters = "Clear filters",
        preferencesFailed = "Browse preferences could not be read or saved. Changes apply only to this page; existing stored data was retained.",
        indexFailed = "Could not read the saved-original index. Previous results were retained; refresh to retry.",
        indexPending = "Saved-original index is not ready; the Pending filter is temporarily unavailable.",
        refresh = "Refresh", queue = "Queue", integrationStatus = "Original-file browser: full preview and the complete settings page are still being connected.",
        notices = listOf(
            "Refresh failed; the previous list was retained.",
            "Some metadata could not be read; the previous list was retained.",
            "The camera changed during scanning. Refresh again; the previous list was retained.",
            "Invalid catalog result; the previous list was retained.",
            "Could not add these files. Check the queue before retrying.",
            "Some files were added. Check the queue before retrying.",
            "Full preview is not yet connected to this shared page.",
        ),
    )

    private val simplified = NativeFilesPageText(
        unknownDate = "未知日期",
        expandLabel = "展开",
        collapseLabel = "收起",
        transferGroupLabel = "传输整组",
        burstAccessibilityTemplate = "连拍合集，共 %1\$d 张",
        burstCountTemplate = "%1\$d",
        protectedLabel = "保护",
        loadingLabel = "正在加载更多…",
        loadingFiles = "正在获取文件列表…",
        empty = "相机中没有照片",
        columns = "每行数量",
        collapseBursts = "连拍成组",
        noMatches = "没有符合筛选的照片",
        clearFilters = "清除筛选",
        preferencesFailed = "浏览偏好读取或保存失败，本次改动仅在当前页面生效；原存储数据已保留。",
        indexFailed = "未能读取已保存原片索引，已保留上次结果；可刷新重试。",
        indexPending = "已保存原片索引尚未就绪，暂不能使用“未传输”筛选。",
        refresh = "刷新", queue = "队列", integrationStatus = "原片浏览接线中：完整预览和完整设置页尚未接入。",
        notices = listOf(
            "刷新失败，已保留原列表。",
            "部分元数据读取失败，已保留原列表。",
            "扫描期间相机目录有变化，请重新刷新；已保留原列表。",
            "目录结果无效，已保留原列表。",
            "未能加入这些文件，请查看队列后再重试。",
            "部分文件已加入，请查看队列后再重试。",
            "完整预览尚未接入此共享页面。",
        ),
    )

    private val traditional = NativeFilesPageText(
        unknownDate = "未知日期",
        expandLabel = "展開",
        collapseLabel = "收起",
        transferGroupLabel = "傳輸整組",
        burstAccessibilityTemplate = "連拍合集，共 %1\$d 張",
        burstCountTemplate = "%1\$d",
        protectedLabel = "保護",
        loadingLabel = "正在載入更多…",
        loadingFiles = "正在取得檔案清單…",
        empty = "相機中沒有照片",
        columns = "每行數量",
        collapseBursts = "連拍成組",
        noMatches = "沒有符合篩選的照片",
        clearFilters = "清除篩選",
        preferencesFailed = "瀏覽偏好讀取或儲存失敗，本次變更僅在目前頁面生效；原儲存資料已保留。",
        indexFailed = "未能讀取已儲存原片索引，已保留上次結果；可重新整理重試。",
        indexPending = "已儲存原片索引尚未就緒，暫不能使用「未傳輸」篩選。",
        refresh = "重新整理", queue = "佇列", integrationStatus = "原片瀏覽串接中：完整預覽和完整設定頁尚未接入。",
        notices = listOf(
            "重新整理失敗，已保留原列表。",
            "部分中繼資料讀取失敗，已保留原列表。",
            "掃描期間相機目錄有變化，請重新整理；已保留原列表。",
            "目錄結果無效，已保留原列表。",
            "未能加入這些檔案，請查看佇列後再重試。",
            "部分檔案已加入，請查看佇列後再重試。",
            "完整預覽尚未接入此共用頁面。",
        ),
    )
}
