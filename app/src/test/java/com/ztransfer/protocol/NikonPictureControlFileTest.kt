package com.ztransfer.protocol

import java.io.File
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.util.concurrent.CancellationException
import org.junit.Assert.*
import org.junit.Test

class NikonPictureControlFileTest {
    private fun sample(): ByteArray = File("src/main/assets/picture_controls/Kodak Ektar Green.NP3").readBytes()

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
