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
        selectedIndex: Int = 0
    ): ByteArray {
        val jpegSize = 32
        return ByteArray(512 + jpegSize).also { data ->
            putBe16(data, 0, 1)
            putBe16(data, 2, 0)
            putBe32(data, 8, 512)
            putBe32(data, 12, jpegSize)
            putBe16(data, 16, 5568)
            putBe16(data, 18, 3712)
            data[42] = judgement.toByte()
            data[44] = frameCount.toByte()
            data[45] = selectedIndex.toByte()
            putBe16(data, 48, 484)
            putBe16(data, 50, 314)
            putBe16(data, 52, 2784)
            putBe16(data, 54, 878)
            data[512] = 0xFF.toByte()
            data[513] = 0xD8.toByte()
            data[514] = 0xFF.toByte()
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
    fun doesNotGuessUnverifiedMultiFrameLayout() {
        val metadata = parseLiveViewMetadata(
            z30Packet(frameCount = 2, selectedIndex = 1),
            jpegOffset = 512,
            operation = Lab.NK_GET_LIVE_VIEW_IMG_EX
        )

        assertEquals(LiveViewFocusJudgement.FOCUSED, metadata?.focusJudgement)
        assertNull(metadata?.selectedFocusFrame)
    }
}
