package com.ztransfer.viewmodel

/** One download's display cadence; byte/progress counters keep their original update rate. */
internal class TransferSpeedDisplaySampler {
    private var publishedAtMs: Long? = null
    private var displayedBytesPerSecond = 0L

    fun sample(bytesPerSecond: Long, nowMs: Long): Long {
        val previousTime = publishedAtMs
        // A task's first real sample is immediate, even after zero-speed preparation samples.
        if (bytesPerSecond > 0L && (previousTime == null || nowMs - previousTime >= 600L)) {
            displayedBytesPerSecond = bytesPerSecond
            publishedAtMs = nowMs
        }
        return displayedBytesPerSecond
    }
}
