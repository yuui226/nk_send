package com.ztransfer.frame

import com.ztransfer.crop.parseJpegCropHeader
import com.ztransfer.crop.parseJpegCropOrientation
import com.ztransfer.viewmodel.JpegMetadataHeader
import com.ztransfer.viewmodel.inspectJpegMetadataHeader
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException
import org.junit.Assert.*
import org.junit.Test

class PhotoEffectIdentityJpegTest {
    private val identity = "0123456789abcdef".repeat(4)

    @Test fun bulkWritePreservesEveryOriginalJpegByte() {
        val original = jpeg()
        val encoded = encode(original)
        assertEquals(identity, PhotoEffectIdentityJpeg.read(encoded.inputStream()))
        val metadataStart = metadataStart(encoded)
        assertEquals(0xff, encoded[metadataStart].toInt() and 0xff)
        assertEquals(0xef, encoded[metadataStart + 1].toInt() and 0xff)
        val metadataEnd = metadataStart + 2 + unsignedShort(encoded, metadataStart + 2)
        assertArrayEquals(original, encoded.copyOfRange(0, metadataStart) + encoded.copyOfRange(metadataEnd, encoded.size))
    }

    @Test fun headerCanArriveOneByteAtATime() {
        val original = jpeg()
        val output = ByteArrayOutputStream()
        PhotoEffectIdentityJpeg.outputStream(output, identity).use { writer ->
            original.forEach { writer.write(it.toInt()) }
        }
        assertArrayEquals(encode(original), output.toByteArray())
    }

    @Test fun splitHeaderAndOffsetBulkWritesAreSupported() {
        val original = jpeg()
        val output = ByteArrayOutputStream()
        PhotoEffectIdentityJpeg.outputStream(output, identity).use { writer ->
            writer.write(byteArrayOf(0, original[0], 0), 1, 1)
            writer.write(byteArrayOf(), 0, 0)
            writer.write(original, 1, original.size - 1)
        }
        assertArrayEquals(encode(original), output.toByteArray())
    }

    @Test fun bulkImageWriteDoesNotDegenerateIntoByteWrites() {
        var bulkCalls = 0
        val output = object : ByteArrayOutputStream() {
            override fun write(bytes: ByteArray, offset: Int, length: Int) {
                bulkCalls++
                super.write(bytes, offset, length)
            }
            override fun write(value: Int) = fail("A bulk JPEG must stay bulk-written")
        }
        PhotoEffectIdentityJpeg.outputStream(output, identity).use { it.write(jpeg()) }
        assertEquals(3, bulkCalls) // Original APP0, identity metadata, remaining image.
    }

    @Test fun fingerprintMustBeExactly64LowercaseHexCharacters() {
        for (invalid in listOf("", identity.dropLast(1), identity + "0", identity.uppercase(), "g".repeat(64))) {
            assertThrows(IllegalArgumentException::class.java) {
                PhotoEffectIdentityJpeg.outputStream(ByteArrayOutputStream(), invalid)
            }
        }
    }

    @Test fun emptyAndTruncatedHeadersFailOnCloseAndCloseDelegate() {
        for (header in listOf(
            byteArrayOf(),
            byteArrayOf(0xff.toByte()),
            byteArrayOf(0xff.toByte(), 0xd8.toByte()),
            byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte()),
            byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte(), 0xe0.toByte(), 0, 8, 1),
        )) {
            var closed = false
            val output = object : ByteArrayOutputStream() {
                override fun close() { closed = true }
            }
            val writer = PhotoEffectIdentityJpeg.outputStream(output, identity)
            writer.write(header)
            assertThrows(IOException::class.java) { writer.close() }
            assertTrue(closed)
            assertEquals(0, output.size())
            writer.close() // Closing again is harmless.
        }
    }

    @Test fun nonJpegHeaderIsRejectedBeforeWritingAnything() {
        for (header in listOf(byteArrayOf(0, 1), byteArrayOf(0xff.toByte(), 0xe0.toByte()))) {
            val output = ByteArrayOutputStream()
            val writer = PhotoEffectIdentityJpeg.outputStream(output, identity)
            assertThrows(IOException::class.java) { writer.write(header) }
            writer.close()
            assertEquals(0, output.size())
        }
    }

    @Test fun foreignApp15AndLargeExifSegmentsAreSkipped() {
        val encoded = encode(jpeg())
        val ourSegmentLength = unsignedShort(encoded, metadataStart(encoded) + 2) - 2
        val foreign = segment(0xef, ByteArray(ourSegmentLength) { 'x'.code.toByte() })
        val exif = segment(0xe1, ByteArray(65533) { 42 })
        val decorated = encoded.copyOfRange(0, 2) + foreign + exif + encoded.copyOfRange(2, encoded.size)
        assertEquals(identity, PhotoEffectIdentityJpeg.read(decorated.inputStream()))
        // Some document providers cannot skip; reading forward must still work.
        val cannotSkip = object : ByteArrayInputStream(decorated) {
            override fun skip(count: Long): Long = 0
        }
        assertEquals(identity, PhotoEffectIdentityJpeg.read(cannotSkip))
    }

    @Test fun paddedMarkersAndStandaloneMarkersAreSupported() {
        val encoded = encode(jpeg())
        val padding = byteArrayOf(0xff.toByte(), 0xff.toByte(), 0x01, 0xff.toByte(), 0xd0.toByte(), 0xff.toByte())
        val decorated = encoded.copyOfRange(0, 2) + padding + encoded.copyOfRange(2, encoded.size)
        assertEquals(identity, PhotoEffectIdentityJpeg.read(decorated.inputStream()))
    }

    @Test fun missingWrongVersionAndMalformedFingerprintsDoNotMatch() {
        assertNull(PhotoEffectIdentityJpeg.read(jpeg().inputStream()))
        val encoded = encode(jpeg())
        val metadataStart = metadataStart(encoded)
        val wrongNamespace = encoded.copyOf().apply { this[metadataStart + 4] = 'X'.code.toByte() }
        assertNull(PhotoEffectIdentityJpeg.read(wrongNamespace.inputStream()))
        val wrongVersion = encoded.copyOf().apply {
            val version = String(this, Charsets.ISO_8859_1).indexOf("v1")
            this[version + 1] = '2'.code.toByte()
        }
        assertNull(PhotoEffectIdentityJpeg.read(wrongVersion.inputStream()))
        val invalidIdentity = encoded.copyOf().apply {
            this[metadataStart + 2 + unsignedShort(this, metadataStart + 2) - 1] = 'g'.code.toByte()
        }
        assertNull(PhotoEffectIdentityJpeg.read(invalidIdentity.inputStream()))
    }

    @Test fun truncationAndInvalidSegmentLengthsReturnNull() {
        val encoded = encode(jpeg())
        val metadataStart = metadataStart(encoded)
        val metadataEnd = metadataStart + 2 + unsignedShort(encoded, metadataStart + 2)
        for (length in 0 until metadataEnd) {
            assertNull("Truncated at $length", PhotoEffectIdentityJpeg.read(encoded.copyOf(length).inputStream()))
        }
        for (header in listOf(
            byteArrayOf(0, 1),
            byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte(), 0xe1.toByte(), 0, 1),
            byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte(), 0x00),
            byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0x01, 0xe1.toByte()),
        )) {
            assertNull(PhotoEffectIdentityJpeg.read(header.inputStream()))
        }
    }

    @Test fun parserStopsAtImageDataAndDoesNotCloseInput() {
        val encoded = encode(jpeg())
        val hiddenAfterSos = byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte(), 0xda.toByte()) +
            encoded.copyOfRange(2, encoded.size)
        var closed = false
        val input = object : ByteArrayInputStream(hiddenAfterSos) {
            override fun close() { closed = true }
        }
        assertNull(PhotoEffectIdentityJpeg.read(input))
        assertEquals(hiddenAfterSos.size - 4, input.available())
        assertFalse(closed)
    }

    @Test fun excessiveMetadataIsBounded() {
        val output = ByteArrayOutputStream()
        output.write(byteArrayOf(0xff.toByte(), 0xd8.toByte()))
        val largeSegment = segment(0xe1, ByteArray(65533))
        repeat(65) { output.write(largeSegment) }
        output.write(encode(jpeg()).drop(2).toByteArray())
        val input = ByteArrayInputStream(output.toByteArray())
        assertNull(PhotoEffectIdentityJpeg.read(input))
        assertTrue(output.size() - input.available() <= 4 * 1024 * 1024)
        assertTrue(input.available() > 0)
    }

    @Test fun interruptedIoIsNotMistakenForMissingIdentity() {
        val input = object : InputStream() {
            override fun read(): Int = throw InterruptedIOException("Interrupted")
        }
        assertThrows(InterruptedIOException::class.java) { PhotoEffectIdentityJpeg.read(input) }
    }

    @Test fun jfifStaysFirstAndExifOnEitherSideOfIdentityIsReadable() {
        val original = jpeg()
        assertEquals(0xe0, original[3].toInt() and 0xff)
        val app0End = 4 + unsignedShort(original, 4)
        val encoded = encode(original)
        assertArrayEquals(original.copyOf(app0End), encoded.copyOf(app0End))
        val exif = segment(0xe1, "Exif\u0000\u0000".toByteArray())
        val withExifFirst = original.copyOfRange(0, 2) + exif + original.copyOfRange(2, original.size)
        val identityBeforeExif = encode(withExifFirst)
        assertEquals(0xef, identityBeforeExif[3].toInt() and 0xff)
        assertEquals(identity, PhotoEffectIdentityJpeg.read(identityBeforeExif.inputStream()))
        val exifBeforeIdentity = encoded.copyOfRange(0, app0End) + exif + encoded.copyOfRange(app0End, encoded.size)
        assertEquals(identity, PhotoEffectIdentityJpeg.read(exifBeforeIdentity.inputStream()))
    }

    @Test fun effectIdentityPreservesCropDimensionsAndExifOrientationReaders() {
        val original = jpeg()
        val encoded = encode(original)
        assertEquals(parseJpegCropHeader(original), parseJpegCropHeader(encoded))
        assertEquals(1, parseJpegCropOrientation(encoded))
        assertEquals(JpegMetadataHeader.NO_EXIF, inspectJpegMetadataHeader(encoded))

        for (orientation in 1..8) {
            // Little-endian TIFF with one SHORT orientation entry and no next IFD.
            val exif = segment(0xe1, "Exif\u0000\u0000".toByteArray() + byteArrayOf(
                0x49, 0x49, 42, 0, 8, 0, 0, 0,
                1, 0, 0x12, 1, 3, 0, 1, 0, 0, 0,
                orientation.toByte(), 0, 0, 0, 0, 0, 0, 0,
            ))
            val withExif = original.copyOfRange(0, 2) + exif + original.copyOfRange(2, original.size)
            val withIdentity = encode(withExif)
            val expected = checkNotNull(parseJpegCropHeader(withExif))
            assertEquals(12, expected.width)
            assertEquals(9, expected.height)
            assertEquals(orientation, expected.orientation)
            assertEquals(expected, parseJpegCropHeader(withIdentity))
            assertEquals(orientation, parseJpegCropOrientation(withIdentity))
            assertEquals(JpegMetadataHeader.EXIF_COMPLETE, inspectJpegMetadataHeader(withIdentity))
        }
    }

    private fun encode(jpeg: ByteArray): ByteArray {
        val output = ByteArrayOutputStream()
        PhotoEffectIdentityJpeg.outputStream(output, identity).use { it.write(jpeg) }
        return output.toByteArray()
    }

    private fun segment(marker: Int, payload: ByteArray): ByteArray {
        val length = payload.size + 2
        return byteArrayOf(
            0xff.toByte(), marker.toByte(), (length ushr 8).toByte(), length.toByte(),
        ) + payload
    }

    private fun unsignedShort(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xff) shl 8) or (bytes[offset + 1].toInt() and 0xff)

    private fun metadataStart(bytes: ByteArray): Int =
        if (bytes[3].toInt() and 0xff == 0xe0) 4 + unsignedShort(bytes, 4) else 2

    // A fixed 12 × 9 JPEG keeps these Android unit tests independent of Java desktop APIs.
    private fun jpeg(): ByteArray =
        checkNotNull(javaClass.getResourceAsStream("/photo-effects/sample.jpg")).use { it.readBytes() }
}
