package com.ztransfer.preview

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ThumbnailCropPolicyTest {
    private fun pixels(w: Int, h: Int, color: (Int, Int) -> Int) = object : ThumbnailCropPixels {
        override val width = w
        override val height = h
        override fun readLine(index: Int, horizontal: Boolean, into: IntArray) {
            repeat(if (horizontal) w else h) { i ->
                into[i] = if (horizontal) color(i, index) else color(index, i)
            }
        }
    }

    @Test fun symmetricBarsIncludeOriginalTransitionPixel() {
        val source = pixels(100, 100) { x, y ->
            if (y < 5 || y >= 95 || x < 3 || x >= 97) 0xff000000.toInt() else -1
        }
        assertEquals(ThumbnailCrop(4, 6, 92, 88), ThumbnailCropPolicy.letterbox(source))
    }

    @Test fun asymmetryLimitSmallImagesAndFullBlackAreNotCropped() {
        assertNull(ThumbnailCropPolicy.letterbox(pixels(100, 100) { _, y -> if (y < 5 || y >= 90) 0 else -1 }))
        assertNull(ThumbnailCropPolicy.letterbox(pixels(100, 100) { _, y -> if (y < 15 || y >= 85) 0 else -1 }))
        assertNull(ThumbnailCropPolicy.letterbox(pixels(15, 100) { _, _ -> 0 }))
        assertNull(ThumbnailCropPolicy.letterbox(pixels(100, 100) { _, _ -> 0 }))
    }

    @Test fun strictRgbThresholdIgnoresAlphaLikeAndroidGetPixels() {
        assertNull(ThumbnailCropPolicy.letterbox(pixels(100, 100) { _, y ->
            if (y < 5 || y >= 95) 0x00202020 else -1
        }))
        assertEquals(ThumbnailCrop(0, 6, 100, 88),
            ThumbnailCropPolicy.letterbox(pixels(100, 100) { _, y ->
                if (y < 5 || y >= 95) 0x001f1f1f else -1
            }))
    }

    @Test fun videoAverageIsStrictAndKeepsSixteenByNineTransition() {
        assertEquals(ThumbnailCrop(0, 7, 160, 88),
            ThumbnailCropPolicy.videoBars(pixels(160, 102) { _, y -> if (y < 6 || y >= 96) 0x272727 else -1 }))
        assertNull(ThumbnailCropPolicy.videoBars(pixels(160, 102) { _, y -> if (y < 6 || y >= 96) 0x282828 else -1 }))
        assertNull(ThumbnailCropPolicy.videoBars(pixels(160, 90) { _, _ -> 0 }))
    }
}
