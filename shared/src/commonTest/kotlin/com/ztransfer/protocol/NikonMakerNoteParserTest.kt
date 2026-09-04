package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class NikonMakerNoteParserTest {
    @Test
    fun parsesFileInfoWithIndependentValueByteOrder() {
        assertEquals(NikonMakerFileInfo(123, 4567), nikonMakerFileInfo(tiffFixture(true)))
        assertEquals(NikonMakerFileInfo(123, 4567), nikonMakerFileInfo(tiffFixture(false)))
    }

    @Test
    fun acceptsTheSameTiffInsideAJpegExifSegment() {
        val jpeg = jpegExif(tiffFixture(true))
        assertEquals(
            NikonMakerFileInfo(123, 4567),
            nikonMakerFileInfo(jpeg),
        )
        assertEquals(
            NikonMakerFileInfo(123, 4567),
            nikonMakerFileInfo(
                byteArrayOf(
                    0xFF.toByte(),
                    0xD8.toByte(),
                    0xFF.toByte(),
                    0xE0.toByte(),
                    0,
                    4,
                    1,
                    2,
                    *jpeg.copyOfRange(2, jpeg.size),
                ),
            ),
        )
        assertNull(nikonMakerFileInfo(jpeg.copyOf(jpeg.size - 5)))
        assertNull(nikonMakerFileInfo(jpeg.copyOf().also { it[6] = 'X'.code.toByte() }))
    }

    @Test
    fun truncatedOrStructurallyInvalidPrefixesFailClosed() {
        val valid = tiffFixture(true)
        assertNull(nikonMakerFileInfo(valid.copyOf(95)))
        assertNull(nikonMakerFileInfo(valid.copyOf(7)))
        assertNull(nikonMakerFileInfo(valid.copyOf().also { it[2] = 0 }))
        assertNull(nikonMakerFileInfo(valid.copyOf().also { it[44] = 'X'.code.toByte() }))
        assertNull(nikonMakerFileInfo(byteArrayOf(0xFF.toByte(), 0xD8.toByte())))
    }

    private fun tiffFixture(fileInfoLittleEndian: Boolean): ByteArray {
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

        "Nikon\u0000".encodeToByteArray().copyInto(bytes, 44)
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

        "0100".encodeToByteArray().copyInto(bytes, 86)
        putU16(90, 1, fileInfoLittleEndian)
        putU16(92, 123, fileInfoLittleEndian)
        putU16(94, 4567, fileInfoLittleEndian)
        return bytes
    }

    private fun jpegExif(tiff: ByteArray): ByteArray {
        val exifHeader = byteArrayOf(
            'E'.code.toByte(),
            'x'.code.toByte(),
            'i'.code.toByte(),
            'f'.code.toByte(),
            0,
            0,
        )
        val segmentLength = 2 + exifHeader.size + tiff.size
        return byteArrayOf(
            0xFF.toByte(),
            0xD8.toByte(),
            0xFF.toByte(),
            0xE1.toByte(),
            (segmentLength ushr 8).toByte(),
            segmentLength.toByte(),
            *exifHeader,
            *tiff,
            0xFF.toByte(),
            0xD9.toByte(),
        )
    }
}
