package com.ztransfer.ui.screen

import com.ztransfer.protocol.LiveViewPacket

/** Bounded, opt-in capture. Never retains a packet/JPEG or issues a camera command. */
internal class PostureDiagnostic {
    private data class Sample(val at: Long, val operation: Int, val header: ByteArray)
    private val steps = mutableListOf<List<Sample>>()
    private val pending = mutableListOf<Sample>()
    private var source: Any? = null
    private var description = ""
    private var active = false
    private var started = 0L
    private var invalid = false
    @Synchronized fun count() = steps.size
    @Synchronized fun reset() {
        active = false; steps.clear(); pending.clear(); source = null; description = ""
    }
    @Synchronized fun begin(camera: Any, info: String, now: Long): Boolean {
        if (steps.size >= 5 || (source != null && (source !== camera || description != info))) return false
        source = camera; description = info; started = now; invalid = false
        pending.clear(); active = true
        return true
    }
    @Synchronized fun offer(camera: Any, packet: LiveViewPacket) {
        if (!active) return
        if (camera !== source) { invalid = true; return }
        val at = packet.receivedAtElapsedMs
        if (at < started || at - started > 2100 || pending.size >= 8) return
        if (pending.isNotEmpty() && at - pending.last().at < 250) return
        val end = packet.jpegOffset
        if (end !in 1..4096 || end + 2 >= packet.bytes.size ||
            packet.bytes[end] != 0xFF.toByte() || packet.bytes[end + 1] != 0xD8.toByte()) {
            invalid = true; return
        }
        val baseline = steps.firstOrNull()?.firstOrNull() ?: pending.firstOrNull()
        if (baseline != null && (baseline.operation != packet.operation || baseline.header.size != end)) {
            invalid = true; return
        }
        pending += Sample(at, packet.operation, packet.bytes.copyOfRange(0, end))
    }
    @Synchronized fun finish(): Boolean {
        active = false
        val valid = !invalid && pending.size >= 5 && pending.last().at - pending.first().at >= 1000
        if (valid) steps += pending.toList()
        pending.clear()
        return valid
    }
    @Synchronized fun cancel() { active = false; pending.clear() }
    @Synchronized fun report(): String = if (steps.isEmpty()) "" else buildString {
        appendLine("posture diagnostic v1; completed=${steps.size}/5; header-only; byte offsets are payload-relative")
        appendLine(description)
        val names = listOf("level", "pitch_up_20", "pitch_down_20", "roll_left_20", "roll_right_20")
        steps.forEachIndexed { index, samples ->
            appendLine("pose=${names[index]} samples=${samples.size}")
            samples.forEach { sample ->
                appendLine("t=${sample.at} op=0x${sample.operation.toString(16)} headerBytes=${sample.header.size}")
                val hex = "0123456789abcdef"
                sample.header.forEach { byte ->
                    val value = byte.toInt() and 255
                    append(hex[value ushr 4]); append(hex[value and 15])
                }
                appendLine()
            }
        }
    }
}
