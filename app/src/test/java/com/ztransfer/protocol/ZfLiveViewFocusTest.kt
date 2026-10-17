package com.ztransfer.protocol

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class ZfLiveViewFocusTest {
    private fun ByteArray.put16(offset: Int, value: Int) {
        this[offset] = (value ushr 8).toByte()
        this[offset + 1] = value.toByte()
    }

    private fun ByteArray.put32(offset: Int, value: Int) {
        put16(offset, value ushr 16)
        put16(offset + 2, value)
    }

    // Synthetic fixture from Nikon ZfUsbMtpE_02 §9.7.1, not a Zf hardware capture.
    // Whole size is deliberately independent of the selectable preview resolution.
    private fun packet(previewWidth: Int = 640, previewHeight: Int = 424, rotation: Int = 0) =
        ByteArray(1024 + 32).apply {
            put16(0, 2)
            put16(2, 1)
            put32(8, 1024)
            put32(12, 32)
            put16(16, 6000)
            put16(18, 4000)
            put16(20, 6000)
            put16(22, 4000)
            put16(24, 3000)
            put16(26, 2000)
            put16(28, previewWidth)
            put16(30, previewHeight)
            this[42] = 2
            this[44] = 1
            put16(48, 300)
            put16(50, 200)
            put16(52, 3000)
            put16(54, 2000)
            put32(816, 7_500_000)
            this[824] = 12
            this[825] = 10
            this[826] = 8
            this[827] = 6
            this[839] = rotation.toByte()
            this[1024] = 0xFF.toByte()
            this[1025] = 0xD8.toByte()
            this[1026] = 0xFF.toByte()
        }

    private fun parse(bytes: ByteArray, offset: Int = 1024) =
        parseLiveViewMetadata(bytes, offset, Lab.NK_GET_LIVE_VIEW_IMG_EX)

    private fun assertFrame(center: Float, frame: LiveViewFocusFrame?) {
        requireNotNull(frame)
        assertEquals(center, frame.centerX, 0.0001f)
        assertEquals(center, frame.centerY, 0.0001f)
        assertEquals(0.05f, frame.width, 0.0001f)
        assertEquals(0.05f, frame.height, 0.0001f)
    }

    @Test
    fun parsesDocumentedZfVersionWithoutConfusingPreviewAndCommandSizes() {
        val metadata = requireNotNull(parse(packet()))
        assertEquals(6000, metadata.trackingCoordinateWidth)
        assertEquals(4000, metadata.trackingCoordinateHeight)
        assertEquals(640, metadata.focusCoordinateWidth)
        assertEquals(424, metadata.focusCoordinateHeight)
        assertEquals(LiveViewFocusJudgement.FOCUSED, metadata.focusJudgement)
        assertFrame(0.5f, metadata.selectedFocusFrame)
        assertEquals(LiveViewSoundLevels(12, 10, 8, 6), metadata.soundLevels)
        assertEquals(7_500_000L, metadata.remainingVideoTimeMs)
        assertNull(metadata.attitude) // Do not apply compact Z30 attitude offsets to Zf.
    }

    @Test
    fun tapsReachFullCoordinateDomainForBothAfPathsAtEveryCameraOrientation() = runBlocking {
        for ((previewWidth, previewHeight) in listOf(640 to 424, 1280 to 848)) {
            for (rotation in 0..3) {
                val metadata = requireNotNull(parse(packet(previewWidth, previewHeight, rotation)))
                for ((fraction, expected) in listOf(
                    0.1f to listOf(600, 400),
                    0.5f to listOf(3000, 2000),
                    0.9f to listOf(5399, 3599)
                )) {
                    val x = rcNormalizedToFocusCoordinate(fraction, metadata.trackingCoordinateWidth)
                    val y = rcNormalizedToFocusCoordinate(fraction, metadata.trackingCoordinateHeight)
                    for (path in listOf(RcTapFocusPath.MOVE_AREA, RcTapFocusPath.TRACKING)) {
                        val commands = mutableListOf<Pair<Int, List<Int>>>()
                        runTapFocusStart(x, y, x, y, tryTracking = true, tapPath = path,
                            command = { code, params ->
                                commands += code to params.toList()
                                Lab.OK
                            }, pause = {})
                        val operation = if (path == RcTapFocusPath.TRACKING) Lab.NK_START_TRACKING
                            else Lab.NK_CHANGE_AF_AREA
                        assertEquals(listOf(operation to expected, Lab.NK_AF_DRIVE to emptyList()), commands)
                    }
                }
            }
        }
    }

    @Test
    fun readsSubjectRecordsBeyondTheCompactHeaderTable() {
        val bytes = packet().apply {
            this[44] = 64
            this[45] = 63
            val offset = 48 + 63 * 8
            put16(offset, 300)
            put16(offset + 2, 200)
            put16(offset + 4, 4500)
            put16(offset + 6, 3000)
        }
        val metadata = requireNotNull(parse(bytes))
        assertFrame(0.75f, metadata.selectedFocusFrame)
        assertEquals(2, metadata.focusFrames.size)
    }

    @Test
    fun rejectsUnknownVersionsAndMismatchedHeaderSizes() {
        for ((major, minor) in listOf(2 to 0, 2 to 2, 3 to 0)) {
            val bytes = packet().apply { put16(0, major); put16(2, minor) }
            assertNull(parse(bytes))
            assertNull(parseLiveViewRemainingVideoTime(bytes, 1024))
        }
        val compact = packet().copyOf(512 + 32).apply {
            put32(8, 512)
            this[512] = 0xFF.toByte()
            this[513] = 0xD8.toByte()
            this[514] = 0xFF.toByte()
        }
        assertNull(parse(compact, 512))
        assertNull(parse(packet().apply { put32(8, 512) }))
        assertNull(parse(packet().apply { put32(12, 33) }))
        assertNull(parse(packet().apply { this[1024] = 0 }))
    }
}
