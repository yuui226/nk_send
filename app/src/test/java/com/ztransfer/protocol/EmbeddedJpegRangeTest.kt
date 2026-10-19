package com.ztransfer.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EmbeddedJpegRangeTest {
    @Test
    fun extractsLargestCompleteImageAndHonorsValidLength() {
        val small = jpeg(byteArrayOf(1))
        val large = jpeg(ByteArray(32) { 2 })
        val largeOffset = 2 + small.size + 3
        val raw = byteArrayOf(9, 9) + small + byteArrayOf(8, 8, 8) + large + byteArrayOf(7)

        assertArrayEquals(large, largestEmbeddedJpeg(raw))
        assertEquals(NefPreviewReference(largeOffset.toLong(), large.size), largestEmbeddedJpegRange(raw))
        assertEquals(NefPreviewReference(2, small.size), largestEmbeddedJpegRange(raw, largeOffset + large.size - 1))
        assertNull(largestEmbeddedJpegRange(raw, 2 + small.size - 1))
        assertNull(largestEmbeddedJpegRange(raw, -1))
    }

    @Test
    fun rawMetadataMarkerPairDoesNotHidePreviewBeyondFirstHeader() {
        // Reproduce the reported NEF's offsets and sizes without storing any user image data.
        val raw = ByteArray(240 * 1024)
        val falseCandidate = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0x57) +
            ByteArray(8_432) { 0x6B } + byteArrayOf(0xFF.toByte(), 0xD9.toByte())
        falseCandidate.copyInto(raw, 79_973)
        val actualPreview = jpeg(ByteArray(109_002 - 27) { 0x21 })
        assertEquals(109_002, actualPreview.size)
        actualPreview.copyInto(raw, 95_044)

        assertNull(largestEmbeddedJpegRange(raw, 128 * 1024))
        assertEquals(NefPreviewReference(95_044, 109_002), largestEmbeddedJpegRange(raw))
    }

    @Test
    fun ignoresJpegMarkersInsideAppAndCommentPayloads() {
        val nested = jpeg(byteArrayOf(1, 2, 3))
        val opaque = nested + byteArrayOf(0xFF.toByte(), 0xD9.toByte(), 0xFF.toByte(), 0xD8.toByte())
        val preview = jpeg(byteArrayOf(3), prefix = segment(0xE1, opaque) + segment(0xFE, opaque))

        assertArrayEquals(preview, largestEmbeddedJpeg(preview))
        assertNull(largestEmbeddedJpegRange(byteArrayOf(0xFF.toByte(), 0xD8.toByte()) + segment(0xE1, byteArrayOf(1)) + byteArrayOf(0xFF.toByte(), 0xD9.toByte())))
    }

    @Test
    fun acceptsStuffedBytesAndRestartMarkersInEntropyData() {
        val preview = jpeg(byteArrayOf(
            1, 0xFF.toByte(), 0, 0xD9.toByte(),
            2, 0xFF.toByte(), 0, 0xD8.toByte(),
            3, 0xFF.toByte(), 0xD0.toByte(),
            4, 0xFF.toByte(), 0xFF.toByte(), 0xD7.toByte(), 5,
        ))

        assertArrayEquals(preview, largestEmbeddedJpeg(preview))
        assertNull(largestEmbeddedJpeg(preview.copyOf(preview.size - 1)))
    }

    @Test
    fun acceptsProgressiveMultipleScans() {
        val preview = byteArrayOf(0xFF.toByte(), 0xD8.toByte()) + frame(0xC2) +
            scan() + byteArrayOf(1, 2) + segment(0xC4, byteArrayOf(0)) +
            scan() + byteArrayOf(3, 4) + byteArrayOf(0xFF.toByte(), 0xD9.toByte())

        assertArrayEquals(preview, largestEmbeddedJpeg(preview))
    }

    @Test
    fun rejectsMalformedSegmentsAndTruncatedImages() {
        val noFrame = byteArrayOf(0xFF.toByte(), 0xD8.toByte()) + scan() + byteArrayOf(0xFF.toByte(), 0xD9.toByte())
        val badLength = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE1.toByte(), 0, 1, 0xFF.toByte(), 0xD9.toByte())
        val truncatedSegment = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE1.toByte(), 0x7F, 0x7F, 0xFF.toByte(), 0xD9.toByte())

        assertNull(largestEmbeddedJpeg(noFrame))
        assertNull(largestEmbeddedJpeg(badLength))
        assertNull(largestEmbeddedJpeg(truncatedSegment))
        assertNull(largestEmbeddedJpeg(jpeg(byteArrayOf(1)).copyOf(26)))
    }

    // Structurally complete JPEG framing: these fixtures exercise marker parsing, not pixel decoding.
    private fun jpeg(entropy: ByteArray, prefix: ByteArray = byteArrayOf()): ByteArray =
        byteArrayOf(0xFF.toByte(), 0xD8.toByte()) + prefix + frame(0xC0) + scan() +
            entropy + byteArrayOf(0xFF.toByte(), 0xD9.toByte())

    private fun frame(marker: Int): ByteArray =
        segment(marker, byteArrayOf(8, 0, 8, 0, 8, 1, 1, 0x11, 0))

    private fun scan(): ByteArray = segment(0xDA, byteArrayOf(1, 1, 0, 0, 63, 0))

    private fun segment(marker: Int, payload: ByteArray): ByteArray {
        val length = payload.size + 2
        return byteArrayOf(0xFF.toByte(), marker.toByte(), (length ushr 8).toByte(), length.toByte()) + payload
    }
}
