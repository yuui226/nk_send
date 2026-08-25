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
}
