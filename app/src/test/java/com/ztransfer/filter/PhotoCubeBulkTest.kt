package com.ztransfer.filter

import com.ztransfer.lut.CubeLut
import kotlinx.coroutines.CancellationException
import org.junit.Assert.*
import org.junit.Test
import java.util.Random

class PhotoCubeBulkTest {
    private fun mapper(size: Int, seed: Long = 1): PhotoCubeMapper {
        val random = Random(seed)
        return PhotoCubeMapper(CubeLut(size,
            floatArrayOf(-.1f, .05f, 0f), floatArrayOf(1.1f, .95f, 1f),
            FloatArray(size * size * size * 3) { random.nextFloat() * 1.5f - .25f }, "test"))
    }
    private fun requireNativeWhenRequested() {
        if (java.lang.Boolean.getBoolean("ztransfer.nativeLutRequired")) assertTrue(NativePhotoLut.available)
    }

    @Test fun bulkIsBitExactAcrossGridsStrengthsAlphaAndBatchEdges() {
        requireNativeWhenRequested()
        val random = Random(107)
        for (size in listOf(2, 3, 17, 33, 65)) {
            val mapper = mapper(size)
            for (execution in PhotoLutExecution.entries)
            for (strength in listOf(.02f, .5f, .8f, 1f)) for (alpha in listOf(false, true)) {
                val source = IntArray(64 * 1024 + 19) { random.nextInt() }
                source[1] = 0x00123456
                source[2] = -1
                source[3] = 0
                val expected = source.copyOf()
                for (i in 1 until source.lastIndex) expected[i] = mapper.map(source[i], strength, alpha)
                mapper.mapRange(source, 1, source.lastIndex, strength, alpha, execution) { false }
                assertArrayEquals("size=$size strength=$strength alpha=$alpha", expected, source)
            }
        }
    }

    @Test fun cancellationStopsBetweenBatchesAndDoesNotTouchTheRemainder() {
        val mapper = mapper(17)
        val batchSize = if (NativePhotoLut.available) NativePhotoLut.BATCH_PIXELS else 4096
        val pixels = IntArray(NativePhotoLut.BATCH_PIXELS * 2) { 0xff123456.toInt() }
        var checks = 0
        try {
            mapper.mapRange(pixels, 0, pixels.size, .8f, false) { ++checks == 2 }
            fail("must cancel")
        } catch (_: CancellationException) {}
        assertEquals(2, checks)
        assertEquals(mapper.map(0xff123456.toInt(), .8f, false), pixels[0])
        assertEquals(0xff123456.toInt(), pixels[batchSize])
    }

    @Test fun optionalExhaustiveRgbParityAndSingleThreadBenchmark() {
        if (!java.lang.Boolean.getBoolean("ztransfer.nativeLutRequired")) return
        requireNativeWhenRequested()
        val mapper = mapper(65)
        mapper.prepareBulk()
        val n = 1 shl 24
        val original = IntArray(64 * 1024)
        val actual = IntArray(original.size)
        var referenceNs = 0L
        var bulkNs = 0L
        // Every RGB value in a shuffled permutation, with the previous scalar mapper as the oracle.
        for (start in 0 until n step original.size) {
            for (i in original.indices) { original[i] = (0xff000000.toInt() or (((start+i) * 0x5bd1e995) and 0xffffff)); actual[i] = original[i] }
            var time = System.nanoTime()
            for (i in original.indices) original[i] = mapper.map(original[i], 1f, false)
            referenceNs += System.nanoTime() - time
            time = System.nanoTime()
            mapper.mapRange(actual, 0, actual.size, 1f, false) { false }
            bulkNs += System.nanoTime() - time
            assertArrayEquals("RGB block $start / 16K", original, actual)
        }
        println("LUT_HOST_SINGLE_THREAD pixels=$n scalarMs=${referenceNs/1e6} bulkMs=${bulkNs/1e6} ratio16=${referenceNs.toDouble()/bulkNs}")
    }
}
