package com.ztransfer.gps

import java.time.Instant

/** Small in-memory ring buffer for troubleshooting real-camera pairing without logcat access. */
internal object GpsDiagnostics {
    private const val MAX_ENTRIES = 80
    private val entries = ArrayDeque<String>()

    @Synchronized
    fun record(message: String) {
        if (entries.size >= MAX_ENTRIES) entries.removeFirst()
        entries.addLast("${Instant.now()} $message")
    }

    @Synchronized
    fun snapshot(): String = entries.joinToString("\n").ifBlank { "GPS: no events" }
}
