package com.ztransfer.diagnostics

import java.time.Instant

/** Debug-only thumbnail history. Reading the report never issues camera requests or updates UI. */
object ThumbnailDiagnostics {
    const val enabled: Boolean = true
    private const val MAX_MESSAGE_CHARS = 300
    private const val MAX_SECTION_BYTES = 7 * 1024
    private val whitespace = Regex("[\\s\\p{Cc}]+")
    private val lock = Any()
    private val failures = Entries(24)
    private val recent = Entries(48)
    private var sessionDescription = "暂无相机会话"
    private var startedAt = System.currentTimeMillis()
    private var startedNanos = System.nanoTime()

    fun beginSession(description: String) = synchronized(lock) {
        sessionDescription = compact(description, 180)
        startedAt = System.currentTimeMillis()
        startedNanos = System.nanoTime()
        failures.clear()
        recent.clear()
    }

    fun note(message: String, failure: Boolean = false) = synchronized(lock) {
        val elapsedMs = ((System.nanoTime() - startedNanos) / 1_000_000).coerceAtLeast(0L)
        val prefix = if (failure) "failed" else "event"
        val line = "$prefix +${elapsedMs}ms ${compact(message, MAX_MESSAGE_CHARS)}"
        // Normal scan/cache activity must never evict the evidence for a missing thumbnail.
        if (failure) failures.add(line) else recent.add(line)
    }

    fun snapshot(): String = synchronized(lock) {
        buildString {
            appendLine("ZTransfer 缩略图诊断 v1")
            appendLine("session=${Instant.ofEpochMilli(startedAt)} $sessionDescription")
            appendLine("异常记录（${failures.size}，省略 ${failures.omitted}）")
            failures.appendTo(this)
            appendLine()
            appendLine("最近记录（${recent.size}，省略 ${recent.omitted}）")
            recent.appendTo(this)
        }.trimEnd()
    }

    fun clear() = synchronized(lock) {
        failures.clear()
        recent.clear()
    }

    private fun compact(message: String, limit: Int): String =
        message.replace(whitespace, " ").trim().take(limit)

    /** Each section is bounded independently by count and UTF-8 bytes; the report stays under 16 KiB. */
    private class Entries(private val maxCount: Int) {
        private data class Entry(val line: String, val bytes: Int)
        private val entries = ArrayDeque<Entry>()
        private var bytes = 0
        var omitted = 0L
            private set
        val size: Int get() = entries.size

        fun add(line: String) {
            val entry = Entry(line, line.toByteArray(Charsets.UTF_8).size + 1)
            entries.addLast(entry)
            bytes += entry.bytes
            while (entries.size > maxCount || bytes > MAX_SECTION_BYTES) {
                bytes -= entries.removeFirst().bytes
                omitted++
            }
        }

        fun appendTo(report: StringBuilder) {
            if (entries.isEmpty()) report.appendLine("暂无记录")
            else entries.forEach { report.appendLine(it.line) }
        }

        fun clear() {
            entries.clear()
            bytes = 0
            omitted = 0
        }
    }
}
