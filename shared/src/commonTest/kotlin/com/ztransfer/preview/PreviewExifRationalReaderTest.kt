package com.ztransfer.preview

import kotlin.random.Random
import kotlin.test.*

class PreviewExifRationalReaderTest {
    private data class Tag(val id: Int, val n: Long, val d: Long, val type: Int = 5, val count: Int = 1)
    private fun tiff(tags: List<Tag>, little: Boolean = true): ByteArray {
        val result = ByteArray(32 + tags.size * 28)
        fun put(at: Int, value: Long, width: Int) = repeat(width) { i ->
            result[at + i] = (value ushr ((if (little) i else width - i - 1) * 8)).toByte()
        }
        result[0] = if (little) 73 else 77; result[1] = result[0]
        put(2, 42, 2); put(4, 8, 4); put(8, 1, 2)
        put(10, 0x8769, 2); put(12, 4, 2); put(14, 1, 4); put(18, 26, 4)
        put(26, tags.size.toLong(), 2)
        tags.forEachIndexed { i, tag ->
            val at = 28 + i * 12; val body = 32 + tags.size * 12 + i * 16
            put(at, tag.id.toLong(), 2); put(at + 2, tag.type.toLong(), 2)
            put(at + 4, tag.count.toLong(), 4); put(at + 8, body.toLong(), 4)
            put(body, tag.n, 4); put(body + 4, tag.d, 4)
        }
        return result
    }
    private fun jpeg(tiff: ByteArray): ByteArray {
        val length = tiff.size + 8
        return byteArrayOf(-1, -40, -1, -32, 0, 4, 1, 2, -1, -31,
            (length ushr 8).toByte(), length.toByte(), 69, 120, 105, 102, 0, 0) + tiff + byteArrayOf(-1, -39)
    }
    private fun read(data: ByteArray) = PreviewExifRationalReader.read(
        PreviewExifByteSource { offset, count -> data.copyOfRange(offset.toInt(), offset.toInt() + count) }, data.size.toLong())

    @Test fun bothEndianTiffAndJpegKeepRawAndCompatibilityTagRepresentations() {
        val tags = listOf(Tag(0x829D, 28, 10), Tag(0x829A, 1, 250), Tag(0x9202, 4, 1),
            Tag(0x9204, -2, 3, 10), Tag(0x920A, 85, 1))
        for (little in listOf(true, false)) for (data in listOf(tiff(tags, little), jpeg(tiff(tags, little)))) {
            val result = read(data); assertTrue(result.complete)
            assertEquals("2.8", result.value(PreviewExifTag.F_NUMBER))
            assertEquals("0.004", result.value(PreviewExifTag.EXPOSURE_TIME))
            assertEquals("4/1", result.value(PreviewExifTag.APERTURE_VALUE))
            assertEquals("-2/3", result.value(PreviewExifTag.EXPOSURE_BIAS_VALUE))
            assertEquals("85/1", result.value(PreviewExifTag.FOCAL_LENGTH))
        }
    }
    @Test fun rawBiasOverridesImageIoDecimalAndRestoresOriginalVisibilityBoundary() {
        val n = 36_293_949L; val d = 725_879_001L
        val values = NativePreviewExifValues().apply { set(PreviewExifTag.EXPOSURE_BIAS_VALUE, (n.toDouble() / d).toString()) }
        val formatter = PreviewExifDecimalFormatter { value, _, _ -> value.toString() }
        assertNull(parsePreviewExif(values, formatter)?.exposureCompensation)
        read(jpeg(tiff(listOf(Tag(0x9204, n, d, 10))))).applyTo(values)
        assertEquals(n.toFloat() / d.toFloat(), parsePreviewExifRational(values.attribute(PreviewExifTag.EXPOSURE_BIAS_VALUE)))
        assertNotNull(parsePreviewExif(values, formatter)?.exposureCompensation)
    }
    @Test fun signedAndUnsignedExtremesAndZeroDenominatorsMatchAttributeRules() {
        for (little in listOf(true, false)) {
            val result = read(tiff(listOf(Tag(0x9204, Int.MIN_VALUE.toLong(), -1, 10),
                Tag(0x920A, 0xFFFFFFFF, 0xFFFFFFFE), Tag(0x9202, 99, 0), Tag(0x829A, 123, 0)), little))
            assertEquals("-2147483648/-1", result.value(PreviewExifTag.EXPOSURE_BIAS_VALUE))
            assertEquals("4294967295/4294967294", result.value(PreviewExifTag.FOCAL_LENGTH))
            assertEquals("0/1", result.value(PreviewExifTag.APERTURE_VALUE))
            assertEquals("0.0", result.value(PreviewExifTag.EXPOSURE_TIME))
        }
    }
    @Test fun missingRawTagsClearSynthesizedNumericsButKeepOtherProperties() {
        val values = NativePreviewExifValues().apply { PreviewExifTag.entries.forEach { set(it, "synthetic") } }
        read(tiff(emptyList())).applyTo(values)
        assertNull(values.attribute(PreviewExifTag.F_NUMBER)); assertNull(values.attribute(PreviewExifTag.APERTURE_VALUE))
        assertNull(values.attribute(PreviewExifTag.EXPOSURE_TIME)); assertNull(values.attribute(PreviewExifTag.EXPOSURE_BIAS_VALUE))
        assertNull(values.attribute(PreviewExifTag.FOCAL_LENGTH))
        assertEquals("synthetic", values.attribute(PreviewExifTag.LENS_MODEL))
        assertEquals("synthetic", values.attribute(PreviewExifTag.GPS_LATITUDE))
    }
    @Test fun undefinedNormalizesTypeAndInvalidDuplicateDoesNotReplaceValidTag() {
        val result = read(tiff(listOf(Tag(0x9204, -2, 3, 7), Tag(0x9204, 20, 1, 5),
            Tag(0x920A, 20, 1), Tag(0x920A, 85, 1))))
        assertEquals("-2/3", result.value(PreviewExifTag.EXPOSURE_BIAS_VALUE))
        assertEquals("85/1", result.value(PreviewExifTag.FOCAL_LENGTH))
    }
    @Test fun emptyAndMultipleRationalsAreNotMistakenForScalarValues() {
        val result = read(tiff(listOf(Tag(0x9204, 2, 3, 10, 0), Tag(0x920A, 85, 1, count = 2))))
        assertTrue(result.complete)
        assertNull(result.value(PreviewExifTag.EXPOSURE_BIAS_VALUE)); assertNull(result.value(PreviewExifTag.FOCAL_LENGTH))
    }
    @Test fun truncatedOrWrongSignatureInputCannotApplyPartialValues() {
        val original = tiff(listOf(Tag(0x9204, 2, 3, 10), Tag(0x920A, 85, 1)))
        for (length in (0 until 80).filter { it != 26 }) {
            val result = read(original.copyOf(length)); assertFalse(result.complete, "length=$length")
            val values = NativePreviewExifValues().apply { set(PreviewExifTag.FOCAL_LENGTH, "previous") }
            result.applyTo(values); assertEquals("previous", values.attribute(PreviewExifTag.FOCAL_LENGTH))
        }
        assertFalse(read(ByteArray(40)).complete)
        assertFalse(read(original.copyOf().apply { this[2] = 43 }).complete)
        // At exactly the EXIF pointer, known-length Android input skips the out-of-range IFD.
        assertTrue(read(original.copyOf(26)).complete)
        assertNull(read(original.copyOf(26)).value(PreviewExifTag.FOCAL_LENGTH))
    }
    @Test fun jpegStopsAtScanOrEndAndNeverScansEntropyForFakeExif() {
        for (marker in listOf(0xDA, 0xD9)) {
            var count = 0
            val data = byteArrayOf(-1, -40, -1, marker.toByte()) + jpeg(tiff(listOf(Tag(0x920A, 85, 1))))
            val result = PreviewExifRationalReader.read(PreviewExifByteSource { offset, length ->
                count++; assertTrue(offset + length <= 4); data.copyOfRange(offset.toInt(), offset.toInt() + length)
            }, data.size.toLong())
            assertTrue(result.complete); assertNull(result.value(PreviewExifTag.FOCAL_LENGTH)); assertEquals(3, count)
        }
    }
    @Test fun appOneOffsetsCannotEscapeTheExifSegment() {
        val data = jpeg(tiff(listOf(Tag(0x920A, 85, 1))))
        data[10] = 0; data[11] = 16 // TIFF header only, body still physically exists after the segment.
        assertFalse(read(data).complete)
    }
    @Test fun readsAreExactBoundedAndSourceExceptionsPropagate() {
        val data = tiff(listOf(Tag(0x920A, 85, 1)))
        assertFalse(PreviewExifRationalReader.read(PreviewExifByteSource { _, count -> ByteArray(count - 1) }, data.size.toLong()).complete)
        assertFalse(PreviewExifRationalReader.read(PreviewExifByteSource { _, _ -> null }, data.size.toLong()).complete)
        val cancelled = IllegalStateException("cancelled")
        assertSame(cancelled, assertFailsWith<IllegalStateException> {
            PreviewExifRationalReader.read(PreviewExifByteSource { _, _ -> throw cancelled }, data.size.toLong())
        })
    }
    @Test fun cyclicNextDirectoryTerminatesAndRepeatedMarkerBudgetIsBounded() {
        val data = tiff(listOf(Tag(0x920A, 85, 1))).apply { this[22] = 8 }
        assertEquals("85/1", read(data).value(PreviewExifTag.FOCAL_LENGTH))
        var reads = 0
        val result = PreviewExifRationalReader.read(PreviewExifByteSource { offset, count ->
            reads++; if (offset == 0L) byteArrayOf(-1, -40) else ByteArray(count) { -1 }
        }, Long.MAX_VALUE)
        assertFalse(result.complete); assertEquals(4096, reads)
    }
    @Test fun seededRationalsRetainAndroidAttributeArithmeticAcrossBothEndianOrders() {
        val random = Random(0xEF17)
        repeat(4000) { index ->
            val signed = index % 2 == 0; val n = random.nextInt().toLong(); val d = random.nextInt().toLong()
            val numerator = if (signed) n else n and 0xFFFFFFFFL
            val denominator = if (signed) d else d and 0xFFFFFFFFL
            val tag = if (signed) PreviewExifTag.EXPOSURE_BIAS_VALUE else PreviewExifTag.FOCAL_LENGTH
            val result = read(tiff(listOf(Tag(if (signed) 0x9204 else 0x920A, numerator, denominator, if (signed) 10 else 5)), index % 3 == 0))
            assertTrue(result.complete)
            assertEquals(numerator.toFloat() / denominator.toFloat(), parsePreviewExifRational(result.value(tag)))
        }
    }

    @Test fun largeRawReadsOnlyMetadataBeyondPrefixAndRejectsSignedOutOfLineOffset() {
        val original = tiff(listOf(Tag(0x920A, 85, 1)))
        val shift = 4 * 1024 * 1024
        fun put(at: Int, value: Int) = repeat(4) { original[at + it] = (value ushr (it * 8)).toByte() }
        put(18, shift + 26); put(36, shift + 44)
        var readBytes = 0
        val result = PreviewExifRationalReader.read(PreviewExifByteSource { offset, count ->
            assertTrue(count <= PreviewExifRationalReader.maximumReadBytes)
            readBytes += count
            val mapped = if (offset >= shift + 26) offset - shift else offset
            original.copyOfRange(mapped.toInt(), mapped.toInt() + count)
        }, 3L * 1024 * 1024 * 1024)
        assertTrue(result.complete); assertEquals("85/1", result.value(PreviewExifTag.FOCAL_LENGTH))
        assertTrue(readBytes < 100)
        val highOffset = tiff(listOf(Tag(0x920A, 85, 1))).apply { this[39] = 0x80.toByte() }
        assertFalse(PreviewExifRationalReader.read(PreviewExifByteSource { offset, count ->
            assertTrue(offset < highOffset.size); highOffset.copyOfRange(offset.toInt(), offset.toInt() + count)
        }, 3L * 1024 * 1024 * 1024).complete)
    }
}
