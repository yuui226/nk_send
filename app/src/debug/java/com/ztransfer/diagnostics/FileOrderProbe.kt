package com.ztransfer.diagnostics

import android.os.SystemClock
import com.ztransfer.protocol.NikonCamera
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.time.Instant
import java.util.Locale

/** Debug 专用的文件发现顺序探测器；只保存元数据，不读取任何额外照片内容。 */
object FileOrderProbe {
    const val enabled: Boolean = true

    private data class FileRow(
        val handle: Int,
        val fileName: String,
        val captureDate: String?,
        val extension: String,
        val storageIds: Set<Int>,
        val size: Long,
        val protected: Boolean,
        val observedAtMs: Long,
        val batchNumber: Int,
    )

    private data class ThumbnailRow(
        val sequence: Int,
        val handle: Int,
        val lane: String,
        val startedAtMs: Long,
        val finishedAtMs: Long? = null,
        val outcome: String = "running",
        val byteCount: Int? = null,
    )

    private val lock = Any()
    private val startedAtMs = SystemClock.elapsedRealtime()
    private var connectionStartedAtMs = startedAtMs
    private var transport = "not-started"
    private var manufacturer = "unknown"
    private var model = "unknown"
    private var deviceVersion = "unknown"
    private var operations: Set<Int> = emptySet()
    private var storageIds: List<Int> = emptyList()
    private var scanDescription = "not-started"
    private var scanOutcome = "running"
    private var batchCount = 0
    private var totalObjectInfoMs = 0L
    private val rawHandlesByStorage = linkedMapOf<Int, List<Int>>()
    private val rawHandleDurationsMs = linkedMapOf<Int, Long>()
    private var scheduledHandles: List<Int> = emptyList()
    private val fileRows = linkedMapOf<Int, FileRow>()
    private val missingHandles = linkedSetOf<Int>()
    private var nextThumbnailSequence = 0
    private val thumbnailRows = linkedMapOf<Int, ThumbnailRow>()
    private val notes = arrayListOf<String>()

    private val _version = MutableStateFlow(0)
    val version: StateFlow<Int> = _version.asStateFlow()

    fun beginConnection(kind: String) {
        synchronized(lock) {
            connectionStartedAtMs = SystemClock.elapsedRealtime()
            transport = kind
            manufacturer = "unknown"
            model = "unknown"
            deviceVersion = "unknown"
            operations = emptySet()
            storageIds = emptyList()
            scanDescription = "not-started"
            scanOutcome = "waiting"
            batchCount = 0
            totalObjectInfoMs = 0L
            rawHandlesByStorage.clear()
            rawHandleDurationsMs.clear()
            scheduledHandles = emptyList()
            fileRows.clear()
            missingHandles.clear()
            nextThumbnailSequence = 0
            thumbnailRows.clear()
            notes.clear()
            notes += "connection begin: $kind"
        }
        bump()
    }

    fun recordCapabilities(
        manufacturer: String,
        model: String,
        deviceVersion: String,
        operations: Set<Int>,
    ) {
        synchronized(lock) {
            this.manufacturer = manufacturer.ifBlank { "unknown" }
            this.model = model.ifBlank { "unknown" }
            this.deviceVersion = deviceVersion.ifBlank { "unknown" }
            this.operations = operations.toSortedSet()
            notes += "DeviceInfo parsed: ops=${operations.size}"
        }
        bump()
    }

    fun recordCapabilityFailure(message: String) {
        synchronized(lock) { notes += "!! DeviceInfo probe failed: $message" }
        bump()
    }

    fun beginScan(description: String) {
        synchronized(lock) {
            scanDescription = description
            scanOutcome = "running"
            batchCount = 0
            totalObjectInfoMs = 0L
            storageIds = emptyList()
            rawHandlesByStorage.clear()
            rawHandleDurationsMs.clear()
            scheduledHandles = emptyList()
            fileRows.clear()
            missingHandles.clear()
            nextThumbnailSequence = 0
            thumbnailRows.clear()
            notes += "scan begin: $description"
        }
        bump()
    }

    fun recordStorageIds(ids: List<Int>) {
        synchronized(lock) { storageIds = ids.toList() }
        bump()
    }

    fun recordRawHandles(storageId: Int, handles: List<Int>, elapsedMs: Long) {
        synchronized(lock) {
            rawHandlesByStorage[storageId] = handles.toList()
            rawHandleDurationsMs[storageId] = elapsedMs
        }
        bump()
    }

    fun recordScheduledHandles(handles: List<Int>) {
        synchronized(lock) { scheduledHandles = handles.toList() }
        bump()
    }

    fun appendScheduledHandles(handles: List<Int>) {
        synchronized(lock) {
            val existing = scheduledHandles.toHashSet()
            scheduledHandles = scheduledHandles + handles.filter { existing.add(it) }
        }
        bump()
    }

    fun recordObjectInfoBatch(
        requestedHandles: List<Int>,
        files: List<NikonCamera.FileInfo>,
        elapsedMs: Long,
    ) {
        synchronized(lock) {
            batchCount++
            totalObjectInfoMs += elapsedMs
            val returned = files.asSequence().mapTo(HashSet()) { it.handle }
            requestedHandles.filterNotTo(missingHandles) { it in returned }
            val now = SystemClock.elapsedRealtime() - connectionStartedAtMs
            files.forEach { file ->
                fileRows[file.handle] = FileRow(
                    handle = file.handle,
                    fileName = file.fileName,
                    captureDate = file.captureDate,
                    extension = file.extension,
                    storageIds = file.storageIds,
                    size = file.size,
                    protected = file.isProtected,
                    observedAtMs = now,
                    batchNumber = batchCount,
                )
            }
        }
        bump()
    }

    fun beginThumbnail(handle: Int, lane: String): Int {
        val sequence: Int
        synchronized(lock) {
            sequence = nextThumbnailSequence++
            thumbnailRows[sequence] = ThumbnailRow(
                sequence = sequence,
                handle = handle,
                lane = lane,
                startedAtMs = SystemClock.elapsedRealtime() - connectionStartedAtMs,
            )
        }
        bump()
        return sequence
    }

    fun finishThumbnail(sequence: Int, outcome: String, byteCount: Int?) {
        synchronized(lock) {
            val started = thumbnailRows[sequence] ?: return
            thumbnailRows[sequence] = started.copy(
                finishedAtMs = SystemClock.elapsedRealtime() - connectionStartedAtMs,
                outcome = outcome,
                byteCount = byteCount,
            )
        }
        bump()
    }

    fun finishScan(outcome: String) {
        synchronized(lock) {
            scanOutcome = outcome
            notes += "scan end: $outcome"
        }
        bump()
    }

    fun addNote(message: String) {
        synchronized(lock) { notes += message }
        bump()
    }

    fun clear() {
        beginConnection("cleared; reconnect camera to probe")
    }

    fun displayLines(maxRows: Int = 140): List<String> = synchronized(lock) {
        buildList {
            addAll(summaryLinesLocked())
            add("")
            add("按 App 调度顺序显示的前 $maxRows 个文件")
            val scheduledIndex = scheduledHandles.withIndex().associate { it.value to it.index }
            fileRows.values
                .sortedBy { scheduledIndex[it.handle] ?: Int.MAX_VALUE }
                .take(maxRows)
                .forEach { add(formatFileRow(it, scheduledIndex[it.handle])) }
        }
    }

    fun fullReport(): String = synchronized(lock) {
        buildString {
            appendLine("ZTransfer file-order probe v1")
            appendLine("generated=${Instant.now()}")
            summaryLinesLocked().forEach(::appendLine)
            appendLine()
            appendLine("[operations]")
            appendLine(operations.joinToString(" ") { hex4(it) }.ifEmpty { "<none>" })
            appendLine()
            appendLine("[raw handle arrays]")
            if (rawHandlesByStorage.isEmpty()) appendLine("<none>")
            rawHandlesByStorage.forEach { (storageId, handles) ->
                appendLine(
                    "storage=${hex8(storageId)} count=${handles.size} " +
                        "elapsed=${rawHandleDurationsMs[storageId] ?: -1}ms"
                )
                appendLine(handles.joinToString(",") { hex8(it) })
            }
            appendLine()
            appendLine("[scheduled handle order]")
            appendLine(scheduledHandles.joinToString(",") { hex8(it) }.ifEmpty { "<none>" })
            appendLine()
            appendLine("[object info rows in scheduled order]")
            appendLine("scheduledIndex\tbatch\tobservedMs\thandle\tcaptureDate\text\tstorageIds\tsize\tprotected\tfileName")
            val scheduledIndex = scheduledHandles.withIndex().associate { it.value to it.index }
            fileRows.values
                .sortedBy { scheduledIndex[it.handle] ?: Int.MAX_VALUE }
                .forEach { row ->
                    append(scheduledIndex[row.handle] ?: -1).append('\t')
                    append(row.batchNumber).append('\t')
                    append(row.observedAtMs).append('\t')
                    append(hex8(row.handle)).append('\t')
                    append(row.captureDate ?: "<none>").append('\t')
                    append(row.extension).append('\t')
                    append(row.storageIds.joinToString(",") { hex8(it) }).append('\t')
                    append(row.size).append('\t')
                    append(row.protected).append('\t')
                    appendLine(row.fileName.replace('\t', ' '))
                }
            appendLine()
            appendLine("[missing/non-file handles]")
            appendLine(missingHandles.joinToString(",") { hex8(it) }.ifEmpty { "<none>" })
            appendLine()
            appendLine("[remote thumbnail requests in actual camera-channel start order]")
            appendLine("sequence\tlane\tstartMs\tdurationMs\thandle\tcaptureDate\text\toutcome\tbytes\tfileName")
            thumbnailRows.values.forEach { thumb ->
                val file = fileRows[thumb.handle]
                append(thumb.sequence).append('\t')
                append(thumb.lane).append('\t')
                append(thumb.startedAtMs).append('\t')
                append(thumb.finishedAtMs?.minus(thumb.startedAtMs) ?: -1).append('\t')
                append(hex8(thumb.handle)).append('\t')
                append(file?.captureDate ?: "<unknown>").append('\t')
                append(file?.extension ?: "<unknown>").append('\t')
                append(thumb.outcome).append('\t')
                append(thumb.byteCount ?: -1).append('\t')
                appendLine(file?.fileName ?: "<unknown>")
            }
            if (thumbnailRows.isEmpty()) appendLine("<none>")
            appendLine()
            appendLine("[notes]")
            notes.forEach(::appendLine)
        }
    }

    /** 手机回传默认使用的精简报告；保留定性所需首尾样本，避免 Word/聊天工具截断全文。 */
    fun compactReport(): String = synchronized(lock) {
        buildString {
            appendLine("ZTransfer file-order probe compact v2")
            appendLine("generated=${Instant.now()}")
            summaryLinesLocked().forEach(::appendLine)
            appendLine()
            appendLine("[raw handle samples]")
            rawHandlesByStorage.forEach { (storageId, handles) ->
                appendLine(
                    "storage=${hex8(storageId)} count=${handles.size} " +
                        "elapsed=${rawHandleDurationsMs[storageId] ?: -1}ms"
                )
                appendLine("first=${handleSample(handles.take(30))}")
                appendLine("last=${handleSample(handles.takeLast(30))}")
            }
            if (rawHandlesByStorage.isEmpty()) appendLine("<none>")
            appendLine()
            appendLine("[actual scheduled samples]")
            appendLine("count=${scheduledHandles.size}")
            appendLine("first=${handleSample(scheduledHandles.take(40))}")
            appendLine("last=${handleSample(scheduledHandles.takeLast(40))}")
            appendLine()
            appendLine("[notes]")
            notes.forEach(::appendLine)
        }
    }

    private fun summaryLinesLocked(): List<String> {
        val rowsByHandle = fileRows.toMap()
        val lines = arrayListOf<String>()
        lines += "连接：$transport  相机：$manufacturer $model  固件：$deviceVersion"
        lines += "扫描：$scanDescription  结果：$scanOutcome"
        lines += "能力：ops=${operations.size}  GetObjectPropList(0x9805)=" +
            if (0x9805 in operations) "YES" else "NO/未探测"
        lines += "卡槽：${storageIds.joinToString { hex8(it) }.ifEmpty { "<none>" }}"
        lines += "handle=${scheduledHandles.size}  ObjectInfo=${fileRows.size}  " +
            "批次=$batchCount  ObjectInfo总耗时=${totalObjectInfoMs}ms  未返回=${missingHandles.size}"
        lines += orderStats("App实际枚举顺序", scheduledHandles, rowsByHandle)
        rawHandlesByStorage.forEach { (storageId, handles) ->
            lines += orderStats("相机原序 ${hex8(storageId)}", handles, rowsByHandle)
            lines += orderStats("相机反序 ${hex8(storageId)}", handles.asReversed(), rowsByHandle)
        }
        if (fileRows.isNotEmpty()) {
            val descending = fileRows.keys.sortedDescending()
            val ascending = descending.asReversed()
            lines += orderStats("数值降序复核", descending, rowsByHandle)
            lines += orderStats("数值升序复核", ascending, rowsByHandle)
            lines += formatRunStats(scheduledHandles, rowsByHandle)
            lines += pairStats(scheduledHandles, rowsByHandle)
            val counts = fileRows.values.groupingBy { it.extension }.eachCount()
                .entries.sortedByDescending { it.value }
                .joinToString(" ") { "${it.key.ifEmpty { "<none>" }}=${it.value}" }
            lines += "格式计数：$counts"
        }
        if (thumbnailRows.isNotEmpty()) {
            val thumbnailHandles = thumbnailRows.values.map { it.handle }
            val outcomes = thumbnailRows.values.groupingBy { it.outcome }.eachCount()
                .entries.sortedByDescending { it.value }
                .joinToString(" ") { "${it.key}=${it.value}" }
            val lanes = thumbnailRows.values.groupingBy { it.lane }.eachCount()
                .entries.sortedByDescending { it.value }
                .joinToString(" ") { "${it.key}=${it.value}" }
            lines += "远程缩略图：${thumbnailRows.size}  $lanes  $outcomes"
            lines += orderStats("GetThumb实际开始", thumbnailHandles, rowsByHandle)
            lines += "GetThumb " + formatRunStats(thumbnailHandles, rowsByHandle)
        } else {
            lines += "远程缩略图：尚无请求（可能已全部命中手机缓存）"
        }
        notes.takeLast(4).forEach { lines += it }
        return lines
    }

    private fun orderStats(
        label: String,
        handles: List<Int>,
        rows: Map<Int, FileRow>,
    ): String {
        val ordered = handles.mapNotNull(rows::get).filter { validDate(it.captureDate) != null }
        if (ordered.size < 2) return "$label：有效样本不足(${ordered.size})"
        var newestFirst = 0
        var oldestFirst = 0
        var equal = 0
        for (index in 0 until ordered.lastIndex) {
            val current = validDate(ordered[index].captureDate)!!
            val next = validDate(ordered[index + 1].captureDate)!!
            when {
                current > next -> newestFirst++
                current < next -> oldestFirst++
                else -> equal++
            }
        }
        val directionalPairs = newestFirst + oldestFirst
        if (directionalPairs == 0) {
            return "$label：没有跨时间样本  同时刻=$equal  样本=${ordered.size}"
        }
        return "$label：新→旧=${percent(newestFirst, directionalPairs)}  " +
            "旧→新=${percent(oldestFirst, directionalPairs)}  " +
            "同时刻=$equal  样本=${ordered.size}"
    }

    private fun formatRunStats(handles: List<Int>, rows: Map<Int, FileRow>): String {
        val exts = handles.mapNotNull(rows::get).map { it.extension.ifEmpty { "<none>" } }
        if (exts.isEmpty()) return "格式连续段：无样本"
        var runs = 1
        var current = 1
        var longest = 1
        var longestExt = exts.first()
        for (index in 1 until exts.size) {
            if (exts[index] == exts[index - 1]) {
                current++
            } else {
                runs++
                current = 1
            }
            if (current > longest) {
                longest = current
                longestExt = exts[index]
            }
        }
        return "格式连续段：runs=$runs  最长=$longest($longestExt)  " +
            "前40=${exts.take(40).joinToString(" ")}"
    }

    private fun pairStats(handles: List<Int>, rows: Map<Int, FileRow>): String {
        val position = handles.withIndex().associate { it.value to it.index }
        val pairs = rows.values.groupBy { row ->
            "${row.captureDate.orEmpty()}|${row.fileName.substringBeforeLast('.', row.fileName).lowercase()}"
        }.values.filter { group -> group.map { it.extension }.distinct().size > 1 }
        if (pairs.isEmpty()) return "同名多格式配对：未发现"
        val gaps = pairs.mapNotNull { group ->
            val positions = group.mapNotNull { position[it.handle] }
            if (positions.size < 2) null else positions.max() - positions.min()
        }
        if (gaps.isEmpty()) return "同名多格式配对：${pairs.size} 组，位置样本不足"
        return "同名多格式配对：${gaps.size} 组  相邻=${gaps.count { it == 1 }}  " +
            "最大间隔=${gaps.max()}  平均间隔=${"%.1f".format(Locale.US, gaps.average())}"
    }

    private fun formatFileRow(row: FileRow, scheduledIndex: Int?): String =
        "#${scheduledIndex ?: -1} b${row.batchNumber} +${row.observedAtMs}ms " +
            "${hex8(row.handle)} ${row.captureDate ?: "<none>"} ${row.extension} " +
            "${row.storageIds.joinToString(",") { hex8(it) }} ${row.fileName}"

    private fun validDate(value: String?): String? =
        value?.takeIf { it.length >= 8 && it.take(8).all(Char::isDigit) }

    private fun percent(value: Int, total: Int): String =
        "%.1f%%".format(Locale.US, value * 100.0 / total.coerceAtLeast(1))

    private fun hex4(value: Int): String = "0x%04X".format(Locale.US, value and 0xFFFF)
    private fun hex8(value: Int): String = "0x%08X".format(Locale.US, value)
    private fun handleSample(handles: List<Int>): String =
        handles.joinToString(",") { hex8(it) }.ifEmpty { "<none>" }

    private fun bump() {
        _version.update { it + 1 }
    }
}
