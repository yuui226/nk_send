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
        val offset = if (size == 512) 384 else 816
        put32(it, offset, millis)
        it[if (size == 512) 392 else 828] = recording.toByte()
    }
    @Test fun remainingMovieTimeUsesVideoBlockInBothHeaderLayouts() {
        for (size in listOf(512, 1024)) {
            assertEquals(125_000L, parseLiveViewRemainingVideoTime(packet(size, 125_000, 0), size))
            assertEquals(0L, parseLiveViewRemainingVideoTime(packet(size, 0, 1), size))
        }
    }
    @Test fun z30CapturedStandbyTailReadsRemainingTimeAfterZeroField() {
        val bytes = packet(512, 0, 0)
        val captured = "00000000007270E00A0A060600000000"
            .chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        captured.copyInto(bytes, 380)
        assertEquals(7_500_000L, parseLiveViewRemainingVideoTime(bytes, 512))
    }
    @Test fun unknownTimeOrStructureDoesNotBecomeAVisibleCountdown() {
        assertNull(parseLiveViewRemainingVideoTime(packet(512, 0, 0), 512))
        assertNull(parseLiveViewRemainingVideoTime(packet(512, 0xFFFFFFFF, 1), 512))
        assertNull(parseLiveViewRemainingVideoTime(packet(512, 1000, 2), 512))
        assertNull(parseLiveViewRemainingVideoTime(packet(512, 1000, 1).also { it[1] = 2 }, 512))
        assertNull(parseLiveViewRemainingVideoTime(ByteArray(20), 512))
        assertNull(parseLiveViewRemainingVideoTime(ByteArray(1024), 384))
    }

    private fun withJpeg(header: ByteArray, lengthOffset: Int): ByteArray =
        header.copyOf(header.size + 3).also {
            put32(it, lengthOffset, 3)
            it[header.size] = 0xFF.toByte()
            it[header.size + 1] = 0xD8.toByte()
            it[header.size + 2] = 0xFF.toByte()
        }

    @Test fun videoTimeSurvivesMissingAfGeometry() {
        for (size in listOf(512, 1024)) {
            val bytes = withJpeg(packet(size, 125_000, 1), 12)
            if (size == 1024) { bytes[1] = 2; bytes[3] = 1 }
            // No usable whole-image dimensions; AF must remain unavailable.
            assertNull(parseLiveViewMetadata(bytes, size, Lab.NK_GET_LIVE_VIEW_IMG_EX))
            assertEquals(125_000L, parseLiveViewPacketVideoTime(bytes, size, Lab.NK_GET_LIVE_VIEW_IMG_EX, "Zf"))
            bytes[12] = 1 // Corrupt JPEG length must still be rejected.
            assertNull(parseLiveViewPacketVideoTime(bytes, size, Lab.NK_GET_LIVE_VIEW_IMG_EX, "Zf"))
        }
    }

    // Synthetic ZfUsbMtpE_02 §9.7.2 layout: prefix 8 + display information 376.
    private fun legacy(millis: Long, recording: Int) = withJpeg(ByteArray(384).also {
        put32(it, 0, 376)
        put32(it, 64, millis)
        it[68] = recording.toByte()
    }, 4)

    @Test fun legacyZfTimeIsAvailableWithoutInventingAfMetadata() {
        val bytes = legacy(125_000, 1)
        assertNull(parseLiveViewMetadata(bytes, 384, Lab.NK_GET_LIVE_VIEW_IMG))
        for (model in listOf("Zf", "NIKON Z f", "Z 30")) {
            assertEquals(125_000L, parseLiveViewPacketVideoTime(bytes, 384, Lab.NK_GET_LIVE_VIEW_IMG, model))
        }
        assertEquals(0L, parseLiveViewPacketVideoTime(legacy(0, 1), 384, Lab.NK_GET_LIVE_VIEW_IMG, "Zf"))
    }

    @Test fun legacyUnknownValuesAndLayoutsStayHidden() {
        fun parse(bytes: ByteArray, offset: Int = 384, operation: Int = Lab.NK_GET_LIVE_VIEW_IMG, model: String? = "Zf") =
            parseLiveViewPacketVideoTime(bytes, offset, operation, model)
        assertNull(parse(legacy(0, 0)))
        assertNull(parse(legacy(0xFFFFFFFF, 1)))
        assertNull(parse(legacy(1000, 2)))
        assertNull(parse(legacy(1000, 1), model = "Z9"))
        assertNull(parse(legacy(1000, 1), model = null))
        assertNull(parse(legacy(1000, 1), operation = Lab.NK_GET_LIVE_VIEW_IMG_EX))
        assertNull(parse(legacy(1000, 1), offset = 376))
        assertNull(parse(legacy(1000, 1).also { it[4] = 1 }))
        assertNull(parse(legacy(1000, 1).also { it[384] = 0 }))
        assertNull(parse(ByteArray(20)))
    }

    @Test fun enhancedTimeKeepsExistingBehaviorRegardlessOfCameraModel() {
        for ((size, major, minor) in listOf(Triple(512, 1, 0), Triple(1024, 1, 0), Triple(1024, 2, 1))) {
            for ((millis, recording) in listOf(125_000L to 0, 125_000L to 1, 0L to 1, 0L to 0, 0xFFFFFFFFL to 1)) {
                val bytes = withJpeg(packet(size, millis, recording), 12).also {
                    it[1] = major.toByte()
                    it[3] = minor.toByte()
                    it[17] = 100 // Valid whole-image and preview dimensions.
                    it[19] = 100
                    it[29] = 100
                    it[31] = 100
                }
                val original = requireNotNull(parseLiveViewMetadata(bytes, size, Lab.NK_GET_LIVE_VIEW_IMG_EX))
                val before = bytes.copyOf()
                for (model in listOf(null, "Zf", "Z 30", "Z6_2", "Z9", "unknown")) {
                    assertEquals(original.remainingVideoTimeMs,
                        parseLiveViewPacketVideoTime(bytes, size, Lab.NK_GET_LIVE_VIEW_IMG_EX, model))
                }
                assertArrayEquals(before, bytes)
                assertEquals(original, parseLiveViewMetadata(bytes, size, Lab.NK_GET_LIVE_VIEW_IMG_EX))
            }
        }
    }

    @Test fun malformedVideoHeadersCannotInterruptFrameProcessing() {
        for (offset in listOf(Int.MIN_VALUE, -1, 0, 376, 384, 512, 1024, Int.MAX_VALUE)) {
            for (size in listOf(0, 1, 20, 383, 384, 386, 511, 512, 514, 1023, 1024, 1026)) {
                for (operation in listOf(0, Lab.NK_GET_LIVE_VIEW_IMG, Lab.NK_GET_LIVE_VIEW_IMG_EX)) {
                    assertNull(parseLiveViewPacketVideoTime(ByteArray(size), offset, operation, "Zf"))
                }
            }
        }
        val bytes = withJpeg(packet(1024, 125_000, 1), 12)
        for ((major, minor) in listOf(2 to 0, 2 to 2, 3 to 0)) {
            bytes[1] = major.toByte()
            bytes[3] = minor.toByte()
            assertNull(parseLiveViewPacketVideoTime(bytes, 1024, Lab.NK_GET_LIVE_VIEW_IMG_EX, "Zf"))
        }
    }
}
