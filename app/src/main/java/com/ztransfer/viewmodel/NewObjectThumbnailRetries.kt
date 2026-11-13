package com.ztransfer.viewmodel

/** Main-thread, session-local retry budget for objects announced after the initial camera scan. */
internal class NewObjectThumbnailRetries {
    private data class Entry(var failures: Int = 0, var retryAtMs: Long? = null)
    private val entries = HashMap<Int, Entry>()
    private val delaysMs = longArrayOf(300L, 900L, 1_800L)

    fun register(handle: Int) { entries.putIfAbsent(handle, Entry()) }
    fun isRetry(handle: Int): Boolean = (entries[handle]?.failures ?: 0) > 0
    fun canAttempt(handle: Int, nowMs: Long): Boolean =
        entries[handle]?.retryAtMs?.let { nowMs >= it } ?: true

    /** Null means no automatic retry remains; callers may apply their normal negative-cache rule. */
    fun failed(handle: Int, nowMs: Long): Long? {
        val entry = entries[handle] ?: return null
        entry.retryAtMs?.takeIf { it > nowMs }?.let { return it }
        entry.retryAtMs = null
        if (entry.failures >= delaysMs.size) {
            entries.remove(handle)
            return null
        }
        return (nowMs + delaysMs[entry.failures++]).also { entry.retryAtMs = it }
    }

    fun nextRetryAtMs(): Long? {
        var next: Long? = null
        entries.values.forEach { entry ->
            val deadline = entry.retryAtMs
            val previous = next
            if (deadline != null && (previous == null || deadline < previous)) next = deadline
        }
        return next
    }

    /** Consumes only timer deadlines, retaining the finite attempt budget until success/final failure. */
    fun takeDue(nowMs: Long): Set<Int> = buildSet {
        entries.forEach { (handle, entry) ->
            if (entry.retryAtMs?.let { it <= nowMs } == true) {
                entry.retryAtMs = null
                add(handle)
            }
        }
    }

    fun remove(handle: Int): Boolean = entries.remove(handle)?.retryAtMs != null
    fun clear() { entries.clear() }
}
