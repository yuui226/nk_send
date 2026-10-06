package com.ztransfer.diagnostics

/** Bounded rating diagnostics shared by protocol and the filter UI. */
object RatingDiagnostics {
    // Rating diagnostics are opt-in.  The normal filter pass keeps only its short summary;
    // protocol timings are collected only by the explicit RAW probe in the debug panel.
    private const val MAX_ENTRIES = 48
    private const val MAX_CHARS = 8_000
    private val whitespace = Regex("\\s+")
    private val lock = Any()
    private val entries = ArrayDeque<String>()
    private var enabled = false
    private var verbose = false

    data class CaptureState internal constructor(
        val enabled: Boolean,
        val verbose: Boolean,
    )

    /** Enables the short, user-facing scan summary. Disabled state does no work on note(). */
    fun setEnabled(value: Boolean) = synchronized(lock) {
        enabled = value
        verbose = false
        if (!value) entries.clear()
    }

    /** Starts a bounded detailed capture for an explicit debug probe. */
    fun beginProbe(): CaptureState = synchronized(lock) {
        val previous = CaptureState(enabled, verbose)
        enabled = true
        verbose = true
        entries.clear()
        previous
    }

    /** Restores the rating scan's previous capture state after a debug probe. */
    fun restore(state: CaptureState) = synchronized(lock) {
        enabled = state.enabled
        verbose = state.verbose
        if (!enabled) entries.clear()
    }

    fun note(message: String) = synchronized(lock) {
        if (!enabled) return@synchronized
        appendLocked(message)
    }

    /** Protocol timing lines are useful for a deliberate probe, but too noisy for normal scans. */
    fun detail(message: String) = synchronized(lock) {
        if (!enabled || !verbose) return@synchronized
        appendLocked(message)
    }

    private fun appendLocked(message: String) {
        entries.addLast(message.replace(whitespace, " ").take(260))
        while (entries.size > MAX_ENTRIES || entries.sumOf { it.length + 1 } > MAX_CHARS) {
            entries.removeFirstOrNull() ?: break
        }
    }

    fun snapshot(): String = synchronized(lock) {
        if (entries.isEmpty()) "评级筛选：暂无诊断记录"
        else "ZTransfer 评级筛选诊断\n" + entries.joinToString("\n")
    }

    fun clear() = synchronized(lock) { entries.clear() }
}
