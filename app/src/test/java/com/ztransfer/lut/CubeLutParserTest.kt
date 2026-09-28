package com.ztransfer.lut

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream

class CubeLutParserTest {
    private fun identity(size: Int = 2): String = buildString {
        append("LUT_3D_SIZE $size\n")
        for (b in 0 until size) for (g in 0 until size) for (r in 0 until size)
            append("${r.toFloat()/(size-1)} ${g.toFloat()/(size-1)} ${b.toFloat()/(size-1)}\n")
    }
    private fun parse(s: String) = CubeLutParser.parse(ByteArrayInputStream(s.toByteArray()))
    private fun rejects(s: String, reason: LutFailure = LutFailure.INVALID) {
        try { parse(s); fail("Accepted malformed LUT") }
        catch (failure: LutException) { assertEquals(reason, failure.reason) }
    }
    @Test fun redVariesFastestAndDomainIsPreserved() {
        val lut = parse("\uFEFF# test\r\nTITLE \"Identity\"\nDOMAIN_MIN -1 -2 -3\nDOMAIN_MAX 1 2 3\n" + identity())
        assertEquals(2, lut.size)
        assertArrayEquals(floatArrayOf(0f,0f,0f,1f,0f,0f,0f,1f,0f), lut.rgb.take(9).toFloatArray(), 0f)
        assertArrayEquals(floatArrayOf(-1f,-2f,-3f), lut.domainMin, 0f)
        assertEquals(64, lut.digest.length)
    }
    @Test fun rejectsBrokenTablesAndUnknownFormats() {
        rejects(identity().substringBeforeLast("1.0 1.0 1.0"))
        rejects(identity() + "0 0 0\n")
        rejects(identity().replaceFirst("0.0 0.0 0.0", "0 NaN 0"))
        rejects("LUT_1D_SIZE 2\n", LutFailure.UNSUPPORTED)
        rejects("LUT_3D_SIZE 2147483647\n", LutFailure.UNSUPPORTED)
        rejects("DOMAIN_MIN 1 0 0\n" + identity())
        rejects("DOMAIN_MAX 1e40 1 1\n" + identity())
        rejects("DOMAIN_MIN -5e-39 0 0\nDOMAIN_MAX 5e-39 1 1\n" + identity())
        rejects("LUT_3D_INPUT_RANGE 0 1\n" + identity(), LutFailure.UNSUPPORTED)
    }
    @Test fun boundsLinesBeforeGrowingMemory() {
        rejects("#".repeat(CubeLutParser.MAX_LINE + 1), LutFailure.TOO_LARGE)
    }
    @Test fun preservesExtendedOutputAndAcceptsScientificNotation() {
        val lut = parse(identity().replaceFirst("0.0 0.0 0.0", "-1e-1 1.2 2e0"))
        assertArrayEquals(floatArrayOf(-.1f,1.2f,2f), lut.rgb.take(3).toFloatArray(), 0f)
    }
    @Test fun commonGridSizesAndCancellation() {
        for (size in listOf(17,33,65)) assertEquals(size*size*size*3, parse(identity(size)).rgb.size)
        var checks=0
        try {
            CubeLutParser.parse(identity(17).byteInputStream()) { if (++checks == 4) throw InterruptedException() }
            fail("Cancellation ignored")
        } catch (_: InterruptedException) { assertEquals(4, checks) }
    }
    @Test fun chunkBoundariesDoNotChangeTableOrDigest() {
        val bytes = ("\uFEFFTITLE \"Identity\"\r\n" + identity(17)).toByteArray()
        val ordinary = CubeLutParser.parse(bytes.inputStream())
        val fragmented = object : ByteArrayInputStream(bytes) {
            override fun read(b: ByteArray, off: Int, len: Int): Int = super.read(b, off, minOf(len, 7))
        }
        val result = CubeLutParser.parse(fragmented)
        assertEquals(ordinary.digest, result.digest)
        assertArrayEquals(ordinary.rgb, result.rgb, 0f)
    }

    @Test fun actualByteLimitIsEnforcedEvenWithoutFileMetadata() {
        val source = object : java.io.InputStream() {
            var remaining = CubeLutParser.MAX_BYTES + 1
            override fun read(): Int {
                if (remaining <= 0) return -1
                return if (--remaining % 1024 == 0) 10 else 35
            }
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (remaining <= 0) return -1
                val count = minOf(remaining, len)
                // Bounded comment lines avoid masking the file limit with the line limit.
                for (i in 0 until count) b[off + i] = read().toByte()
                return count
            }
        }
        try { CubeLutParser.parse(source); fail("Accepted oversized file") }
        catch (failure: LutException) { assertEquals(LutFailure.TOO_LARGE, failure.reason) }
    }

    @Test fun refusesAProviderThatMakesNoReadProgress() {
        val source = object : java.io.InputStream() {
            override fun read(): Int = 0
            override fun read(b: ByteArray, off: Int, len: Int): Int = 0
        }
        try { CubeLutParser.parse(source); fail("Spinning on an empty read") }
        catch (failure: LutException) { assertEquals(LutFailure.READ, failure.reason) }
    }

}
