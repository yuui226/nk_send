package com.ztransfer.protocol

/** Timing of existing handshake steps only; never sends requests or publishes UI state. */
internal class StaConnectionTrace(private val nanoTime: () -> Long = System::nanoTime) {
    private val lines = ArrayList<String>()
    private var started = nanoTime()
    private var previous = started
    private var omitted = 0

    fun clear() {
        lines.clear()
        omitted = 0
        started = nanoTime()
        previous = started
    }

    operator fun plusAssign(message: String) {
        val now = nanoTime()
        val elapsed = ((now - started) / 1_000_000L).coerceAtLeast(0L)
        val delta = ((now - previous) / 1_000_000L).coerceAtLeast(0L)
        previous = now
        // Keep both the beginning and the final outcome if a peer floods the event channel.
        if (lines.size == 256) {
            lines.removeAt(128)
            omitted++
        }
        lines += "+${elapsed}ms Δ${delta}ms $message"
    }

    fun report(): String = buildString {
        appendLine("+ms=本次连接起点；Δms=距上一条记录（含请求、解析或等待）")
        lines.forEachIndexed { index, line ->
            if (index == 128 && omitted > 0) appendLine("中间省略 $omitted 条")
            appendLine(line)
        }
    }.trimEnd()
}
