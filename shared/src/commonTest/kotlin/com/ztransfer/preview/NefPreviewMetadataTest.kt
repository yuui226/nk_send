package com.ztransfer.preview

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull

class NefPreviewMetadataTest {
    private class Tiff(val little: Boolean = true) {
        val bytes = ByteArray(1024)
        init {
            bytes[0] = (if (little) 'I' else 'M').code.toByte()
            bytes[1] = bytes[0]
            u16(2, 42); u32(4, 8)
        }
        fun u16(at: Int, value: Int) = put(at, value.toLong(), 2)
        fun u32(at: Int, value: Long) = put(at, value, 4)
        private fun put(at: Int, value: Long, size: Int) {
            repeat(size) { i -> bytes[at + i] = (value ushr ((if (little) i else size - 1 - i) * 8)).toByte() }
        }
        fun entry(at: Int, tag: Int, type: Int = 4, count: Long = 1, value: Long) {
            u16(at, tag); u16(at + 2, type); u32(at + 4, count)
            if (type == 3 && count == 1L) u16(at + 8, value.toInt()) else u32(at + 8, value)
        }
        fun jpeg(ifd: Int, offset: Long, length: Long) {
            u16(ifd, 2); entry(ifd + 2, 0x0201, value = offset)
            entry(ifd + 14, 0x0202, value = length)
        }
    }

    @Test fun littleAndBigEndianRangesMayPointBeyondPrefix() {
        for (little in listOf(true, false)) {
            val t = Tiff(little); t.jpeg(8, 300_000, 1_068_298)
            assertEquals(listOf(NefPreviewReference(300_000, 1_068_298)), parseNefHeaderMetadata(t.bytes, 38).previews)
            assertEquals(emptyList(), parseNefHeaderMetadata(t.bytes, 37).previews)
        }
    }

    @Test fun jpegRangeLimitsAndUnsignedOffsetsRemainUnchanged() {
        for (length in listOf(3L, 4L, 16L * 1024 * 1024, 16L * 1024 * 1024 + 1)) {
            val t = Tiff(); t.jpeg(8, 0xffffffffL, length)
            val expected = if (length in 4..16L * 1024 * 1024) listOf(NefPreviewReference(0xffffffffL, length.toInt())) else emptyList()
            assertEquals(expected, parseNefHeaderMetadata(t.bytes).previews)
        }
        val t = Tiff(); t.jpeg(8, 0, 10)
        assertEquals(emptyList(), parseNefHeaderMetadata(t.bytes).previews)
    }

    @Test fun stripRangesRequireJpegCompressionSix() {
        for (compression in listOf(1L, 6L, 7L)) {
            val t = Tiff(false); t.u16(8, 3)
            t.entry(10, 0x0103, type = 3, value = compression)
            t.entry(22, 0x0111, value = 700); t.entry(34, 0x0117, value = 44)
            assertEquals(if (compression == 6L) listOf(NefPreviewReference(700, 44)) else emptyList(), parseNefHeaderMetadata(t.bytes).previews)
        }
    }

    @Test fun traversalDeduplicatesSortsAndStopsCycles() {
        val t = Tiff(); t.jpeg(8, 500, 20); t.u32(34, 100)
        t.jpeg(100, 600, 40); t.u32(126, 200)
        t.jpeg(200, 500, 20); t.u32(226, 8)
        assertEquals(listOf(NefPreviewReference(600, 40), NefPreviewReference(500, 20)), parseNefHeaderMetadata(t.bytes).previews)
    }

    @Test fun depthEightInclusiveAndEntryCountLimitArePreserved() {
        val t = Tiff()
        repeat(11) { depth ->
            val at = 8 + depth * 40
            t.jpeg(at, 500L + depth, 4L + depth); t.u32(at + 26, (at + 40).toLong())
        }
        assertEquals(9, parseNefHeaderMetadata(t.bytes).previews.size)
        t.u16(8, 513)
        assertEquals(emptyList(), parseNefHeaderMetadata(t.bytes).previews)
    }

    @Test fun datePriorityAndSamePriorityFirstWins() {
        val t = Tiff(); t.u16(8, 4)
        val dates = listOf("2020:01:02 03:04:05", "2021:01:02 03:04:05", "2022:01:02 03:04:05", "2023:01:02 03:04:05")
        listOf(0x0132, 0x9004, 0x9003, 0x9003).forEachIndexed { i, tag ->
            t.entry(10 + i * 12, tag, type = 2, count = 20, value = (400 + i * 24).toLong())
            (dates[i] + '\u0000').encodeToByteArray().copyInto(t.bytes, 400 + i * 24)
        }
        assertEquals("20220102T030405", parseNefHeaderMetadata(t.bytes).captureDate)
    }

    @Test fun dateFormattingKeepsOriginalLooseDigitExtraction() {
        assertNull(staDirectCaptureDate(null)); assertNull(staDirectCaptureDate("123"))
        assertEquals("20261399T996199", staDirectCaptureDate("2026:13:99 99:61:99+123"))
        assertEquals("٢٠٢٦٠٩٠٥T٠١٠٢٠٣", staDirectCaptureDate("٢٠٢٦:٠٩:٠٥ ٠١:٠٢:٠٣"))
    }

    @Test fun asciiReplacesEachHighByteNotUtf8Sequences() {
        val bytes = ByteArray(256) { it.toByte() }
        assertEquals(buildString { repeat(128) { append(it.toChar()) }; repeat(128) { append('\uFFFD') } }, bytes.decodeRawAscii())
        assertEquals("\uFFFD\uFFFD\uFFFD1", byteArrayOf(0xe2.toByte(), 0x82.toByte(), 0xac.toByte(), 49).decodeRawAscii())
    }

    @Test fun jpegScannerKeepsFirstEqualLengthAndLatestNestedStart() {
        val bytes = byteArrayOf(-1, -40, 1, -1, -39, 0, -1, -40, 2, -1, -39)
        assertEquals(NefPreviewReference(0, 5), largestEmbeddedJpegRange(bytes))
        assertContentEquals(bytes.copyOfRange(0, 5), largestEmbeddedJpeg(bytes))
        assertEquals(NefPreviewReference(3, 5), largestEmbeddedJpegRange(byteArrayOf(-1, -40, 0, -1, -40, 1, -1, -39)))
    }

    @Test fun validLengthClampsAndIncompleteJpegIsNotReturned() {
        val bytes = byteArrayOf(-1, -40, 0, -1, -39)
        assertNull(largestEmbeddedJpegRange(bytes, -1))
        assertNull(largestEmbeddedJpegRange(bytes, 4))
        assertEquals(NefPreviewReference(0, 5), largestEmbeddedJpegRange(bytes, Int.MAX_VALUE))
        assertEquals(NefHeaderMetadata(null, emptyList()), parseNefHeaderMetadata(Tiff().bytes, -1))
        assertEquals(NefHeaderMetadata(null, emptyList()), parseNefHeaderMetadata(byteArrayOf(1, 2)))
    }
}
