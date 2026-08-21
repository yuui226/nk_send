package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class LiveViewMetadataTest {
    private fun putBe16(data: ByteArray, offset: Int, value: Int) {
        data[offset] = (value ushr 8).toByte()
        data[offset + 1] = value.toByte()
    }

    private fun putBe32(data: ByteArray, offset: Int, value: Int) {
        putBe16(data, offset, value ushr 16)
        putBe16(data, offset + 2, value)
    }

    private fun z30Packet(
        judgement: Int = 2,
        frameCount: Int = 1,
        selectedIndex: Int = 0,
        headerSize: Int = 512
    ): ByteArray {
        val jpegSize = 32
        return ByteArray(headerSize + jpegSize).also { data ->
            putBe16(data, 0, 1)
            putBe16(data, 2, 0)
            putBe32(data, 8, headerSize)
            putBe32(data, 12, jpegSize)
            putBe16(data, 16, 5568)
            putBe16(data, 18, 3712)
            putBe16(data, 28, 1024)
            putBe16(data, 30, 680)
            data[42] = judgement.toByte()
            data[44] = frameCount.toByte()
            data[45] = selectedIndex.toByte()
            putBe16(data, 48, 484)
            putBe16(data, 50, 314)
            putBe16(data, 52, 2784)
            putBe16(data, 54, 878)
            data[headerSize] = 0xFF.toByte()
            data[headerSize + 1] = 0xD8.toByte()
            data[headerSize + 2] = 0xFF.toByte()
        }
    }

    @Test
    fun parsesFocusedFrameFromValidatedZ30Header() {
        val metadata = parseLiveViewMetadata(
            z30Packet(),
            jpegOffset = 512,
            operation = Lab.NK_GET_LIVE_VIEW_IMG_EX
        )

        assertNotNull(metadata)
        assertEquals(LiveViewFocusJudgement.FOCUSED, metadata?.focusJudgement)
        assertEquals(5568, metadata?.trackingCoordinateWidth)
        assertEquals(3712, metadata?.trackingCoordinateHeight)
        assertEquals(1024, metadata?.focusCoordinateWidth)
        assertEquals(680, metadata?.focusCoordinateHeight)
        val frame = metadata?.selectedFocusFrame
        assertNotNull(frame)
        assertEquals(0.5f, frame?.centerX ?: 0f, 0.0001f)
        assertEquals(878f / 3712f, frame?.centerY ?: 0f, 0.0001f)
        assertEquals(484f / 5568f, frame?.width ?: 0f, 0.0001f)
        assertEquals(314f / 3712f, frame?.height ?: 0f, 0.0001f)
    }

    @Test
    fun keepsJudgementWhenNoSelectedFrameExists() {
        val metadata = parseLiveViewMetadata(
            z30Packet(judgement = 1, frameCount = 0),
            jpegOffset = 512,
            operation = Lab.NK_GET_LIVE_VIEW_IMG_EX
        )

        assertEquals(LiveViewFocusJudgement.NOT_FOCUSED, metadata?.focusJudgement)
        assertNull(metadata?.selectedFocusFrame)
    }

    @Test
    fun rejectsUnknownOperationAndMalformedCoordinates() {
        assertNull(
            parseLiveViewMetadata(
                z30Packet(),
                jpegOffset = 512,
                operation = Lab.NK_GET_LIVE_VIEW_IMG
            )
        )

        val malformed = z30Packet().also { putBe16(it, 52, 6000) }
        val metadata = parseLiveViewMetadata(
            malformed,
            jpegOffset = 512,
            operation = Lab.NK_GET_LIVE_VIEW_IMG_EX
        )
        assertNotNull(metadata)
        assertNull(metadata?.selectedFocusFrame)
    }

    @Test
    fun rejectsUnknownHeaderVersionAndInvalidJpegBoundary() {
        val unknownVersion = z30Packet().also { putBe16(it, 0, 2) }
        assertNull(
            parseLiveViewMetadata(
                unknownVersion,
                jpegOffset = 512,
                operation = Lab.NK_GET_LIVE_VIEW_IMG_EX
            )
        )

        val invalidJpeg = z30Packet().also { it[512] = 0 }
        assertNull(
            parseLiveViewMetadata(
                invalidJpeg,
                jpegOffset = 512,
                operation = Lab.NK_GET_LIVE_VIEW_IMG_EX
            )
        )
    }

    @Test
    fun parsesSelectedFrameFromMultiFrameTrackingHeader() {
        val packet = z30Packet(frameCount = 2, selectedIndex = 1).also {
            putBe16(it, 48, 120)
            putBe16(it, 50, 80)
            putBe16(it, 52, 200)
            putBe16(it, 54, 160)
            putBe16(it, 56, 300)
            putBe16(it, 58, 180)
            putBe16(it, 60, 700)
            putBe16(it, 62, 420)
        }
        val metadata = parseLiveViewMetadata(
            packet,
            jpegOffset = 512,
            operation = Lab.NK_GET_LIVE_VIEW_IMG_EX
        )

        val frame = metadata?.selectedFocusFrame
        assertEquals(LiveViewFocusJudgement.FOCUSED, metadata?.focusJudgement)
        assertNotNull(frame)
        assertEquals(700f / 5568f, frame!!.centerX, 0.0001f)
        assertEquals(420f / 3712f, frame.centerY, 0.0001f)
        assertEquals(300f / 5568f, frame.width, 0.0001f)
        assertEquals(180f / 3712f, frame.height, 0.0001f)
    }

    @Test
    fun rejectsOutOfRangeSelectedFrameIndex() {
        val metadata = parseLiveViewMetadata(
            z30Packet(frameCount = 2, selectedIndex = 2),
            jpegOffset = 512,
            operation = Lab.NK_GET_LIVE_VIEW_IMG_EX
        )

        assertEquals(LiveViewFocusJudgement.FOCUSED, metadata?.focusJudgement)
        assertNull(metadata?.selectedFocusFrame)
    }

    @Test
    fun rejectsFrameTableThatWouldRunIntoJpeg() {
        val metadata = parseLiveViewMetadata(
            z30Packet(frameCount = 59, selectedIndex = 0),
            jpegOffset = 512,
            operation = Lab.NK_GET_LIVE_VIEW_IMG_EX
        )

        assertEquals(LiveViewFocusJudgement.FOCUSED, metadata?.focusJudgement)
        assertNull(metadata?.selectedFocusFrame)
    }

    @Test
    fun ignoresInvalidFocusCoordinateGrid() {
        val packet = z30Packet().also {
            putBe16(it, 28, 0)
            putBe16(it, 30, 4000)
        }
        val metadata = parseLiveViewMetadata(
            packet,
            jpegOffset = 512,
            operation = Lab.NK_GET_LIVE_VIEW_IMG_EX
        )

        assertNotNull(metadata)
        assertNull(metadata?.focusCoordinateWidth)
        assertNull(metadata?.focusCoordinateHeight)
    }

    @Test
    fun parsesStereoSoundLevelsFrom512ByteHeader() {
        val packet = z30Packet().also {
            // +312 是旧的尾部推断，会稳定命中保留区；即使放入非法值也不应影响
            // 已由真机差分确认的 +388..+391。
            it[512 - 200] = 0x7F
            it[388] = 11
            it[389] = 9
            it[390] = 7
            it[391] = 4
        }

        val sound = parseLiveViewMetadata(
            packet,
            jpegOffset = 512,
            operation = Lab.NK_GET_LIVE_VIEW_IMG_EX
        )?.soundLevels

        assertNotNull(sound)
        assertEquals(11, sound?.peakLeft)
        assertEquals(9, sound?.peakRight)
        assertEquals(7, sound?.currentLeft)
        assertEquals(4, sound?.currentRight)
    }

    @Test
    fun parsesStereoSoundLevelsFrom1024ByteHeader() {
        val packet = z30Packet(headerSize = 1024).also {
            val soundOffset = 1024 - 200
            it[soundOffset] = 14
            it[soundOffset + 1] = 13
            it[soundOffset + 2] = 10
            it[soundOffset + 3] = 8
        }

        val sound = parseLiveViewMetadata(
            packet,
            jpegOffset = 1024,
            operation = Lab.NK_GET_LIVE_VIEW_IMG_EX
        )?.soundLevels

        assertNotNull(sound)
        assertEquals(14, sound?.peakLeft)
        assertEquals(8, sound?.currentRight)
    }

    @Test
    fun invalidExtendedSoundLevelsDoNotDiscardFocusMetadata() {
        val packet = z30Packet(headerSize = 1024).also {
            it[824 + 2] = 15
        }

        val metadata = parseLiveViewMetadata(
            packet,
            jpegOffset = 1024,
            operation = Lab.NK_GET_LIVE_VIEW_IMG_EX
        )

        assertNotNull(metadata)
        assertEquals(LiveViewFocusJudgement.FOCUSED, metadata?.focusJudgement)
        assertNotNull(metadata?.selectedFocusFrame)
        assertNull(metadata?.soundLevels)
    }

    @Test
    fun invalidCompactSoundLevelsDoNotDiscardFocusMetadata() {
        val packet = z30Packet().also {
            it[390] = 15
        }

        val metadata = parseLiveViewMetadata(
            packet,
            jpegOffset = 512,
            operation = Lab.NK_GET_LIVE_VIEW_IMG_EX
        )

        assertNotNull(metadata)
        assertEquals(LiveViewFocusJudgement.FOCUSED, metadata?.focusJudgement)
        assertNotNull(metadata?.selectedFocusFrame)
        assertNull(metadata?.soundLevels)
    }
}
