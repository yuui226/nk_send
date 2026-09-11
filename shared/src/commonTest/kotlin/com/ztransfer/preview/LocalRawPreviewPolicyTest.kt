package com.ztransfer.preview

import kotlin.random.Random
import kotlin.test.*

class LocalRawPreviewPolicyTest {
    @Test fun prefixBudgetAndCandidateOrderMatchOriginal() {
        assertEquals(16 * 1024 * 1024, LocalRawPreviewPolicy.indexPrefixBytes)
        val prefix = ByteArray(128)
        prefix[0] = 73; prefix[1] = 73; prefix[2] = 42; prefix[4] = 8; prefix[8] = 2
        fun entry(at: Int, tag: Int, value: Int) {
            prefix[at] = tag.toByte(); prefix[at + 1] = (tag ushr 8).toByte()
            prefix[at + 2] = 4; prefix[at + 4] = 1
            repeat(4) { prefix[at + 8 + it] = (value ushr (it * 8)).toByte() }
        }
        entry(10, 0x0201, 1000); entry(22, 0x0202, 400)
        byteArrayOf(-1, -40, 1, -1, -39).copyInto(prefix, 70)
        assertEquals(listOf(NefPreviewReference(1000, 400), NefPreviewReference(70, 5)), LocalRawPreviewPolicy.candidates(prefix))
        entry(10, 0x0201, 70); entry(22, 0x0202, 5)
        assertEquals(listOf(NefPreviewReference(70, 5)), LocalRawPreviewPolicy.candidates(prefix))
    }

    @Test fun largerPixelAreaWinsNotEncodedLengthAndEqualAreaKeepsFirst() {
        var best = -1L; var winner = -1
        listOf(20 to 10, 100 to 50, 50 to 100, 0 to 90).forEachIndexed { i, (w, h) ->
            val pixels = LocalRawPreviewPolicy.pixelCount(w, h)
            if (LocalRawPreviewPolicy.isBetter(pixels, best)) { best = pixels; winner = i }
        }
        assertEquals(1, winner); assertEquals(5000L, best)
    }

    @Test fun dimensionsUseLongProductAndRejectInvalidImageBounds() {
        assertEquals(Int.MAX_VALUE.toLong() * Int.MAX_VALUE, LocalRawPreviewPolicy.pixelCount(Int.MAX_VALUE, Int.MAX_VALUE))
        for ((w, h) in listOf(0 to 1, -1 to 1, 1 to Int.MIN_VALUE)) {
            val count = LocalRawPreviewPolicy.pixelCount(w, h)
            assertEquals(-1L, count); assertFalse(LocalRawPreviewPolicy.isBetter(count, -1))
        }
    }

    @Test fun envelopeChecksExactFirstAndLastMarkersIncludingFourByteJpeg() {
        assertTrue(LocalRawPreviewPolicy.isCompleteJpeg(byteArrayOf(-1, -40, -1, -39)))
        assertFalse(LocalRawPreviewPolicy.isCompleteJpeg(byteArrayOf(-1, -40, -39)))
        assertFalse(LocalRawPreviewPolicy.isCompleteJpeg(byteArrayOf(-1, -40, -1, -39, 0)))
        val random = Random(34)
        repeat(2000) {
            val b = random.nextBytes(random.nextInt(20))
            val original = b.size >= 4 && b[0] == 0xFF.toByte() && b[1] == 0xD8.toByte() &&
                b[b.lastIndex - 1] == 0xFF.toByte() && b[b.lastIndex] == 0xD9.toByte()
            assertEquals(original, LocalRawPreviewPolicy.isCompleteJpeg(b))
        }
    }

    @Test fun candidateSelectionMatchesOriginalDimensionLoopAcrossInvalidAndLargeBounds() {
        val random = Random(55876)
        repeat(1000) {
            var originalBest = -1L; var sharedBest = -1L
            var originalWinner = -1; var sharedWinner = -1
            repeat(20) { index ->
                val width = random.nextInt(); val height = random.nextInt()
                if (width > 0 && height > 0) {
                    val pixels = width.toLong() * height.toLong()
                    if (pixels > originalBest) { originalBest = pixels; originalWinner = index }
                }
                val pixels = LocalRawPreviewPolicy.pixelCount(width, height)
                if (LocalRawPreviewPolicy.isBetter(pixels, sharedBest)) { sharedBest = pixels; sharedWinner = index }
            }
            assertEquals(originalBest, sharedBest); assertEquals(originalWinner, sharedWinner)
        }
    }
}
