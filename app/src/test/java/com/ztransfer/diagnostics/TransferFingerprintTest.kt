package com.ztransfer.diagnostics

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class TransferFingerprintTest {
    @Test
    fun fingerprintsAreIndependentOfChunkSizesOffsetsAndBufferReuse() {
        val content = ByteArray(8 * 17 + 5) { ((it * 37 + 11) and 0xff).toByte() }
        val fingerprint = TransferFingerprint(segmentBytes = 17)
        val buffer = ByteArray(43)
        val chunks = intArrayOf(1, 17, 3, 35, 2, 19, 5)
        var position = 0
        var chunkIndex = 0
        while (position < content.size) {
            val count = minOf(chunks[chunkIndex++ % chunks.size], content.size - position)
            buffer.fill(0x7f)
            content.copyInto(buffer, 4, position, position + count)
            fingerprint.update(buffer, 4, count)
            fingerprint.update(buffer, buffer.size, 0)
            buffer.fill(0)
            position += count
        }

        val result = fingerprint.finish()
        assertEquals(content.size.toLong(), result.bytes)
        assertEquals(sha256(content), result.sha256)
        assertEquals(expectedSegments(content, 17), result.segments)
        assertEquals(17, result.segmentBytes)
        assertFalse(result.segmentsTruncated)
    }

    @Test
    fun emptyStreamHasStandardDigestAndNoEmptySegment() {
        val fingerprint = TransferFingerprint()
        fingerprint.update(byteArrayOf(), 0, 0)
        val result = fingerprint.finish()
        assertEquals(0L, result.bytes)
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", result.sha256)
        assertTrue(result.segments.isEmpty())
        assertEquals(4 * 1024 * 1024, result.segmentBytes)
        assertFalse(result.segmentsTruncated)
    }

    @Test
    fun exactSegmentBoundaryDoesNotAddAnEmptyTail() {
        val content = ByteArray(48) { it.toByte() }
        val fingerprint = TransferFingerprint(segmentBytes = 16)
        fingerprint.update(content, 0, 15)
        fingerprint.update(content, 15, 17)
        fingerprint.update(content, 32, 16)
        val result = fingerprint.finish()
        assertEquals(expectedSegments(content, 16), result.segments)
        assertEquals(3, result.segments.size)
    }

    @Test
    fun reorderedEqualLengthSegmentsAreDetected() {
        val content = ByteArray(64) { it.toByte() }
        val reordered = content.copyOfRange(32, 64) + content.copyOfRange(0, 32)
        val original = fingerprint(content, 32)
        val corrupt = fingerprint(reordered, 32)
        assertEquals(original.bytes, corrupt.bytes)
        assertNotEquals(original.sha256, corrupt.sha256)
        assertNotEquals(original.segments, corrupt.segments)
        assertEquals(original.segments.reversed(), corrupt.segments)
    }

    @Test
    fun differenceHelperReportsMatchSizeAndFirstSegmentOffset() {
        val expected = fingerprint(ByteArray(12) { it.toByte() }, 4)
        val actual = fingerprint(ByteArray(12) { (it + if (it >= 4) 1 else 0).toByte() }, 4)
        assertEquals("MATCH", fingerprintDifference(expected, expected))
        assertEquals(
            "SIZE_MISMATCH expected=12 actual=13",
            fingerprintDifference(expected, fingerprint(ByteArray(13) { it.toByte() }, 4))
        )
        assertEquals(
            "CONTENT_MISMATCH firstDifferentSegment=1 offset=4",
            fingerprintDifference(expected, actual)
        )
    }

    @Test
    fun differenceHelperDoesNotClaimAnOffsetAfterTruncation() {
        val expected = TransferFingerprint(segmentBytes = 4, maxSegments = 1).apply {
            update(ByteArray(12), 0, 12)
        }.finish()
        val actual = TransferFingerprint(segmentBytes = 4, maxSegments = 1).apply {
            update(ByteArray(12) { 1 }, 0, 12)
        }.finish()
        assertEquals(
            "CONTENT_MISMATCH firstDifferentSegment=unknown offset=unknown",
            fingerprintDifference(expected, actual)
        )
    }

    @Test
    fun segmentLimitKeepsWholeDigestAndBoundsRecordedSegments() {
        val content = ByteArray(10_003) { (it * 11).toByte() }
        val fingerprint = TransferFingerprint(segmentBytes = 8, maxSegments = 3)
        content.indices.forEach { fingerprint.update(content, it, 1) }
        val result = fingerprint.finish()
        assertEquals(content.size.toLong(), result.bytes)
        assertEquals(sha256(content), result.sha256)
        assertEquals(expectedSegments(content.copyOfRange(0, 24), 8), result.segments)
        assertEquals(3, result.segments.size)
        assertTrue(result.segmentsTruncated)
    }

    @Test
    fun reachingLimitIsNotTruncationUnlessAdditionalBytesArrive() {
        for (length in listOf(7, 8)) {
            val content = ByteArray(length)
            val fingerprint = TransferFingerprint(segmentBytes = 4, maxSegments = 2)
            fingerprint.update(content, 0, content.size)
            fingerprint.update(content, content.size, 0)
            val result = fingerprint.finish()
            assertEquals(expectedSegments(content, 4), result.segments)
            assertFalse(result.segmentsTruncated)
        }
        val fingerprint = TransferFingerprint(segmentBytes = 4, maxSegments = 2)
        fingerprint.update(ByteArray(9), 0, 9)
        assertTrue(fingerprint.finish().segmentsTruncated)
    }

    @Test
    fun zeroSegmentLimitCanStillFingerprintWholeStream() {
        val fingerprint = TransferFingerprint(segmentBytes = 4, maxSegments = 0)
        val content = byteArrayOf(3, 5, 7)
        fingerprint.update(content, 0, content.size)
        val result = fingerprint.finish()
        assertEquals(sha256(content), result.sha256)
        assertEquals(3L, result.bytes)
        assertTrue(result.segments.isEmpty())
        assertTrue(result.segmentsTruncated)
        assertFalse(TransferFingerprint(maxSegments = 0).finish().segmentsTruncated)
    }

    @Test
    fun invalidRangesIncludingOverflowCannotAffectDigest() {
        val fingerprint = TransferFingerprint(segmentBytes = 2)
        val content = byteArrayOf(1, 2, 3)
        val invalidRanges = listOf(
            -1 to 1, 0 to -1, 4 to 0, 2 to 2,
            Int.MAX_VALUE to 1, 1 to Int.MAX_VALUE,
            Int.MAX_VALUE to Int.MAX_VALUE
        )
        invalidRanges.forEach { (offset, count) ->
            expectFailure<IndexOutOfBoundsException> { fingerprint.update(content, offset, count) }
        }
        fingerprint.update(content, 3, 0)
        fingerprint.update(content, 0, content.size)
        val result = fingerprint.finish()
        assertEquals(3L, result.bytes)
        assertEquals(sha256(content), result.sha256)
    }

    @Test
    fun invalidConfigurationIsRejected() {
        expectFailure<IllegalArgumentException> { TransferFingerprint(segmentBytes = 0) }
        expectFailure<IllegalArgumentException> { TransferFingerprint(segmentBytes = -1) }
        expectFailure<IllegalArgumentException> { TransferFingerprint(maxSegments = -1) }
    }

    @Test
    fun finishIsIdempotentAndLaterUpdatesFail() {
        val fingerprint = TransferFingerprint(segmentBytes = 2)
        fingerprint.update(byteArrayOf(1, 2, 3), 0, 3)
        val result = fingerprint.finish()
        assertSame(result, fingerprint.finish())
        expectFailure<IllegalStateException> { fingerprint.update(byteArrayOf(4), 0, 1) }
        expectFailure<IllegalStateException> { fingerprint.update(byteArrayOf(), 0, 0) }
        @Suppress("UNCHECKED_CAST")
        expectFailure<UnsupportedOperationException> { (result.segments as MutableList<String>).clear() }
        assertSame(result, fingerprint.finish())
        assertEquals(2, result.segments.size)
    }

    @Test
    fun outputWrapperForwardsExactBytesAndStandardLifecycle() {
        val delegate = RecordingOutputStream()
        val fingerprint = TransferFingerprint(segmentBytes = 2)
        val output = FingerprintingOutputStream(delegate, fingerprint)
        val buffer = byteArrayOf(99, 10, 20, 30, 88)
        output.write(buffer, 1, 3)
        assertSame(buffer, delegate.lastBuffer)
        assertEquals(1, delegate.lastOffset)
        assertEquals(3, delegate.lastCount)
        buffer.fill(0)
        output.write(0x1ff)
        output.write(byteArrayOf(40, 50))
        output.write(byteArrayOf(), 0, 0)
        output.flush()
        output.close()

        val expected = byteArrayOf(10, 20, 30, -1, 40, 50)
        assertArrayEquals(expected, delegate.bytes.toByteArray())
        assertEquals(1, delegate.flushes)
        assertEquals(1, delegate.closes)
        assertEquals(sha256(expected), fingerprint.finish().sha256)
        assertEquals(expectedSegments(expected, 2), fingerprint.finish().segments)
    }

    @Test
    fun invalidOrFinalizedWritesDoNotReachDelegate() {
        val delegate = RecordingOutputStream()
        val fingerprint = TransferFingerprint()
        val output = FingerprintingOutputStream(delegate, fingerprint)
        expectFailure<IndexOutOfBoundsException> { output.write(byteArrayOf(1), 0, Int.MAX_VALUE) }
        fingerprint.finish()
        expectFailure<IllegalStateException> { output.write(1) }
        assertEquals(0, delegate.writes)
    }

    @Test
    fun unsuccessfulDelegateWriteIsExcludedFromFingerprint() {
        val fingerprint = TransferFingerprint()
        val output = FingerprintingOutputStream(object : OutputStream() {
            override fun write(value: Int) { throw IOException("disk full") }
        }, fingerprint)
        expectFailure<IOException> { output.write(byteArrayOf(1, 2, 3), 1, 2) }
        assertEquals(0L, fingerprint.finish().bytes)
        assertEquals(sha256(byteArrayOf()), fingerprint.finish().sha256)
    }

    private fun fingerprint(content: ByteArray, segmentBytes: Int): FingerprintResult =
        TransferFingerprint(segmentBytes = segmentBytes).apply {
            update(content, 0, content.size)
        }.finish()

    private fun expectedSegments(content: ByteArray, segmentBytes: Int): List<String> =
        content.asList().chunked(segmentBytes).map { sha256(it.toByteArray()) }

    private fun sha256(content: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(content).joinToString("") { "%02x".format(it) }

    private inline fun <reified T : Throwable> expectFailure(block: () -> Unit) {
        try {
            block()
            fail("Expected ${T::class.java.simpleName}")
        } catch (failure: Throwable) {
            if (failure !is T) throw failure
        }
    }

    private class RecordingOutputStream : OutputStream() {
        val bytes = ByteArrayOutputStream()
        var lastBuffer: ByteArray? = null
        var lastOffset = -1
        var lastCount = -1
        var writes = 0
        var flushes = 0
        var closes = 0

        override fun write(value: Int) { bytes.write(value) }

        override fun write(buffer: ByteArray, offset: Int, count: Int) {
            lastBuffer = buffer
            lastOffset = offset
            lastCount = count
            writes++
            bytes.write(buffer, offset, count)
        }

        override fun flush() { flushes++ }
        override fun close() { closes++ }
    }
}
