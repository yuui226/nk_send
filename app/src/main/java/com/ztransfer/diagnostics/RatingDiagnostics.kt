package com.ztransfer.diagnostics

/** Bounded rating diagnostics shared by protocol and the filter UI. */
object RatingDiagnostics {
    private const val MAX_ENTRIES = 120
    private const val MAX_CHARS = 16_000
    private val whitespace = Regex("\\s+")
    private val lock = Any()
    private val entries = ArrayDeque<String>()

    fun note(message: String) = synchronized(lock) {
        entries.addLast(message.replace(whitespace, " ").take(260))
        while (entries.size > MAX_ENTRIES || entries.sumOf { it.length + 1 } > MAX_CHARS) {
            entries.removeFirstOrNull() ?: break
        }
    }

    fun snapshot(): String = synchronized(lock) {
        if (entries.isEmpty()) "评级筛选：暂无诊断记录"
        else "ZTransfer 评级筛选诊断\n" + entries.joinToString("\n")
    }
}
