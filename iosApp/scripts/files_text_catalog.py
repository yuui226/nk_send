"""Original Android grid text plus explicit, temporary native integration-status copy."""
from pathlib import Path
import json
import xml.etree.ElementTree as ET

FIELDS = {'unknownDate': 'unknown_date', 'expandLabel': 'cd_expand', 'collapseLabel': 'cd_collapse',
    'transferGroupLabel': 'cd_transfer_group', 'burstAccessibilityTemplate': 'burst_collection_a11y',
    'burstCountTemplate': 'burst_collection_count', 'protectedLabel': 'filter_protected',
    'loadingLabel': 'loading_more', 'loadingFiles': 'loading_file_list', 'empty': 'no_photos_on_camera',
    'columns': 'columns', 'collapseBursts': 'collapse_burst_photos',
    'noMatches': 'no_photos_match_filter', 'clearFilters': 'clear_filters'}
EXTRA = {
 'english': ['Refresh', 'Queue', 'Original-file browser: full preview and the complete settings page are still being connected.',
  'Refresh failed; the previous list was retained.', 'Some metadata could not be read; the previous list was retained.',
  'The camera changed during scanning. Refresh again; the previous list was retained.', 'Invalid catalog result; the previous list was retained.',
  'Could not add these files. Check the queue before retrying.', 'Some files were added. Check the queue before retrying.',
  'Full preview is not yet connected to this shared page.'],
 'simplified': ['刷新', '队列', '原片浏览接线中：完整预览和完整设置页尚未接入。',
  '刷新失败，已保留原列表。', '部分元数据读取失败，已保留原列表。', '扫描期间相机目录有变化，请重新刷新；已保留原列表。',
  '目录结果无效，已保留原列表。', '未能加入这些文件，请查看队列后再重试。', '部分文件已加入，请查看队列后再重试。', '完整预览尚未接入此共享页面。'],
 'traditional': ['重新整理', '佇列', '原片瀏覽串接中：完整預覽和完整設定頁尚未接入。',
  '重新整理失敗，已保留原列表。', '部分中繼資料讀取失敗，已保留原列表。', '掃描期間相機目錄有變化，請重新整理；已保留原列表。',
  '目錄結果無效，已保留原列表。', '未能加入這些檔案，請查看佇列後再重試。', '部分檔案已加入，請查看佇列後再重試。', '完整預覽尚未接入此共用頁面。'],
}
INDEX_FAILURE = {
    'english': 'Could not read the saved-original index. Previous results were retained; refresh to retry.',
    'simplified': '未能读取已保存原片索引，已保留上次结果；可刷新重试。',
    'traditional': '未能讀取已儲存原片索引，已保留上次結果；可重新整理重試。',
}
INDEX_PENDING = {
    'english': 'Saved-original index is not ready; the Pending filter is temporarily unavailable.',
    'simplified': '已保存原片索引尚未就绪，暂不能使用“未传输”筛选。',
    'traditional': '已儲存原片索引尚未就緒，暫不能使用「未傳輸」篩選。',
}

PREFERENCES_FAILURE = {
    'english': 'Browse preferences could not be read or saved. Changes apply only to this page; existing stored data was retained.',
    'simplified': '浏览偏好读取或保存失败，本次改动仅在当前页面生效；原存储数据已保留。',
    'traditional': '瀏覽偏好讀取或儲存失敗，本次變更僅在目前頁面生效；原儲存資料已保留。',
}

def expected_files_catalog(root: Path):
    s = '''package com.ztransfer.ui

import androidx.compose.runtime.Composable
import com.ztransfer.catalog.UNKNOWN_CAPTURE_DATE_GROUP_KEY
import com.ztransfer.ui.screen.ThumbnailGridText

/** Generated/checked against Android values*. Native integration messages are explicitly separate. */
internal data class NativeFilesPageText(
'''
    s += ''.join(f'    val {name}: String,\n' for name in FIELDS)
    s += '''    val refresh: String, val queue: String, val integrationStatus: String,
    val notices: List<String>, val indexFailed: String, val indexPending: String, val preferencesFailed: String,
) : ThumbnailGridText {
    @Composable override fun date(value: String): String = when {
        value == UNKNOWN_CAPTURE_DATE_GROUP_KEY -> unknownDate
        value.length < 8 -> value
        else -> "${value.substring(0, 4)}-${value.substring(4, 6)}-${value.substring(6, 8)}"
    }
    @Composable override fun expand(collapsed: Boolean): String = if (collapsed) expandLabel else collapseLabel
    @Composable override fun transferGroup(): String = transferGroupLabel
    @Composable override fun burstAccessibility(count: Int): String = burstAccessibilityTemplate.replace("%1\\$d", "$count")
    @Composable override fun burstCount(count: Int): String = burstCountTemplate.replace("%1\\$d", "$count")
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

'''
    def quote(text): return json.dumps(text, ensure_ascii=False).replace('$', '\\$')
    for language, folder in [('english', 'values'), ('simplified', 'values-zh'), ('traditional', 'values-b+zh+Hant')]:
        values = {n.attrib['name']: ''.join(n.itertext()) for n in ET.parse(root/'app/src/main/res'/folder/'strings.xml').getroot() if n.tag == 'string'}
        s += f'    private val {language} = NativeFilesPageText(\n'
        s += ''.join(f'        {name} = {quote(values[key])},\n' for name,key in FIELDS.items())
        extra=EXTRA[language]
        s += f'        preferencesFailed = {quote(PREFERENCES_FAILURE[language])},\n'
        s += f'        indexFailed = {quote(INDEX_FAILURE[language])},\n'
        s += f'        indexPending = {quote(INDEX_PENDING[language])},\n'
        s += f'        refresh = {quote(extra[0])}, queue = {quote(extra[1])}, integrationStatus = {quote(extra[2])},\n'
        s += '        notices = listOf(\n'+''.join('            '+quote(x)+',\n' for x in extra[3:])+'        ),\n    )\n\n'
    return s.rstrip()+'\n}\n'
