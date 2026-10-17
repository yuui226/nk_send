package com.ztransfer.protocol

import java.io.File
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.util.concurrent.CancellationException
import org.junit.Assert.*
import org.junit.Test

class NikonPictureControlFileTest {
    private fun sample(): ByteArray = File("src/main/assets/picture_controls/Kodak Ektar Green.NP3").readBytes()
    private fun flexibleColor(name: String = "vanilla"): ByteArray =
        javaClass.getResourceAsStream("/picture_control/flexible-color/$name.NP3")!!.use { it.readBytes() }

    @Test fun realFlexibleColorFilesHaveTheirOwnUnsupportedReason() {
        for (name in listOf("vanilla", "tonecurve-noop", "comment-a")) {
            val bytes = flexibleColor(name)
            assertThrows(NikonFlexibleColorUnsupportedException::class.java) {
                NikonPictureControlFile.parse(bytes)
            }
            assertThrows(NikonFlexibleColorUnsupportedException::class.java) {
                NikonPictureControlFile.read(ByteArrayInputStream(bytes))
            }
        }
    }

    @Test fun damagedFlexibleColorContainersAreStillInvalidFiles() {
        val bytes = flexibleColor()
        fun assertInvalid(data: ByteArray) {
            val error = assertThrows(IllegalArgumentException::class.java) {
                NikonPictureControlFile.parse(data)
            }
            assertFalse(error is NikonFlexibleColorUnsupportedException)
        }
        for (length in 0 until bytes.size) assertInvalid(bytes.copyOf(length))
        assertInvalid(bytes + 0)
        assertInvalid(bytes.copyOf().apply { this[0] = 0 })
        assertInvalid(bytes.copyOf().apply { this[8] = 0x7f })
        // Repeat the version field before the terminator: duplicate TLVs are corrupt.
        assertInvalid(bytes.dropLast(4).toByteArray() + bytes.copyOfRange(4, 16) + ByteArray(4))
    }

    @Test fun aNewVersionAloneDoesNotIdentifyFlexibleColor() {
        for (version in listOf("0301", "0310", "0399")) {
            // The classic fixture starts with a four-byte version TLV at offset 12.
            val bytes = sample().apply { version.toByteArray(Charsets.US_ASCII).copyInto(this, 12) }
            val parsed = NikonPictureControlFile.parse(bytes)
            assertEquals(version, parsed.version)
            val error = assertThrows(IllegalArgumentException::class.java) {
                parsed.encodeClassicPictureControl()
            }
            assertFalse(error is NikonFlexibleColorUnsupportedException)
        }
    }

    @Test fun bundledFilesPreserveEveryByte() {
        val directory = File("src/main/assets/picture_controls")
        val files = directory.listFiles()!!.filter { it.extension == "NP3" }
        assertEquals(22, files.size) // 20 displayed presets and two unlisted research samples.
        files.forEach { file ->
            val bytes = file.readBytes()
            val parsed = NikonPictureControlFile.parse(bytes)
            assertEquals(file.nameWithoutExtension, parsed.name)
            assertEquals("0300", parsed.version)
            assertArrayEquals(bytes, parsed.bytes())
            assertEquals(64, parsed.sha256.length)
        }
    }

    @Test fun truncatedOrOversizedFieldsCannotBeAccepted() {
        val bytes = sample()
        for (length in 0 until bytes.size) {
            assertThrows(IllegalArgumentException::class.java) {
                NikonPictureControlFile.parse(bytes.copyOf(length))
            }
        }
        val badLength = bytes.copyOf().apply { this[8] = 0x7f }
        assertThrows(IllegalArgumentException::class.java) { NikonPictureControlFile.parse(badLength) }
        assertThrows(IllegalArgumentException::class.java) { NikonPictureControlFile.parse(bytes + 0) }
    }

    @Test fun assetBuffersCannotMutateTheValidatedPreset() {
        val bytes = sample()
        val parsed = NikonPictureControlFile.parse(bytes)
        val digest = parsed.sha256
        bytes.fill(0)
        parsed.bytes().fill(0)
        parsed.field(0x200)!!.fill(0)
        assertEquals("Kodak Ektar Green", parsed.name)
        assertEquals(digest, parsed.sha256)
    }

    @Test fun providerStreamCanReturnSmallChunksWithoutChangingThePreset() {
        val bytes = sample()
        val stream = object : ByteArrayInputStream(bytes) {
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
                super.read(buffer, offset, minOf(length, 7))
        }
        assertArrayEquals(bytes, NikonPictureControlFile.read(stream).bytes())
    }

    @Test fun oversizedProviderStreamIsStoppedBeforeReadingTheWholeDocument() {
        var consumed = 0
        val stream = object : InputStream() {
            override fun read(): Int { consumed++; return 0 }
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                consumed += length
                buffer.fill(0, offset, offset + length)
                return length
            }
        }
        assertThrows(IllegalArgumentException::class.java) { NikonPictureControlFile.read(stream) }
        assertEquals(NikonPictureControlFile.MAX_BYTES + 1, consumed)
    }

    @Test fun stalledProviderStreamDoesNotLoopForever() {
        val stream = object : InputStream() {
            override fun read(): Int = 0
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int = 0
        }
        assertThrows(IllegalArgumentException::class.java) { NikonPictureControlFile.read(stream) }
    }

    @Test fun cancellationStopsBeforeReadingAnotherChunk() {
        val stream = ByteArrayInputStream(sample())
        assertThrows(CancellationException::class.java) {
            NikonPictureControlFile.read(stream) { throw CancellationException() }
        }
        assertEquals(sample().size, stream.available())
    }
}
