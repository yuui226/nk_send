package com.ztransfer.diagnostics

import android.os.SystemClock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.time.Instant
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong

/** Debug 专用的效果图生成耗时探针；只记录时长和诊断摘要，不读取或保留照片内容。 */
object PhotoGenerationProbe {
    const val enabled: Boolean = true
    const val NO_SESSION: Long = -1L
    private const val MAX_SESSIONS = 12
    private const val MAX_NOTES = 24

    private data class DiagnosticNote(
        val elapsedMs: Long,
        val category: String,
        val message: String,
    )

    private data class Stage(
        val name: String,
        val durationMs: Long,
        val finishedOffsetMs: Long,
        val detail: String,
        val heapMiB: Long,
    )

    private data class Session(
        val id: Long,
        val sourceName: String,
        val configuration: String,
        val startedAtElapsedMs: Long,
        val stages: MutableList<Stage> = arrayListOf(),
        var outcome: String = "running",
        var totalMs: Long? = null,
    )

    private val ids = AtomicLong(0L)
    private val lock = Any()
    private val sessions = linkedMapOf<Long, Session>()
    private val notes = arrayListOf<DiagnosticNote>()
    private val _version = MutableStateFlow(0)
    val version: StateFlow<Int> = _version.asStateFlow()

    fun begin(sourceName: String, configuration: String): Long {
        val id = ids.incrementAndGet()
        synchronized(lock) {
            sessions[id] = Session(
                id = id,
                sourceName = sourceName,
                configuration = configuration,
                startedAtElapsedMs = SystemClock.elapsedRealtime(),
            )
            while (sessions.size > MAX_SESSIONS) {
                sessions.remove(sessions.keys.first())
            }
        }
        bump()
        return id
    }

    fun stage(sessionId: Long, name: String, durationMs: Long, detail: String = "") {
        if (sessionId == NO_SESSION) return
        synchronized(lock) {
            val session = sessions[sessionId] ?: return
            session.stages += Stage(
                name = name,
                durationMs = durationMs.coerceAtLeast(0L),
                finishedOffsetMs = SystemClock.elapsedRealtime() - session.startedAtElapsedMs,
                detail = detail,
                heapMiB = usedHeapMiB(),
            )
        }
        bump()
    }

    fun finish(sessionId: Long, outcome: String, totalMs: Long) {
        if (sessionId == NO_SESSION) return
        synchronized(lock) {
            val session = sessions[sessionId] ?: return
            session.outcome = outcome
            session.totalMs = totalMs.coerceAtLeast(0L)
        }
        bump()
    }

    /**
     * Shares the existing bottom Debug log with frame diagnostics only.  STA/protocol notes stay
     * suppressed so enabling this focused trace cannot flood the timing window.
     */
    fun note(category: String, message: String) {
        if (!category.startsWith("FRAME-")) return
        synchronized(lock) {
            notes += DiagnosticNote(
                elapsedMs = SystemClock.elapsedRealtime(),
                category = category,
                message = message,
            )
            while (notes.size > MAX_NOTES) notes.removeAt(0)
        }
        bump()
    }

    /** Adds a session-relative marker while keeping the global note format backwards compatible. */
    fun frameNote(sessionId: Long, category: String, message: String) {
        if (sessionId == NO_SESSION) {
            note(category, message)
            return
        }
        val offset = synchronized(lock) {
            sessions[sessionId]?.let { SystemClock.elapsedRealtime() - it.startedAtElapsedMs }
        }
        note(
            category = category,
            message = "session=$sessionId offsetMs=${offset ?: -1} $message",
        )
    }

    fun clear() {
        synchronized(lock) {
            sessions.clear()
            notes.clear()
        }
        bump()
    }

    fun displayLines(): List<String> = synchronized(lock) {
        buildList {
            if (sessions.isEmpty() && notes.isEmpty()) {
                add("暂无记录：连接一次 STA，或传输一张启用了滤镜/边框的 JPG")
                return@buildList
            }
            if (notes.isNotEmpty()) {
                add("STA / 协议诊断")
                notes.forEach { note ->
                    add("[${note.category}] t=${note.elapsedMs}ms")
                    note.message.lineSequence().forEach { add("  $it") }
                }
            }
            if (notes.isNotEmpty() && sessions.isNotEmpty()) add("")
            sessions.values.toList().asReversed().forEachIndexed { index, session ->
                if (index > 0) add("")
                add(
                    "#${session.id} ${session.sourceName}  ${session.outcome}  " +
                        "总计=${duration(session.totalMs)}",
                )
                add(session.configuration)
                session.stages.forEach { stage ->
                    add(
                        "  +${stage.finishedOffsetMs}ms  ${stage.name}=${stage.durationMs}ms" +
                            "  javaHeap=${stage.heapMiB}MiB" +
                            stage.detail.takeIf(String::isNotBlank)?.let { "  $it" }.orEmpty(),
                    )
                }
            }
        }
    }

    fun report(): String = synchronized(lock) {
        buildString {
            appendLine("ZTransfer debug timing/protocol log v2")
            appendLine("generated=${Instant.now()}")
            appendLine("clock=SystemClock.elapsedRealtime")
            appendLine("note=total stages include their child stages; do not sum every line")
            appendLine()
            displayLinesLocked().forEach(::appendLine)
        }
    }

    private fun displayLinesLocked(): List<String> = buildList {
        if (sessions.isEmpty() && notes.isEmpty()) {
            add("<no sessions>")
            return@buildList
        }
        notes.forEach { note ->
            add("note category=${note.category} elapsedMs=${note.elapsedMs}")
            note.message.lineSequence().forEach { add("  $it") }
        }
        sessions.values.forEach { session ->
            add(
                "session=${session.id} source=${session.sourceName} outcome=${session.outcome} " +
                    "totalMs=${session.totalMs ?: -1} config=${session.configuration}",
            )
            session.stages.forEach { stage ->
                add(
                    "stage=${stage.name} durationMs=${stage.durationMs} " +
                        "finishedOffsetMs=${stage.finishedOffsetMs} javaHeapMiB=${stage.heapMiB} " +
                        "detail=${stage.detail}",
                )
            }
        }
    }

    private fun usedHeapMiB(): Long {
        val runtime = Runtime.getRuntime()
        return (runtime.totalMemory() - runtime.freeMemory()) / (1024L * 1024L)
    }

    private fun duration(value: Long?): String = value?.let {
        "%.1fs".format(Locale.US, it / 1000.0)
    } ?: "运行中"

    private fun bump() {
        _version.update { it + 1 }
    }
}
