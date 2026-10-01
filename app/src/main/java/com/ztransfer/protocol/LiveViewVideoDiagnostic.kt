package com.ztransfer.protocol

/** Passive, bounded diagnostics. No camera I/O; no payload retained outside this call. */
internal object LiveViewVideoDiagnostic {
    @Volatile private var enabled = false
    @Volatile var latest: String = "awaiting fresh frame"
        private set
    private var lastSampleNs = 0L

    @Synchronized fun start() {
        latest = "awaiting fresh frame"
        lastSampleNs = 0L
        enabled = true
    }
    @Synchronized fun stop() { enabled = false }

    fun capture(payload: ByteArray, headerSize: Int, operation: Int) {
        if (!enabled) return
        synchronized(this) {
            if (!enabled) return
            val now = System.nanoTime()
            if (lastSampleNs != 0L && now - lastSampleNs < 1_000_000_000L) return
            lastSampleNs = now
            val end = minOf(headerSize, payload.size, 1024).coerceAtLeast(0)
            fun hex(from: Int, limit: Int): String = buildString {
                for (i in from until limit.coerceAtMost(end)) {
                    val b = payload[i].toInt() and 255
                    append("0123456789ABCDEF"[b ushr 4])
                    append("0123456789ABCDEF"[b and 15])
                }
            }
            val tail = when (headerSize) { 512 -> 352; 1024 -> 800; else -> 0 }
            latest = "frame op=${operation.toString(16)} header=$headerSize sampleNs=$now\n" +
                "head[0..47]=${hex(0, 48)}\n" +
                "tail[$tail..${end - 1}]=${hex(tail, end)}"
        }
    }
}

/** One read only: does not switch the normal live-view operation or camera mode. */
internal suspend fun NikonCamera.probeLegacyVideoTime(): String {
    val (response, data) = labCommand(Lab.NK_GET_LIVE_VIEW_IMG)
    val payload = data ?: byteArrayOf()
    val jpeg = (0 until minOf(payload.size - 2, 2048).coerceAtLeast(0)).firstOrNull {
        payload[it] == 0xff.toByte() && payload[it + 1] == 0xd8.toByte() &&
            payload[it + 2] == 0xff.toByte()
    }
    val summary = "legacy op=9203 resp=${response.toString(16)} bytes=${payload.size} header=$jpeg"
    if (response != 0x2001 || jpeg != 384) return "$summary; unsupported layout, no interpretation"
    fun u16(offset: Int) = ((payload[offset].toInt() and 255) shl 8) or
        (payload[offset + 1].toInt() and 255)
    return "$summary\nremaining words[64,66]=${u16(64)},${u16(66)} recording[68]=${payload[68].toInt() and 255}; compare with camera time"
}
