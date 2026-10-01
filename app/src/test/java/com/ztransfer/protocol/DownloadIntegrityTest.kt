package com.ztransfer.protocol

import org.junit.Assert.*
import org.junit.Test

class DownloadIntegrityTest {
    @Test fun rejectsSelfConsistentShortOrOversizedDataPhase() {
        assertEquals(100L, mismatchedFullObjectSize(80, 80, 100))
        assertEquals(100L, mismatchedFullObjectSize(120, 120, 100))
    }

    @Test fun checksDeclaredLengthEvenWhenFileSizeIsUnknown() {
        assertEquals(100L, mismatchedFullObjectSize(80, 100, PtpConstants.SIZE_UNKNOWN))
        assertEquals(100L, mismatchedFullObjectSize(80, -1, 100))
    }

    @Test fun preservesUnknownSizeStreamsAndLargeVideos() {
        assertNull(mismatchedFullObjectSize(100, -1, PtpConstants.SIZE_UNKNOWN))
        assertNull(mismatchedFullObjectSize(100, 100, 100))
        val large = 6L * 1024 * 1024 * 1024
        assertNull(mismatchedFullObjectSize(large, PtpConstants.SIZE_UNKNOWN, large))
        assertEquals(large, mismatchedFullObjectSize(large - 1, -1, large))
    }
}
