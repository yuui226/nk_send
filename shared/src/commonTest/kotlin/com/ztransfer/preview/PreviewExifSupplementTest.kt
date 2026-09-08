package com.ztransfer.preview

import kotlin.test.*

class PreviewExifSupplementTest {
    private data class Tag(val id: Int, val type: Int, val bytes: ByteArray)
    private fun number(value: Long, width: Int, little: Boolean = true) =
        ByteArray(width) { (value ushr ((if (little) it else width - it - 1) * 8)).toByte() }
    private fun ascii(id: Int, value: String) = Tag(id, 2, value.encodeToByteArray() + byteArrayOf(0))
    private fun rational(id: Int, little: Boolean = true, vararg values: Pair<Long, Long>) = Tag(id, 5,
        values.fold(ByteArray(0)) { all, (n, d) -> all + number(n, 4, little) + number(d, 4, little) })
    private fun tiff(exif: List<Tag> = emptyList(), gps: List<Tag> = emptyList(), root: List<Tag> = emptyList(), little: Boolean = true): ByteArray {
        val bytes = ByteArray(4096)
        fun put(at: Int, value: Long, width: Int) { number(value, width, little).copyInto(bytes, at) }
        bytes[0] = if (little) 73 else 77; bytes[1] = bytes[0]
        put(2, 42, 2); put(4, 8, 4)
        val rootTags = root + Tag(0x8769, 4, number(256, 4, little)) + Tag(0x8825, 4, number(512, 4, little))
        var body = 1024
        fun directory(at: Int, tags: List<Tag>) {
            put(at, tags.size.toLong(), 2)
            tags.forEachIndexed { index, tag ->
                val entry = at + 2 + index * 12
                put(entry, tag.id.toLong(), 2); put(entry + 2, tag.type.toLong(), 2)
                val width = when (tag.type) { 3 -> 2; 4 -> 4; 5 -> 8; else -> 1 }
                put(entry + 4, (tag.bytes.size / width).toLong(), 4)
                if (tag.bytes.size <= 4) tag.bytes.copyInto(bytes, entry + 8)
                else { put(entry + 8, body.toLong(), 4); tag.bytes.copyInto(bytes, body); body += tag.bytes.size }
            }
        }
        directory(8, rootTags); directory(256, exif); directory(512, gps)
        return bytes.copyOf(body)
    }
    private fun read(bytes: ByteArray, header: Boolean = false): Pair<PreviewExifRationalValues, NativePreviewExifValues> {
        val raw = PreviewExifRationalReader.readMetadata(PreviewExifByteSource { offset, count ->
            bytes.copyOfRange(offset.toInt(), offset.toInt() + count)
        }, bytes.size.toLong(), header)
        return raw to NativePreviewExifValues().also(raw::applyTo)
    }
    private val formatter = PreviewExifDecimalFormatter { value, _, _ -> value.toString() }

    @Test fun isoUsesRawUnsignedShortArrayAndNeverImageIoDecimal() {
        for (little in listOf(true, false)) {
            val (_, values) = read(tiff(exif = listOf(Tag(0x8827, 3, number(64, 2, little) + number(65535, 2, little))), little = little))
            assertEquals("ISO64,65535", parsePreviewExif(values, formatter)?.iso)
        }
    }
    @Test fun unobservedExtrasPreserveImageIoWhileOldNumericPolicyStillClears() {
        val bytes = tiff()
        val raw = read(bytes).first
        val values = NativePreviewExifValues().apply { PreviewExifTag.entries.forEach { set(it, "synthetic") } }
        raw.applyTo(values)
        assertNull(values.attribute(PreviewExifTag.F_NUMBER))
        assertEquals("synthetic", values.attribute(PreviewExifTag.LENS_MODEL))
        assertEquals("synthetic", values.attribute(PreviewExifTag.PHOTOGRAPHIC_SENSITIVITY))
        values.set(PreviewExifTag.LENS_MODEL, "property")
        PreviewExifRationalReader.read(PreviewExifByteSource { o, n -> bytes.copyOfRange(o.toInt(), o.toInt() + n) }, bytes.size.toLong()).applyTo(values)
        assertEquals("property", values.attribute(PreviewExifTag.LENS_MODEL))
    }

    @Test fun unobservedGpsRetainsImageIoPairAndAltitudeButObservedRawPairIsAtomic() {
        val values = NativePreviewExifValues().apply {
            setDecodedCoordinates(12.5, -30.25); altitudeMeters = 50.0
            set(PreviewExifTag.GPS_LATITUDE, "12.5"); set(PreviewExifTag.GPS_LONGITUDE, "30.25")
        }
        for (bytes in listOf(tiff(), tiff(gps = listOf(ascii(2, "wrong type"))))) {
            read(bytes).first.applyTo(values)
            assertContentEquals(doubleArrayOf(12.5, -30.25), values.decodedCoordinates())
            assertEquals(50.0, values.decodedAltitude())
        }
        read(tiff(gps = listOf(ascii(1, "S")))).first.applyTo(values)
        assertNull(values.decodedCoordinates()); assertNull(values.attribute(PreviewExifTag.GPS_LONGITUDE))
        assertEquals(50.0, values.decodedAltitude()) // Coordinate presence never invalidates unrelated altitude.
    }

    @Test fun ordinaryNumericApiObservesNoAdditionalReadsForExifSupplementFields() {
        val empty = tiff()
        val extras = tiff(exif = listOf(Tag(0x8827, 3, number(64, 2)), ascii(0xA434, "lens")), gps = gps(true))
        for (bytes in listOf(empty, extras)) {
            val reads = mutableListOf<Pair<Long, Int>>()
            fun source() = PreviewExifByteSource { offset, count -> reads += offset to count
                bytes.copyOfRange(offset.toInt(), offset.toInt() + count) }
            val strict = PreviewExifRationalReader.read(source(), bytes.size.toLong())
            val strictReads = reads.toList(); reads.clear()
            val header = PreviewExifRationalReader.readHeader(source(), bytes.size.toLong())
            assertEquals(strictReads, reads); assertEquals(strict.complete, header.complete)
            assertTrue(reads.none { it.first >= 1024 }, "Old numeric API must never load supplemental bodies")
            PreviewExifTag.entries.forEach { assertEquals(strict.value(it), header.value(it)) }
        }
    }
    @Test fun rawTextUsesOriginalAsciiPrefixControlByteAndNullRules() {
        val lens = byteArrayOf(65, 83, 67, 73, 73, 0, 0, 0, 32, 76, 9, -1, 32, 0, 88)
        val (_, values) = read(tiff(exif = listOf(Tag(0xA434, 2, lens))))
        assertEquals("L??", parsePreviewExif(values, formatter)?.lensModel)
    }
    @Test fun datePriorityKeepsRawStringsWithoutTimezoneOrLocaleRewriting() {
        val (_, values) = read(tiff(exif = listOf(ascii(0x9003, " "), ascii(0x9004, " 2026:09:08 11:12:13 ")),
            root = listOf(ascii(0x0132, "2001:01:01 00:00:00"))))
        assertEquals(" 2026:09:08 11:12:13 ", parsePreviewExif(values, formatter)?.dateTime)
        assertEquals("2001:01:01 00:00:00", read(tiff(root = listOf(ascii(0x0132, "2001:01:01 00:00:00")))).second.attribute(PreviewExifTag.DATETIME))
    }
    private fun gps(little: Boolean, ref: String = "S") = listOf(ascii(1, ref), rational(2, little, 31L to 1L, 12L to 1L, 123456789L to 10000000L),
        ascii(3, "E"), rational(4, little, 121L to 1L, 30L to 1L, 0L to 1L), Tag(5, 1, byteArrayOf(1)), rational(6, little, 31L to 2L))
    @Test fun rawGpsUsesDoubleBeforeOriginalFloatFallbackAndSignedAltitude() {
        for (little in listOf(true, false)) {
            val result = assertNotNull(parsePreviewExif(read(tiff(gps = gps(little), little = little)).second, formatter))
            assertEquals(-(31 + 12.0 / 60 + 12.3456789 / 3600), result.latitude)
            assertEquals(121.5, result.longitude); assertEquals(-15.5, result.altitudeMeters)
        }
    }
    @Test fun lowercaseGpsReferenceKeepsAndroidPairRejectionAndFloatFallback() {
        val (_, values) = read(tiff(gps = gps(true, "s")))
        assertNull(values.decodedCoordinates())
        val result = assertNotNull(parsePreviewExif(values, formatter))
        assertEquals(-(31 + 12.0 / 60 + (123456789f / 10000000f).toDouble() / 3600), result.latitude)
    }
    @Test fun absentReferenceMalformedPairsAndZeroAltitudeDoNotBorrowImageIoValues() {
        val (_, values) = read(tiff(gps = gps(true).filter { it.id != 3 && it.id != 5 }))
        assertNull(values.decodedCoordinates()); assertTrue(values.decodedAltitude().isNaN())
        // Shared legacy preview can still use raw coordinates with a missing direction as positive.
        assertEquals(121.5, parsePreviewExif(values, formatter)?.longitude)
        assertNull(parsePreviewExif(read(tiff(gps = listOf(Tag(5, 1, byteArrayOf(0)), rational(6, true, 0L to 1L)))).second, formatter)?.altitudeMeters)
    }
    @Test fun tiffPrimaryDateSurvivesThumbnailDateAtReusedDirectory() {
        val primary = ascii(0x0132, "2026:09:08 10:00:00")
        val bytes = tiff(root = listOf(primary))
        // Root's next directory points at EXIF already visited: never reinterpret it as TIFF.
        number(256, 4).copyInto(bytes, 8 + 2 + 3 * 12)
        assertEquals("2026:09:08 10:00:00", read(bytes).second.attribute(PreviewExifTag.DATETIME))
    }
    @Test fun truncatedHeaderKeepsEarlierIsoButLocalReadRejectsWholeResult() {
        val bytes = tiff(exif = listOf(Tag(0x8827, 3, number(64, 2)), ascii(0xA434, "long lens value"))).copyOf(1030)
        val (partial, values) = read(bytes, header = true)
        assertTrue(partial.partial); assertEquals("64", values.attribute(PreviewExifTag.PHOTOGRAPHIC_SENSITIVITY))
        assertNull(values.attribute(PreviewExifTag.LENS_MODEL))
        val strict = read(bytes).first; assertFalse(strict.complete); assertFalse(strict.partial)
    }
    @Test fun gpsDirectoryCannotOccupyExifOffsetAndThenPublishFakeIso() {
        val bytes = tiff(exif = listOf(Tag(0x8827, 3, number(64, 2))))
        // Swap root pointer entries and point GPS at EXIF, consuming that visited offset first.
        val exifEntry = bytes.copyOfRange(10, 22); val gpsEntry = bytes.copyOfRange(22, 34)
        number(256, 4).copyInto(gpsEntry, 8); gpsEntry.copyInto(bytes, 10); exifEntry.copyInto(bytes, 22)
        assertNull(read(bytes).second.attribute(PreviewExifTag.PHOTOGRAPHIC_SENSITIVITY))
    }
    @Test fun metadataBudgetAndSourceFailureRemainHardFailureWithoutPartialLeak() {
        val bytes = tiff(exif = listOf(Tag(0x8827, 3, number(64, 2)), ascii(0xA434, "long lens")))
        val result = PreviewExifRationalReader.readMetadata(PreviewExifByteSource { offset, count ->
            if (offset >= 1024) null else bytes.copyOfRange(offset.toInt(), offset.toInt() + count)
        }, bytes.size.toLong(), header = true)
        assertFalse(result.complete); assertFalse(result.partial)
        val values = NativePreviewExifValues().apply { set(PreviewExifTag.PHOTOGRAPHIC_SENSITIVITY, "previous") }
        result.applyTo(values); assertEquals("previous", values.attribute(PreviewExifTag.PHOTOGRAPHIC_SENSITIVITY))
    }
    @Test fun invalidIsoTypeCannotReplaceEarlierValidDuplicate() {
        val (_, values) = read(tiff(exif = listOf(Tag(0x8827, 3, number(64, 2)), Tag(0x8827, 2, byteArrayOf(88, 0)),
            Tag(0x8827, 4, number(999, 4)))))
        assertEquals("64", values.attribute(PreviewExifTag.PHOTOGRAPHIC_SENSITIVITY))
    }

    @Test fun jpegAppOneReuseAndFinalByteOrderAlsoApplyToSupplementalIso() {
        fun segment(bytes: ByteArray): ByteArray {
            val length = bytes.size + 8
            return byteArrayOf(-1, -31, (length ushr 8).toByte(), length.toByte(), 69, 120, 105, 102, 0, 0) + bytes
        }
        val first = tiff(exif = listOf(Tag(0x8827, 3, number(64, 2))))
        val second = tiff(exif = listOf(Tag(0x8827, 3, number(100, 2, false))), little = false)
        fun joined() = byteArrayOf(-1, -40) + segment(first) + segment(second) + byteArrayOf(-1, -39)
        assertEquals("16384", read(joined()).second.attribute(PreviewExifTag.PHOTOGRAPHIC_SENSITIVITY))
        second.copyOfRange(256, 274).copyInto(second, 384)
        number(384, 4, false).copyInto(second, 18)
        assertEquals("100", read(joined()).second.attribute(PreviewExifTag.PHOTOGRAPHIC_SENSITIVITY))
    }

    @Test fun primaryDateWinsOverDifferentEmbeddedThumbnailDirectory() {
        val bytes = tiff(root = listOf(ascii(0x0132, "2026:09:08 10:00:00")))
        number(768, 4).copyInto(bytes, 46)
        number(1, 2).copyInto(bytes, 768)
        number(0x0132, 2).copyInto(bytes, 770); number(2, 2).copyInto(bytes, 772)
        number(4, 4).copyInto(bytes, 774); byteArrayOf(78, 69, 87, 0).copyInto(bytes, 778)
        assertEquals("2026:09:08 10:00:00", read(bytes).second.attribute(PreviewExifTag.DATETIME))
    }
}
