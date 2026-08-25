package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StaDirectObjectMetadataTest {
    @Test
    fun detectsCommonNikonMediaTypesFromOriginalHeader() {
        assertEquals(".jpg", staDirectObjectExtension(byteArrayOf(0xFF.toByte(), 0xD8.toByte())))
        assertEquals(".nef", staDirectObjectExtension(byteArrayOf('I'.code.toByte(), 'I'.code.toByte(), 0x2A, 0)))
        assertEquals(
            ".mov",
            staDirectObjectExtension(byteArrayOf(0, 0, 0, 0, 'f'.code.toByte(), 't'.code.toByte(), 'y'.code.toByte(), 'p'.code.toByte(), 'q'.code.toByte(), 't'.code.toByte(), 0x20, 0x20)),
        )
        assertEquals(".bin", staDirectObjectExtension(byteArrayOf(1, 2, 3, 4)))
    }

    @Test
    fun normalizesExifDateForExistingPhotoGrouping() {
        assertEquals("20260824T135715", staDirectCaptureDate("2026:08:24 13:57:15"))
        assertNull(staDirectCaptureDate("2026:08"))
        assertNull(staDirectCaptureDate(null))
    }

    @Test
    fun extractsCompleteExifApp1IntoMinimalJpeg() {
        val exifPayload = "Exif\u0000\u0000sample".toByteArray()
        val segmentLength = exifPayload.size + 2
        val source = byteArrayOf(
            0xFF.toByte(), 0xD8.toByte(),
            0xFF.toByte(), 0xE1.toByte(),
            (segmentLength ushr 8).toByte(), segmentLength.toByte(),
            *exifPayload,
            0xFF.toByte(), 0xDA.toByte(),
        )

        val envelope = requireNotNull(jpegExifEnvelope(source))

        assertEquals(0xFF.toByte(), envelope[0])
        assertEquals(0xD8.toByte(), envelope[1])
        assertEquals(0xFF.toByte(), envelope[envelope.lastIndex - 1])
        assertEquals(0xD9.toByte(), envelope[envelope.lastIndex])
        assertNull(jpegExifEnvelope(source.copyOf(source.size - 5)))
    }

    @Test
    fun parsesFhdPreviewFromJpegMpfIndex() {
        val bytes = ByteArray(82)
        fun putU16(offset: Int, value: Int) {
            bytes[offset] = value.toByte()
            bytes[offset + 1] = (value ushr 8).toByte()
        }
        fun putU32(offset: Int, value: Long) {
            repeat(4) { index -> bytes[offset + index] = (value ushr (index * 8)).toByte() }
        }

        bytes[0] = 0xFF.toByte()
        bytes[1] = 0xD8.toByte()
        bytes[2] = 0xFF.toByte()
        bytes[3] = 0xE2.toByte()
        // 2-byte length field + 74-byte payload; next marker starts at offset 80.
        bytes[4] = 0
        bytes[5] = 76
        "MPF\u0000".toByteArray().copyInto(bytes, 6)
        val tiffBase = 10
        bytes[tiffBase] = 'I'.code.toByte()
        bytes[tiffBase + 1] = 'I'.code.toByte()
        putU16(tiffBase + 2, 42)
        putU32(tiffBase + 4, 8)
        val ifd = tiffBase + 8
        putU16(ifd, 2)
        // NumberOfImages = 2.
        putU16(ifd + 2, 0xB001)
        putU16(ifd + 4, 4)
        putU32(ifd + 6, 1)
        putU32(ifd + 10, 2)
        // MPEntry list: two 16-byte records at TIFF-relative offset 38.
        putU16(ifd + 14, 0xB002)
        putU16(ifd + 16, 7)
        putU32(ifd + 18, 32)
        putU32(ifd + 22, 38)
        val entries = tiffBase + 38
        putU32(entries, 0x030000)
        putU32(entries + 4, 1_000_000)
        putU32(entries + 8, 0)
        putU32(entries + 16, 0x010002)
        putU32(entries + 20, 123_456)
        putU32(entries + 24, 500_000)
        bytes[80] = 0xFF.toByte()
        bytes[81] = 0xDA.toByte()

        assertEquals(
            listOf(JpegMpfPreviewReference(500_010, 123_456, 0x010002)),
            parseJpegMpfPreviews(bytes, objectSize = 1_000_000),
        )
        assertEquals(emptyList<JpegMpfPreviewReference>(), parseJpegMpfPreviews(bytes, 600_000))
    }

    @Test
    fun extractsLargestCompleteJpegFromRawPrefix() {
        val small = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 1, 0xFF.toByte(), 0xD9.toByte())
        val large = byteArrayOf(
            0xFF.toByte(), 0xD8.toByte(), 1, 2, 3, 4, 0xFF.toByte(), 0xD9.toByte(),
        )
        val raw = byteArrayOf(9, 9, *small, 8, 8, *large, 7)

        assertEquals(large.toList(), largestEmbeddedJpeg(raw)?.toList())
        assertNull(largestEmbeddedJpeg(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 1, 2)))
    }

    @Test
    fun parsesQuickTimeMovieCreationTime() {
        val unixSeconds = 1_777_000_000L
        val quickTimeSeconds = unixSeconds + 2_082_844_800L
        val mvhd = ByteArray(16)
        "mvhd".toByteArray().copyInto(mvhd)
        repeat(4) { offset ->
            mvhd[8 + offset] = (quickTimeSeconds ushr ((3 - offset) * 8)).toByte()
        }

        val parsed = staDirectVideoCaptureDate(mvhd)

        org.junit.Assert.assertNotNull(parsed)
        assertEquals(15, parsed?.length)
        assertNull(staDirectVideoCaptureDate("no movie metadata".toByteArray()))
    }

    @Test
    fun parsesNefDateAndExactEmbeddedPreviewRange() {
        val bytes = ByteArray(120)
        fun putU16(offset: Int, value: Int) {
            bytes[offset] = value.toByte()
            bytes[offset + 1] = (value ushr 8).toByte()
        }
        fun putU32(offset: Int, value: Long) {
            repeat(4) { index -> bytes[offset + index] = (value ushr (index * 8)).toByte() }
        }
        bytes[0] = 'I'.code.toByte()
        bytes[1] = 'I'.code.toByte()
        putU16(2, 42)
        putU32(4, 8)
        putU16(8, 2)
        // DateTime -> ASCII at offset 40.
        putU16(10, 0x0132)
        putU16(12, 2)
        putU32(14, 20)
        putU32(18, 40)
        "2026:08:18 00:00:16\u0000".toByteArray().copyInto(bytes, 40)
        // SubIFD -> offset 80.
        putU16(22, 0x014A)
        putU16(24, 4)
        putU32(26, 1)
        putU32(30, 80)
        putU16(80, 2)
        putU16(82, 0x0201)
        putU16(84, 4)
        putU32(86, 1)
        putU32(90, 300_000)
        putU16(94, 0x0202)
        putU16(96, 4)
        putU32(98, 1)
        putU32(102, 1_068_298)

        val metadata = parseNefHeaderMetadata(bytes)

        assertEquals("20260818T000016", metadata.captureDate)
        assertEquals(listOf(NefPreviewReference(300_000, 1_068_298)), metadata.previews)
    }

    @Test
    fun parsesNikonMakerFileInfoWithIndependentByteOrder() {
        fun fixture(fileInfoLittleEndian: Boolean): ByteArray {
            val bytes = ByteArray(96)
            fun putU16(offset: Int, value: Int, littleEndian: Boolean = true) {
                if (littleEndian) {
                    bytes[offset] = value.toByte()
                    bytes[offset + 1] = (value ushr 8).toByte()
                } else {
                    bytes[offset] = (value ushr 8).toByte()
                    bytes[offset + 1] = value.toByte()
                }
            }
            fun putU32(offset: Int, value: Long) {
                repeat(4) { index -> bytes[offset + index] = (value ushr (index * 8)).toByte() }
            }

            bytes[0] = 'I'.code.toByte()
            bytes[1] = 'I'.code.toByte()
            putU16(2, 42)
            putU32(4, 8)
            putU16(8, 1)
            putU16(10, 0x8769)
            putU16(12, 4)
            putU32(14, 1)
            putU32(18, 26)

            putU16(26, 1)
            putU16(28, 0x927C)
            putU16(30, 7)
            putU32(32, 52)
            putU32(36, 44)

            "Nikon\u0000".toByteArray().copyInto(bytes, 44)
            bytes[50] = 2
            bytes[51] = 0x10
            bytes[54] = 'I'.code.toByte()
            bytes[55] = 'I'.code.toByte()
            putU16(56, 42)
            putU32(58, 8)
            putU16(62, 1)
            putU16(64, 0x00B8)
            putU16(66, 7)
            putU32(68, 10)
            putU32(72, 32)

            "0100".toByteArray().copyInto(bytes, 86)
            putU16(90, 1, fileInfoLittleEndian)
            putU16(92, 123, fileInfoLittleEndian)
            putU16(94, 4567, fileInfoLittleEndian)
            return bytes
        }

        assertEquals(NikonMakerFileInfo(123, 4567), nikonMakerFileInfo(fixture(true)))
        assertEquals(NikonMakerFileInfo(123, 4567), nikonMakerFileInfo(fixture(false)))
        assertNull(nikonMakerFileInfo(fixture(true).copyOf(95)))
    }

    @Test
    fun derivesNikonFileNumbersAcrossMediaHandleTypes() {
        val anchor = NikonFileNumberAnchor(
            handleSequence = 0x1961F5,
            directoryNumber = 101,
            fileNumber = 8693,
        )

        assertEquals(
            NikonMakerFileInfo(101, 8692),
            deriveNikonMakerFileInfo(anchor, 0x611961F4),
        )
        assertEquals(
            NikonMakerFileInfo(101, 8679),
            deriveNikonMakerFileInfo(anchor, 0x091961E7),
        )
        assertEquals(
            "DSC_8692.MP4",
            nikonDefaultCameraFileName(NikonMakerFileInfo(101, 8692), ".mp4"),
        )
    }

    @Test
    fun parsesNikonBulkObjectDatesAndRejectsIncompleteLayouts() {
        val payload = ByteArray(8 + 2 * 16)
        fun putU32(offset: Int, value: Int) {
            repeat(4) { index -> payload[offset + index] = (value ushr (index * 8)).toByte() }
        }
        fun putRecord(offset: Int, handle: Int, year: Int, month: Int, day: Int,
                      hour: Int, minute: Int, second: Int) {
            putU32(offset, handle)
            payload[offset + 9] = second.toByte()
            payload[offset + 10] = minute.toByte()
            payload[offset + 11] = hour.toByte()
            payload[offset + 12] = day.toByte()
            payload[offset + 13] = month.toByte()
            payload[offset + 14] = year.toByte()
            payload[offset + 15] = (year ushr 8).toByte()
        }
        putU32(0, 100)
        putU32(4, 2)
        putRecord(8, 0x291961F5, 2026, 8, 24, 20, 45, 40)
        putRecord(24, 0x611961F4, 2026, 8, 23, 14, 56, 45)

        assertEquals(
            mapOf(
                0x291961F5 to "20260824T204540",
                0x611961F4 to "20260823T145645",
            ),
            parseNikonObjectsMetadataCaptureDates(payload),
        )
        assertEquals(emptyMap<Int, String>(), parseNikonObjectsMetadataCaptureDates(payload.copyOf(payload.size - 1)))
    }

    @Test
    fun mapsOnlyObservedPairedStaHandleKinds() {
        assertEquals(".jpg", staDirectExtensionFromHandle(0x291961F5))
        assertEquals(".nef", staDirectExtensionFromHandle(0x091961E7))
        assertEquals(".mp4", staDirectExtensionFromHandle(0x611961F4))
        assertNull(staDirectExtensionFromHandle(0x7F1961F4))
    }
}
