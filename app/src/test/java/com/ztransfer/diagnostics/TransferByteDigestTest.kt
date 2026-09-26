package com.ztransfer.diagnostics

import java.security.MessageDigest
import org.junit.Assert.*
import org.junit.Test

class TransferByteDigestTest {
    @Test fun digestAndZeroRunsSurviveChunkBoundariesAndResumeOffsets() {
        val bytes = ByteArray(100_000).apply { this[0] = 1; this[99_999] = 2 }
        val digest = TransferByteDigest(4_194_304)
        digest.add(bytes, 0, 32768)
        digest.add(bytes, 32768, bytes.size-32768)
        val actual = digest.finish()
        val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
        assertTrue(actual.contains("bytes=100000 sha256=$sha"))
        assertTrue(actual.contains("[4194305,4294303)"))
        assertEquals(actual, digest.finish())
    }
    @Test fun trailingZerosAreRecordedAndReportsRemainBounded() {
        val digest = TransferByteDigest()
        repeat(40) { digest.add(ByteArray(65536), 0, 65536); digest.add(byteArrayOf(1), 0, 1) }
        digest.add(ByteArray(65536), 0, 65536)
        val report = digest.finish()
        assertTrue(report.endsWith("totalZeroRanges=41"))
        assertEquals(33, report.count { it == '[' }) // outer list plus at most 32 ranges
    }
}
