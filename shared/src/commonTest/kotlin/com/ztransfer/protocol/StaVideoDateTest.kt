package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class StaVideoDateTest {
    private fun header(seconds: Long, version: Int): ByteArray {
        val width = if (version == 0) 4 else 8
        return ByteArray(15 + width).also { b ->
            "mvhd".encodeToByteArray().copyInto(b, 3)
            b[7] = version.toByte()
            repeat(width) { b[11 + it] = (seconds ushr ((width - it - 1) * 8)).toByte() }
        }
    }
    @Test fun bothQuickTimeVersionsPreserveSecondsAndIgnorePrefixPosition() {
        for (v in 0..1) assertEquals(1_800_000_000L, staDirectVideoCaptureSeconds(header(3_882_844_800, v)))
        assertEquals(3_000_000_000L, staDirectVideoCaptureSeconds(header(5_082_844_800, 1)))
    }
    @Test fun missingTruncatedUnknownVersionAndNonpositiveDatesAreAbsent() {
        assertNull(staDirectVideoCaptureSeconds(ByteArray(30)))
        assertNull(staDirectVideoCaptureSeconds(header(3_882_844_800, 1).copyOf(15)))
        assertNull(staDirectVideoCaptureSeconds(header(3_882_844_800, 2)))
        assertNull(staDirectVideoCaptureSeconds(header(2_082_844_800, 0)))
    }
}
