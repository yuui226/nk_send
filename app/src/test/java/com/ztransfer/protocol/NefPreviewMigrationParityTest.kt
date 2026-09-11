package com.ztransfer.protocol

import com.ztransfer.protocol.rawbaseline.parseNefHeaderMetadata as baselineHeader
import com.ztransfer.protocol.rawbaseline.largestEmbeddedJpegRange as baselineRange
import com.ztransfer.protocol.rawbaseline.largestEmbeddedJpeg as baselineJpeg
import com.ztransfer.protocol.rawbaseline.staDirectCaptureDate as baselineDate
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Test

/** Frozen original implementation exists only in test sources; product has one shared parser. */
class NefPreviewMigrationParityTest {
    private fun outcome(block: () -> Any?): Any? = try {
        block()
    } catch (failure: Exception) {
        failure.javaClass.name
    }

    private fun check(bytes: ByteArray, length: Int = bytes.size) {
        assertEquals(outcome { baselineHeader(bytes, length).let { it.captureDate to it.previews.map { r -> r.offset to r.length } } },
            outcome { parseNefHeaderMetadata(bytes, length).let { it.captureDate to it.previews.map { r -> r.offset to r.length } } })
        assertEquals(outcome { baselineRange(bytes, length)?.let { it.offset to it.length } },
            outcome { largestEmbeddedJpegRange(bytes, length)?.let { it.offset to it.length } })
        assertEquals(outcome { baselineJpeg(bytes)?.toList() }, outcome { largestEmbeddedJpeg(bytes)?.toList() })
    }

    @Test fun deterministicRandomInputsAndBoundedPrefixesMatchFrozenAndroid() {
        val random = Random(735188)
        repeat(4000) {
            val bytes = random.nextBytes(random.nextInt(0, 1025))
            check(bytes, when (it % 4) { 0 -> -1; 1 -> Int.MAX_VALUE; else -> random.nextInt(bytes.size + 1) })
        }
    }

    @Test fun mutatedTiffDirectoriesDatesAndJpegMarkersMatchFrozenAndroid() {
        val random = Random(55876)
        val seed = ByteArray(512)
        fun u16(at: Int, value: Int) { seed[at] = value.toByte(); seed[at + 1] = (value ushr 8).toByte() }
        fun u32(at: Int, value: Int) { repeat(4) { seed[at + it] = (value ushr (8 * it)).toByte() } }
        seed[0] = 73; seed[1] = 73; u16(2, 42); u32(4, 8); u16(8, 3)
        for ((i, tag) in listOf(0x0201, 0x0202, 0x9003).withIndex()) {
            val at = 10 + i * 12
            u16(at, tag); u16(at + 2, if (i == 2) 2 else 4)
            u32(at + 4, if (i == 2) 20 else 1); u32(at + 8, listOf(300, 100, 100)[i])
        }
        "2026:09:05 01:02:03\u0000".toByteArray().copyInto(seed, 100)
        byteArrayOf(-1, -40, 1, 2, -1, -39).copyInto(seed, 300)
        repeat(4000) {
            val bytes = seed.copyOf()
            repeat(random.nextInt(1, 9)) { bytes[random.nextInt(bytes.size)] = random.nextInt(256).toByte() }
            check(bytes, if (it % 2 == 0) bytes.size else random.nextInt(bytes.size + 1))
        }
        // Preserve (and document) legacy exceptions for overflowing corrupt IFD offsets.
        u32(4, Int.MAX_VALUE); check(seed)
    }

    @Test fun asciiByteValuesInsideTiffDateKeepJvmReplacementSemantics() {
        val bytes = ByteArray(80)
        bytes[0] = 73; bytes[1] = 73; bytes[2] = 42; bytes[4] = 8; bytes[8] = 1
        bytes[10] = 3; bytes[11] = 0x90.toByte(); bytes[12] = 2; bytes[14] = 21; bytes[18] = 40
        "2026:09:05 01:02:03 ".toByteArray().copyInto(bytes, 40)
        repeat(256) { bytes[59] = it.toByte(); check(bytes) }
    }

    @Test fun dateNullMalformedAndUnicodeInputsMatchOriginal() {
        for (value in listOf(null, "", "2026:99:99 88:77:66", "٢٠٢٦:٠٩:٠٥ ٠١:٠٢:٠٣", "2026:09:05 01:02:03+08:00")) {
            assertEquals(baselineDate(value), staDirectCaptureDate(value))
        }
    }
}
