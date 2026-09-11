package com.ztransfer.ui.screen

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertSame
import kotlin.test.assertTrue

class LuminanceHistogramTest {
    private fun pixels(vararg values: Int): FloatArray =
        calculateLuminanceHistogram(values.size, 1) { _, row -> values.copyInto(row) }.bins

    @Test fun blackWhiteAndPrimaryWeightsKeepOriginalIntegerBins() {
        val bins = pixels(0xff000000.toInt(), 0xffffffff.toInt(), 0xffff0000.toInt(),
            0xff00ff00.toInt(), 0xff0000ff.toInt())
        val expected = FloatArray(256)
        for (index in intArrayOf(0, 255, 53, 182, 18)) expected[index] = 1f
        assertContentEquals(expected, bins)
    }

    @Test fun histogramKeepsLinearPeakRatherThanLogarithmicCompression() {
        val bins = pixels(0, 0, 0, 0xffffffff.toInt(), 0xffffffff.toInt(), 0xffff0000.toInt())
        assertEquals(1f, bins[0])
        assertEquals(2f / 3f, bins[255])
        assertEquals(1f / 3f, bins[53])
        assertEquals(3, bins.count { it > 0f })
    }

    @Test fun allGraysOccupyTheirOwnBinAndAlphaDoesNotEnterLumaMath() {
        val ramp = IntArray(256) { (it shl 24) or (it shl 16) or (it shl 8) or it }
        assertContentEquals(FloatArray(256) { 1f }, pixels(*ramp))
        assertContentEquals(pixels(0x00123456), pixels(0xff123456.toInt()))
    }

    @Test fun sampleStepPreservesExactTwentyFourThousandBoundary() {
        for ((width, expectedRows) in listOf(23999 to listOf(0), 24000 to listOf(0), 24001 to listOf(0))) {
            val reads = mutableListOf<Int>()
            val result = calculateLuminanceHistogram(width, 1) { y, row ->
                reads += y
                for (x in row.indices) row[x] = if (x % 2 == 0) 0 else 0xffffff
            }
            assertEquals(expectedRows, reads)
            assertEquals(if (width > 24000) 0f else (width / 2).toFloat() / ((width + 1) / 2), result.bins[255])
            assertEquals(1f, result.bins[0])
        }
    }

    @Test fun onlySampledRowsAreReadAndOneWidthSizedBufferIsReused() {
        val rows = mutableListOf<Int>()
        var first: IntArray? = null
        calculateLuminanceHistogram(201, 121) { y, row ->
            assertEquals(201, row.size)
            if (first == null) first = row else assertSame(first, row)
            rows += y
            row.fill(0xffffff)
        }
        assertEquals((0 until 121 step 2).toList(), rows)
    }

    @Test fun scalarPixelAndOriginalDimensionClampRemainDefined() {
        for ((width, height) in listOf(1 to 1, 0 to 0, -1 to -2)) {
            var reads = 0
            val result = calculateLuminanceHistogram(width, height) { y, row ->
                reads++
                assertEquals(0, y)
                assertEquals(1, row.size)
                row[0] = 0xffffff
            }
            assertEquals(1, reads)
            assertEquals(1f, result.bins[255])
        }
    }

    @Test fun readerFailurePropagatesWithoutPublishingPartialHistogram() {
        val failure = IllegalStateException("bitmap unavailable")
        var reads = 0
        val actual = assertFailsWith<IllegalStateException> {
            calculateLuminanceHistogram(2, 2) { y, row ->
                reads++
                if (y == 1) throw failure
                row.fill(0xffffff)
            }
        }
        assertSame(failure, actual)
        assertEquals(2, reads)
    }

    @Test fun patternedVgaXgaOddAndFullSizeInputsMatchFrozenAndroidOracle() {
        for ((width, height) in listOf(1 to 1, 201 to 121, 640 to 480, 1024 to 768, 6000 to 4000)) {
            val expected = originalHistogramOracle(width, height, ::patternPixel)
            val result = calculateLuminanceHistogram(width, height) { y, row ->
                for (x in row.indices) row[x] = patternPixel(x, y)
            }
            assertContentEquals(expected, result.bins, "$width x $height")
            assertTrue(result.bins.all { it.isFinite() && it in 0f..1f })
        }
    }
}

private fun patternPixel(x: Int, y: Int): Int =
    (((x * 17 + y * 3) and 255) shl 24) or
        (((x * 13 + y * 71) and 255) shl 16) or
        (((x * 53 + y * 11) and 255) shl 8) or ((x * 97 + y * 29) and 255)
