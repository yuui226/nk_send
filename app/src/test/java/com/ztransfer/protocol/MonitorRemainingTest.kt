package com.ztransfer.protocol

import org.junit.Assert.*
import org.junit.Test

class MonitorRemainingTest {
    private fun put32(bytes: ByteArray, offset: Int, value: Long) {
        repeat(4) { bytes[offset + it] = (value ushr (24 - it * 8)).toByte() }
    }
    private fun packet(size: Int, millis: Long, recording: Int): ByteArray = ByteArray(size).also {
        it[1] = 1
        put32(it, 8, size.toLong())
        val offset = if (size == 512) 380 else 816
        put32(it, offset, millis)
        it[offset + 12] = recording.toByte()
    }
    @Test fun remainingMovieTimeUsesVideoBlockInBothHeaderLayouts() {
        for (size in listOf(512, 1024)) {
            assertEquals(125_000L, parseLiveViewRemainingVideoTime(packet(size, 125_000, 0), size))
            assertEquals(0L, parseLiveViewRemainingVideoTime(packet(size, 0, 1), size))
        }
    }
    @Test fun unknownTimeOrStructureDoesNotBecomeAVisibleCountdown() {
        assertNull(parseLiveViewRemainingVideoTime(packet(512, 0, 0), 512))
        assertNull(parseLiveViewRemainingVideoTime(packet(512, 0xFFFFFFFF, 1), 512))
        assertNull(parseLiveViewRemainingVideoTime(packet(512, 1000, 2), 512))
        assertNull(parseLiveViewRemainingVideoTime(packet(512, 1000, 1).also { it[1] = 2 }, 512))
        assertNull(parseLiveViewRemainingVideoTime(ByteArray(20), 512))
        assertNull(parseLiveViewRemainingVideoTime(ByteArray(1024), 384))
    }
}
