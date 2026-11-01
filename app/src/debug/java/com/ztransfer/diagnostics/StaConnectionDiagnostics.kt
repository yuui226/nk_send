package com.ztransfer.diagnostics

import com.ztransfer.BuildConfig
import java.time.Instant

/** Passive connection timings only. Kept apart from photo logs and never published as UI state. */
object StaConnectionDiagnostics {
    const val enabled = true
    const val NO_SESSION = -1L
    private val history = StaDiagnosticHistory()

    fun begin(): Long = history.begin()
    fun note(sessionId: Long, text: String) = history.note(sessionId, text)
    fun attempt(sessionId: Long, label: String, report: String) = history.attempt(sessionId, label, report)
    fun finish(sessionId: Long, outcome: String) = history.finish(sessionId, outcome)
    fun clear() = history.clear()
    fun snapshot(): String =
        "ZTransfer STA 连接诊断 v1 app=${BuildConfig.VERSION_NAME}(${BuildConfig.VERSION_CODE})\n" +
            "单位 ms；+ 为本次连接开始后的时间。仅记录已有流程，不发送额外请求。\n" + history.snapshot()
}

/** Keep complete attempt blocks; a cancelled discovery cannot overwrite the next discovery. */
internal class StaDiagnosticHistory(
    private val clockMs: () -> Long = { System.nanoTime() / 1_000_000L },
) {
    private data class Session(
        val id: Long,
        val startedMs: Long,
        val startedAt: String,
        val blocks: ArrayDeque<String> = ArrayDeque(),
        var characters: Int = 0,
        var omitted: Int = 0,
        var completion: String? = null,
    )

    private var nextId = 0L
    private var current: Session? = null

    @Synchronized
    fun begin(): Long = (++nextId).also { id ->
        current = Session(id, clockMs(), Instant.now().toString())
    }

    @Synchronized
    fun note(sessionId: Long, text: String) {
        val session = writableSession(sessionId) ?: return
        append(session, "+${elapsed(session)}ms $text")
    }

    @Synchronized
    fun attempt(sessionId: Long, label: String, report: String) {
        val session = writableSession(sessionId) ?: return
        if (report.isBlank()) return
        append(session, "+${elapsed(session)}ms attempt [$label]\n${report.trimEnd()}")
    }

    @Synchronized
    fun finish(sessionId: Long, outcome: String) {
        val session = writableSession(sessionId) ?: return
        session.completion = "+${elapsed(session)}ms result=${outcome.take(160)}"
    }

    @Synchronized
    fun clear() { current = null }

    @Synchronized
    fun snapshot(): String {
        val session = current ?: return "暂无 STA 连接记录"
        return buildString {
            appendLine("session=${session.id} started=${session.startedAt}")
            if (session.omitted > 0) appendLine("省略较早记录 ${session.omitted} 块；保留的 attempt 均为完整内容")
            session.blocks.forEach { appendLine(it) }
            append(session.completion ?: "+${elapsed(session)}ms result=running")
        }
    }

    private fun writableSession(id: Long): Session? = current?.takeIf { it.id == id && it.completion == null }
    private fun elapsed(session: Session): Long = (clockMs() - session.startedMs).coerceAtLeast(0L)

    private fun append(session: Session, block: String) {
        // Unexpectedly large input is omitted as a whole, never presented as a complete truncated attempt.
        if (block.length > MAX_CHARACTERS) {
            session.omitted++
            return
        }
        while (session.blocks.isNotEmpty() &&
            (session.characters + block.length > MAX_CHARACTERS || session.blocks.size >= MAX_BLOCKS)
        ) {
            session.characters -= session.blocks.removeFirst().length
            session.omitted++
        }
        session.blocks.addLast(block)
        session.characters += block.length
    }

    private companion object {
        const val MAX_CHARACTERS = 64 * 1024
        const val MAX_BLOCKS = 160
    }
}
