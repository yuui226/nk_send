package com.ztransfer.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.ztransfer.protocol.CameraFileInfo
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Frozen indexed identity, not permission to dereference an arbitrary URL. */
class NativeOriginalActionItem(val file: CameraFileInfo, val locator: String, val originalName: String, val originalSize: Long) {
    constructor(file: CameraFileInfo, locator: String) : this(file, locator, file.fileName, file.size)
}
interface NativeOriginalActionCompletion {
    fun complete(succeededIndices: IntArray, failedCount: Int, cancelled: Boolean, message: String?)
}
interface NativeOriginalActionsPlatform {
    fun performOriginalAction(action: String, items: List<NativeOriginalActionItem>, completion: NativeOriginalActionCompletion)
    fun cancelOriginalActions()
}
internal data class NativeOriginalActionState(val busy: Boolean = false, val revision: Long = 0,
    val succeeded: Set<String> = emptySet(), val failedCount: Int = 0, val cancelled: Boolean = false, val message: String? = null)

class NativeOriginalActionsModel {
    private var platform: NativeOriginalActionsPlatform? = null
    private var closed = false
    private var request = 0L
    private val mutableState = MutableStateFlow(NativeOriginalActionState())
    internal val state = mutableState.asStateFlow()
    fun attach(platform: NativeOriginalActionsPlatform): Boolean {
        if (closed || this.platform != null) return false
        this.platform = platform
        return true
    }
    internal fun perform(action: String, items: List<NativeOriginalActionItem>): Boolean {
        val owner = platform ?: return false
        if (closed || mutableState.value.busy || action !in setOf("photos", "share", "files") ||
            items.isEmpty() || items.size > 500 || items.map { it.locator }.toSet().size != items.size) return false
        val frozen = items.toList()
        val token = ++request
        mutableState.value = NativeOriginalActionState(busy = true, revision = token)
        owner.performOriginalAction(action, frozen, object : NativeOriginalActionCompletion {
            override fun complete(succeededIndices: IntArray, failedCount: Int, cancelled: Boolean, message: String?) {
                if (closed || token != request || !mutableState.value.busy) return
                val indices = succeededIndices.toSet()
                val valid = indices.size == succeededIndices.size && indices.all { it in frozen.indices } &&
                    failedCount in 0..(frozen.size - indices.size)
                mutableState.value = NativeOriginalActionState(revision = token,
                    succeeded = if (valid) indices.mapTo(LinkedHashSet()) { frozen[it].locator } else emptySet(),
                    failedCount = if (valid) failedCount else frozen.size,
                    cancelled = cancelled, message = message)
            }
        })
        return true
    }
    fun close() {
        if (closed) return
        closed = true; request++
        platform?.cancelOriginalActions(); platform = null
        mutableState.value = NativeOriginalActionState()
    }
}

internal fun nativeActionText(language: String, cn: String, en: String, tw: String = cn): String =
    when { !language.startsWith("zh", true) -> en
        language.contains("Hant", true) || language.contains("TW", true) || language.contains("HK", true) -> tw
        else -> cn }

/** Export selection only; camera admission remains the original single/date/burst interaction. */
@Composable
internal fun NativeOriginalActionsDialog(model: NativeOriginalActionsModel, originals: List<NativeOriginalActionItem>,
    language: String, onDismiss: () -> Unit) {
    val state by model.state.collectAsState()
    val chosen = remember(originals) { mutableStateMapOf<String, Boolean>() }
    fun text(cn: String, en: String, tw: String = cn) = nativeActionText(language, cn, en, tw)
    LaunchedEffect(state.revision, state.busy) {
        if (!state.busy) state.succeeded.forEach(chosen::remove)
    }
    AlertDialog(onDismissRequest = { if (!state.busy) onDismiss() },
        title = { Text(text("已存原片", "Saved originals")) },
        text = {
            Column {
                Text(text("只操作已保存的原文件，不下载、不删相机照片。每次最多500项。", "Saved originals only; no camera downloads or deletion. Up to 500 per operation.", "只操作已儲存的原檔，不下載、不刪相機照片。每次最多500項。"))
                Row {
                    TextButton(enabled = !state.busy, onClick = {
                        chosen.clear(); originals.take(500).forEach { chosen[it.locator] = true }
                    }) { Text(text("选择本批", "Select batch", "選擇本批")) }
                    TextButton(enabled = !state.busy, onClick = chosen::clear) { Text(text("取消选择", "Clear selection", "取消選擇")) }
                }
                LazyColumn(Modifier.heightIn(max = 260.dp)) {
                    items(originals, key = { it.locator }) { item ->
                        Row {
                            Checkbox(checked = chosen[item.locator] == true, enabled = !state.busy,
                                onCheckedChange = { value ->
                                    if (!value) chosen.remove(item.locator)
                                    else if (chosen.size < 500) chosen[item.locator] = true
                                })
                            Text(item.originalName, Modifier.weight(1f).padding(top = 12.dp))
                        }
                    }
                }
                if (originals.isEmpty()) Text(text("当前筛选下没有可用原片。", "No saved originals in this filter.", "目前篩選下沒有可用原片。"))
                if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                state.message?.let { Text(it) }
                if (!state.busy && state.revision > 0) Text(
                    text("已确认 ", "Confirmed ", "已確認 ") + state.succeeded.size +
                        text("，失败 ", "; failed ", "，失敗 ") + state.failedCount +
                        if (state.cancelled) text("；已取消未完成部分。", "; remaining work cancelled.", "；已取消未完成部分。") else "")
                listOf("photos" to text("加入图库", "Add to Photos", "加入圖庫"),
                    "share" to text("系统分享", "Share", "系統分享"), "files" to text("导出到文件", "Export to Files", "匯出至檔案")).forEach { (action, label) ->
                    TextButton(enabled = !state.busy && chosen.isNotEmpty(), onClick = {
                        model.perform(action, originals.filter { chosen[it.locator] == true })
                    }) { Text(label) }
                }
            }
        },
        confirmButton = { TextButton(enabled = !state.busy, onClick = onDismiss) { Text(text("关闭", "Close", "關閉")) } })
}
