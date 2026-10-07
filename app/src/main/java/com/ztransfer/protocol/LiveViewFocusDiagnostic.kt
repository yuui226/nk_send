package com.ztransfer.protocol

/** Passive, bounded sampling of packets already fetched by live view. No camera commands. */
class LiveViewFocusDiagnostic {
    private val lines = ArrayDeque<String>()
    private var startMs = 0L
    private var lastSampleMs = Long.MIN_VALUE
    private var count = 0
    private var lastState: String? = null
    private var changes = 0
    private var displayState = "UI not observed"
    private val markedSamples = ArrayDeque<String>()
    private var lastSample: String? = null
    private var baseline: String? = null
    var running = false
        private set

    fun start(nowMs: Long, description: String) {
        lines.clear()
        markedSamples.clear()
        lastSample = null
        baseline = null
        lines.add("Focus diagnostic v2 ${description.take(320)}")
        lines.add("60s; changes only; ms; rawWHXY=width,height,centerX,centerY.")
        startMs = nowMs
        lastSampleMs = Long.MIN_VALUE
        count = 0
        lastState = null
        changes = 0
        displayState = "UI not observed"
        running = true
    }

    fun stop(reason: String = "stopped") {
        if (running) lines.add("end=$reason samples=$count changes=$changes")
        running = false
    }

    /** Called by the UI, independently of packet reception. No state writes or per-frame logs. */
    fun display(state: String) {
        if (!running) return
        val previousKind = displayState.substringBefore(" age=").substringBefore(" boxPx=")
        val next = state.take(180)
        val nextKind = next.substringBefore(" age=").substringBefore(" boxPx=")
        displayState = next
        if (previousKind != nextKind) append("UI $next")
    }

    fun mark(nowMs: Long, text: String) {
        if (running) {
            if (markedSamples.size >= 8) markedSamples.removeFirst()
            markedSamples.add("mark +${nowMs - startMs} ${text.take(48)} UI=$displayState state=${lastState?.substringAfter("af=") ?: "no frame"}")
        }
    }

    fun sample(packet: LiveViewPacket, context: String) {
        if (!running) return
        val now = packet.receivedAtElapsedMs
        if (now < startMs) return
        if (now - startMs >= 60_000) { stop("60s"); return }
        if (lastSampleMs != Long.MIN_VALUE && now - lastSampleMs < 200) return
        lastSampleMs = now
        count++
        val bytes = packet.bytes
        val header = packet.jpegOffset
        fun u8(i: Int) = if (i < header && i < bytes.size) bytes[i].toInt() and 255 else -1
        fun u16(i: Int) = if (u8(i) < 0 || u8(i + 1) < 0) -1 else (u8(i) shl 8) or u8(i + 1)
        val meta = packet.metadata
        val selectedIndex = u8(45)
        val tableEnd = when (header) { 512 -> 380; 1024 -> 816; else -> 0 }
        val selectedOffset = 48 + selectedIndex * 8
        val selectedRaw = if (selectedIndex >= 0 && selectedIndex < u8(44) &&
            selectedOffset + 8 <= tableEnd && selectedOffset + 8 <= bytes.size
        ) (selectedOffset until selectedOffset + 8 step 2).joinToString(",") { u16(it).toString() }
        else "none"
        val state = "${context.take(48)} op=${packet.operation.toString(16)} h=$header " +
            "v=${u16(0)}.${u16(2)} whole=${u16(16)}x${u16(18)} " +
            "area=${u16(20)}x${u16(22)}@${u16(24)},${u16(26)} " +
            "af=${u8(42)} n=${u8(44)} valid=${meta?.focusFrames?.size ?: 0} idx=$selectedIndex " +
            "${meta?.focusFrameStatus ?: "unsupported-header"} rawWHXY=$selectedRaw"
        // Repeated frames do not consume report space. Capture resumes on any state/geometry change.
        if (state == lastState) return
        lastState = state
        changes++
        val sample = "+${now - startMs} $state"
        lastSample = sample
        if (baseline == null) baseline = sample else append(sample)
    }

    private fun append(line: String) {
        // Keep report header, discard only oldest samples. Never retain image bytes.
        if (lines.size >= 80) {
            val title = lines.removeFirst()
            val note = lines.removeFirst()
            lines.removeFirst()
            lines.addFirst(note)
            lines.addFirst(title)
        }
        lines.add(line)
    }

    fun report(): String {
        val all = lines.toList()
        if (all.isEmpty()) return ""
        val heading = all.take(2).joinToString("\n") + "\n" +
            listOfNotNull(baseline?.let { "baseline $it" }).joinToString("\n") + "\n" +
            markedSamples.joinToString("\n") + "\nUI=$displayState\n"
        val samples = all.drop(2)
        val report = heading + samples.joinToString("\n")
        if (report.length <= 6000) return report
        val prefix = heading + "[older changes omitted]\n"
        val tail = ArrayDeque<String>()
        var length = prefix.length
        for (line in all.drop(2).asReversed()) {
            if (length + line.length + 1 > 6000) break
            tail.addFirst(line)
            length += line.length + 1
        }
        return prefix + tail.joinToString("\n")
    }
}
