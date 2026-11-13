package com.ztransfer.diagnostics

import java.time.Instant

/**
 * Debug-only history for EXIF location parsing, place lookup and crop metadata hand-off.
 * Callers must pass only a file name/source tag and diagnostic facts (presence flags, counts,
 * durations or exception class names). Never pass coordinates, place names or exception messages.
 * Reading this history performs no location lookup, file access or camera request.
 */
object PhotoLocationDiagnostics {
    const val enabled: Boolean = true
    private const val MAX_RECORDS = 100
    private const val MAX_RECORD_BYTES = 4 * 1024
    private const val MAX_HISTORY_BYTES = 24 * 1024
    private val whitespace = Regex("[\\s\\p{Cc}]+")
    private val lock = Any()
    private data class Entry(val line: String, val bytes: Int)
    private val entries = ArrayDeque<Entry>()
    private var bytes = 0
    private var omitted = 0L
    private var startedAt = System.currentTimeMillis()
    private var startedNanos = System.nanoTime()

    fun record(source: String, stage: String, detail: String) = synchronized(lock) {
        // Retain file correlation without logging the containing folder or content URI.
        val sourceName = source.substringBefore('?').substringBefore('#')
            .substringAfterLast('/').substringAfterLast('\\')
        val elapsedMs = ((System.nanoTime() - startedNanos) / 1_000_000).coerceAtLeast(0L)
        val line = "+${elapsedMs}ms source=${singleLine(sourceName)} " +
            "stage=${singleLine(stage)} ${singleLine(detail)}"
        val entry = Entry(line, line.toByteArray(Charsets.UTF_8).size + 1)
        // An unexpectedly large record is omitted as a whole, never silently cut mid-stage.
        if (entry.bytes > MAX_RECORD_BYTES) {
            omitted++
            return@synchronized
        }
        entries.addLast(entry)
        bytes += entry.bytes
        while (entries.size > MAX_RECORDS || bytes > MAX_HISTORY_BYTES) {
            bytes -= entries.removeFirst().bytes
            omitted++
        }
    }

    fun report(): String = synchronized(lock) {
        buildString {
            appendLine("ZTransfer 照片位置诊断 v1")
            appendLine("since=${Instant.ofEpochMilli(startedAt)}；不记录坐标或地名")
            appendLine("最近记录（${entries.size}，省略 $omitted）")
            if (entries.isEmpty()) appendLine("暂无记录")
            else entries.forEach { appendLine(it.line) }
        }.trimEnd()
    }

    fun clear() = synchronized(lock) {
        entries.clear()
        bytes = 0
        omitted = 0
        startedAt = System.currentTimeMillis()
        startedNanos = System.nanoTime()
    }

    private fun singleLine(value: String): String = value.replace(whitespace, " ").trim()
}
