package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CameraTransferModelsTest {
    @Test
    fun downloadModelsPreserveLongCountersAndHeaderReference() {
        assertEquals(
            DownloadProgress(
                downloaded = 0x1_0000_0000L,
                total = 0x2_0000_0000L,
                bytesPerSecond = 12_345_678L,
            ),
            DownloadProgress(0x1_0000_0000L, 0x2_0000_0000L, 12_345_678L),
        )

        val prefix = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte())
        val stats = DownloadStats(
            bytes = 0x1_0000_0000L,
            transferredBytes = 4_096L,
            startedAtElapsedMs = 99L,
            headerPrefix = prefix,
        )
        assertTrue(stats.headerPrefix === prefix)
        assertEquals(0x1_0000_0000L, stats.bytes)
        assertEquals(4_096L, stats.transferredBytes)
        assertEquals(99L, stats.startedAtElapsedMs)
        assertNull(DownloadStats(bytes = 0L, transferredBytes = 0L, startedAtElapsedMs = 0L).headerPrefix)
    }
}
