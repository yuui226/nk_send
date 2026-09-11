package com.ztransfer.ui.screen

import com.ztransfer.ui.theme.createTextureImageBitmap
import kotlin.test.Test
import kotlin.test.assertContentEquals

/** Real Skia/ImageBitmap row reads: Mac-only gate, not a Windows pass. */
class HistogramBitmapIosTest {
    @Test fun primaryAndEndpointColorsKeepArgbOrderThroughImageBitmap() {
        val pixels = intArrayOf(0xff000000.toInt(), 0xffffffff.toInt(), 0xffff0000.toInt(),
            0xff00ff00.toInt(), 0xff0000ff.toInt(), 0xff808080.toInt())
        val image = createTextureImageBitmap(pixels, 3, 2)
        val expected = FloatArray(256)
        for (index in intArrayOf(0, 255, 53, 182, 18, 128)) expected[index] = 1f
        assertContentEquals(expected, calculateImageLuminanceHistogram(image).bins)
    }

    @Test fun sampledOddDimensionsReadCorrectStartRowAndStride() {
        val width = 201
        val height = 121
        val pixels = IntArray(width * height) { i ->
            val x = i % width
            val y = i / width
            0xff000000.toInt() or (((x * 29) and 255) shl 16) or
                (((y * 11) and 255) shl 8) or ((x + y * 13) and 255)
        }
        val image = createTextureImageBitmap(pixels, width, height)
        val expected = calculateLuminanceHistogram(width, height) { y, row ->
            pixels.copyInto(row, startIndex = y * width, endIndex = (y + 1) * width)
        }
        assertContentEquals(expected.bins, calculateImageLuminanceHistogram(image).bins)
    }

    @Test fun onePixelAndSingleColumnImagesDoNotReadOutsideBitmap() {
        for (height in listOf(1, 17)) {
            val image = createTextureImageBitmap(IntArray(height) { 0xffffffff.toInt() }, 1, height)
            val expected = FloatArray(256).also { it[255] = 1f }
            assertContentEquals(expected, calculateImageLuminanceHistogram(image).bins)
        }
    }
}
