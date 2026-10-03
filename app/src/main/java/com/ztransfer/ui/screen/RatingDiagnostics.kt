package com.ztransfer.ui.screen

/** Small, session-local diagnostic buffer copied only on a long press of the rating control. */
internal object RatingDiagnostics {
    private const val MAX_ENTRIES = 96
    private const val MAX_CHARS = 12_000
    private val lock = Any()
    private val entries = ArrayDeque<String>()

    fun note(message: String) = synchronized(lock) {
        entries.addLast(message.replace(Regex("\\s+"), " ").take(240))
        while (entries.size > MAX_ENTRIES || entries.sumOf { it.length + 1 } > MAX_CHARS) {
            entries.removeFirstOrNull() ?: break
        }
    }

    fun snapshot(): String = synchronized(lock) {
        if (entries.isEmpty()) "评级筛选：暂无诊断记录"
        else "ZTransfer 评级筛选诊断\\n" + entries.joinToString("\\n")
    }
}
