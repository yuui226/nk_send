package com.ztransfer.filter

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CancellationException
import org.junit.Assert.*
import org.junit.Test

class PhotoNp3ParserTest {
    @Test fun independentFlexibleColorSamplesIncludeCommentsAndToneCurves() {
        val vanilla = PhotoNp3Parser.parse(sample("vanilla"))
        assertEquals("vanilla", vanilla.preset.name)
        assertEquals("1199d1e5ca7a1d0b39273e70be05d590ce1ee9fb6378f12e73aa91320d064483", vanilla.sourceSha256)
        assertEquals("np3:${vanilla.sourceSha256}:np3-srgb-v1", vanilla.preset.id)
        assertTrue(vanilla.ignoredDetailControls)
        val neutral = parameters(vanilla)
        assertEquals(listOf(0, 0, 0, 0, 0, 0), controls(neutral))
        assertNull(neutral.toneCurve)
        assertTrue(neutral.colorBands.all { it.hue == 0 && it.chroma == 0 && it.brightness == 0 })

        val comment = PhotoNp3Parser.parse(sample("comment-a"))
        assertEquals("comment-a", comment.preset.name)
        assertEquals(controls(neutral), controls(parameters(comment)))
        assertEquals(neutral.colorBands, parameters(comment).colorBands)

        val curved = parameters(PhotoNp3Parser.parse(sample("tonecurve-noop")))
        // A curve owns all five tonal fields, whose serialized value is 1 rather than 128.
        assertEquals(listOf(0, 0, 0, 0, 0, 0), controls(curved))
        val curve = requireNotNull(curved.toneCurve)
        assertEquals(257, curve.size)
        assertEquals(0, curve.first())
        assertEquals(16384, curve[128])
        assertEquals(32767, curve.last())
    }

    @Test fun readsAllSixControlsAndAllEightColorBandsWithoutClamping() {
        val fields = fields(sample())
        val expectedControls = listOf(-27, 13, 100, -100, 8, 64)
        (0x1900..0x1E00 step 0x100).forEachIndexed { index, tag ->
            fields.getValue(tag)[0] = setting(expectedControls[index])
        }
        val expectedBands = PHOTO_FILTER_COLOR_BAND_CENTERS.mapIndexed { index, center ->
            PhotoFilterColorBand(center, index * 10 - 35, 100 - index * 20, index * 5 - 15)
        }
        expectedBands.forEachIndexed { index, band ->
            fields.getValue(0x1F00)[index * 3] = setting(band.hue)
            fields.getValue(0x1F00)[index * 3 + 1] = setting(band.chroma)
            fields.getValue(0x1F00)[index * 3 + 2] = setting(band.brightness)
        }
        val parsed = parameters(PhotoNp3Parser.parse(encode(fields)))
        assertEquals(expectedControls, controls(parsed))
        assertEquals(expectedBands, parsed.colorBands)
    }

    @Test fun tagsMayBeReorderedAndCommentsMayPrecedeCurveOrName() {
        val original = fields(sample("tonecurve-noop"))
        original[0x10100] = byteArrayOf('a'.code.toByte(), 0)
        val reordered = original.entries.reversed().associateTo(linkedMapOf()) { it.key to it.value }
        val parsed = PhotoNp3Parser.parse(encode(reordered))
        assertEquals("tonecurve-noop", parsed.preset.name)
        assertArrayEquals(parameters(PhotoNp3Parser.parse(sample("tonecurve-noop"))).toneCurve,
            parameters(parsed).toneCurve)
    }

    @Test fun corruptContainersRemainInvalidRegardlessOfSupportedProfile() {
        val bytes = sample()
        for (length in 0 until bytes.size) assertFailure(PhotoNp3Failure.INVALID, bytes.copyOf(length))
        assertFailure(PhotoNp3Failure.INVALID, bytes + 0)
        assertFailure(PhotoNp3Failure.INVALID, bytes.copyOf().apply { this[0] = 0 })
        assertFailure(PhotoNp3Failure.INVALID, bytes.copyOf().apply { this[8] = 0x7f })
        assertFailure(PhotoNp3Failure.INVALID, bytes.copyOf().apply { this[8] = -1 })
        assertFailure(PhotoNp3Failure.INVALID,
            bytes.dropLast(4).toByteArray() + bytes.copyOfRange(4, 16) + ByteArray(4))
    }

    @Test fun missingOrWrongSizedFieldsAreInvalid() {
        for (tag in listOf(0x0100, 0x0200, 0x0300, 0x0600, 0x1900, 0x1F00, 0x2000)) {
            assertFailure(PhotoNp3Failure.INVALID, changed { remove(tag) })
            assertFailure(PhotoNp3Failure.INVALID, changed { this[tag] = getValue(tag).dropLast(1).toByteArray() })
        }
        assertFailure(PhotoNp3Failure.INVALID, changed { this[0x10100] = byteArrayOf(1, 2, 3) })
        assertFailure(PhotoNp3Failure.INVALID, changed { this[0x10100] = byteArrayOf(1, 2) })
    }

    @Test fun classicProfilesAreRoutedSeparatelyAndUnknownFlexibleProfilesRemainUnsupported() {
        assertTrue(PhotoNp3Parser.parse(
            File("src/main/assets/picture_controls/Kodak Ektar Green.NP3").readBytes(),
        ).preset.parameters is ClassicNp3PhotoFilterParameters)
        for (version in listOf("0300", "0301", "0399", "0100")) {
            assertFailure(PhotoNp3Failure.UNSUPPORTED, changed { this[0x0100] = version.toByteArray() })
        }
        // A neutral 0310 container is also valid for a classic base; version alone is not the type.
        assertTrue(PhotoNp3Parser.parse(changed { this[0x0300] = byteArrayOf(0, 1) })
            .preset.parameters is ClassicNp3PhotoFilterParameters)
        assertFailure(PhotoNp3Failure.UNSUPPORTED, changed { this[0x0300] = byteArrayOf(0x7f, 0x7f) })
    }

    @Test fun unknownAdjustmentsAndEncodingsCannotBeSilentlyDropped() {
        assertFailure(PhotoNp3Failure.UNSUPPORTED, changed { this[0x2100] = byteArrayOf(128.toByte(), 1) })
        assertFailure(PhotoNp3Failure.UNSUPPORTED, changed { getValue(0x1900)[1] = 4 })
        assertFailure(PhotoNp3Failure.UNSUPPORTED, changed { getValue(0x0800)[0] = 128.toByte() })
        assertFailure(PhotoNp3Failure.UNSUPPORTED, changed { getValue(0x1400)[0] = 129.toByte() })
        assertFailure(PhotoNp3Failure.UNSUPPORTED, changed { getValue(0x1F00)[24] = 2 })
        assertFailure(PhotoNp3Failure.UNSUPPORTED, changed { getValue(0x2000)[12] = 2 })
    }

    @Test fun activeColorGradingIsUnsupportedEvenIfOtherControlsAreSupported() {
        for (offset in listOf(2, 3, 6, 7, 10, 11)) {
            assertFailure(PhotoNp3Failure.UNSUPPORTED, changed { getValue(0x2000)[offset] = setting(1) })
        }
        // A hue or blend setting with zero chroma and brightness contributes no visible grading.
        val neutral = changed {
            getValue(0x2000)[1] = 120
            getValue(0x2000)[16] = setting(80)
            getValue(0x2000)[18] = setting(-40)
        }
        assertEquals(controls(parameters(PhotoNp3Parser.parse(sample()))), controls(parameters(PhotoNp3Parser.parse(neutral))))
    }

    @Test fun outOfRangeValuesAreRejectedInsteadOfClamped() {
        for (value in listOf(-101, 101)) {
            for (tag in 0x1900..0x1E00 step 0x100) {
                assertFailure(PhotoNp3Failure.INVALID, changed { getValue(tag)[0] = setting(value) })
            }
            for (offset in 0 until 24) {
                assertFailure(PhotoNp3Failure.INVALID, changed { getValue(0x1F00)[offset] = setting(value) })
            }
        }
        assertFailure(PhotoNp3Failure.INVALID, changed { getValue(0x0600)[0] = setting(37) })
        assertFailure(PhotoNp3Failure.INVALID, changed { getValue(0x0700)[0] = setting(-21) })
        assertFailure(PhotoNp3Failure.INVALID, changed { getValue(0x1600)[0] = setting(21) })
        assertFailure(PhotoNp3Failure.INVALID, changed { getValue(0x2000)[16] = setting(-1) })
        assertFailure(PhotoNp3Failure.INVALID, changed { getValue(0x2000)[0] = 129.toByte(); getValue(0x2000)[1] = 127 })
    }

    @Test fun detailControlsAreExplicitlyRecognizedButDoNotChangeColorParameters() {
        val bytes = changed {
            for (tag in listOf(0x0600, 0x0700, 0x1600)) getValue(tag)[0] = setting(0)
        }
        assertFalse(PhotoNp3Parser.parse(bytes).ignoredDetailControls)
        assertEquals(controls(parameters(PhotoNp3Parser.parse(sample()))), controls(parameters(PhotoNp3Parser.parse(bytes))))
    }

    @Test fun curveSamplesAreOwnedAndTheSourceCannotMutateAnExportSnapshot() {
        val source = sample("tonecurve-noop")
        val parsed = PhotoNp3Parser.parse(source)
        val curve = requireNotNull(parameters(parsed).toneCurve)
        val original = curve.copyOf()
        source.fill(0)
        assertArrayEquals(original, curve)
        assertNotSame(curve, parameters(PhotoNp3Parser.parse(sample("tonecurve-noop"))).toneCurve)
        assertEquals(0.5f, parameters(parsed).normalizedToneCurve!![128], 0.0001f)
    }

    @Test fun validatesCurveMetadataAndSampleLimits() {
        assertFailure(PhotoNp3Failure.INVALID, changed("tonecurve-noop") { getValue(2)[8] = 21 })
        assertFailure(PhotoNp3Failure.INVALID, changed("tonecurve-noop") { getValue(2)[64] = 128.toByte() })
        assertFailure(PhotoNp3Failure.INVALID, changed("tonecurve-noop") { this[2] = getValue(2).dropLast(1).toByteArray() })
        assertFailure(PhotoNp3Failure.UNSUPPORTED, changed("tonecurve-noop") { getValue(2)[1] = '1'.code.toByte() })
        assertFailure(PhotoNp3Failure.UNSUPPORTED, changed("tonecurve-noop") { getValue(2)[63] = 1 })
        assertFailure(PhotoNp3Failure.INVALID, changed { getValue(0x1900)[0] = 1 })
        assertFailure(PhotoNp3Failure.INVALID, changed("tonecurve-noop") { getValue(0x1900)[0] = 255.toByte() })
    }

    @Test fun identityIsContentBasedAndRepeatReadsAreStable() {
        val first = PhotoNp3Parser.parse(sample())
        assertEquals(first.sourceSha256, PhotoNp3Parser.parse(sample()).sourceSha256)
        assertEquals(first.preset.id, PhotoNp3Parser.parse(sample()).preset.id)
        assertNotEquals(first.preset.id, PhotoNp3Parser.parse(changed { getValue(0x1E00)[0] = setting(1) }).preset.id)
    }

    @Test fun providerReadsAreBoundedAndAcceptShortChunks() {
        val expected = PhotoNp3Parser.parse(sample())
        val chunked = object : ByteArrayInputStream(sample()) {
            override fun read(bytes: ByteArray, offset: Int, count: Int): Int = super.read(bytes, offset, minOf(count, 7))
        }
        assertEquals(expected.preset.id, PhotoNp3Parser.read(chunked).preset.id)
        assertFailure(PhotoNp3Failure.TOO_LARGE, ByteArray(PhotoNp3Parser.MAX_BYTES + 1))
        var consumed = 0
        val endless = object : InputStream() {
            override fun read(): Int = 0
            override fun read(bytes: ByteArray, offset: Int, count: Int): Int {
                consumed += count
                bytes.fill(0, offset, offset + count)
                return count
            }
        }
        assertEquals(PhotoNp3Failure.TOO_LARGE,
            assertThrows(PhotoNp3Exception::class.java) { PhotoNp3Parser.read(endless) }.reason)
        assertEquals(PhotoNp3Parser.MAX_BYTES + 1, consumed)
    }

    @Test fun providerCancellationAndNoProgressAreNotLost() {
        val input = ByteArrayInputStream(sample())
        assertThrows(CancellationException::class.java) {
            PhotoNp3Parser.read(input) { throw CancellationException() }
        }
        assertEquals(sample().size, input.available())
        val stalled = object : InputStream() {
            override fun read(): Int = 0
            override fun read(bytes: ByteArray, offset: Int, count: Int): Int = 0
        }
        assertEquals(PhotoNp3Failure.INVALID,
            assertThrows(PhotoNp3Exception::class.java) { PhotoNp3Parser.read(stalled) }.reason)
    }

    private fun sample(name: String = "vanilla") =
        javaClass.getResourceAsStream("/picture_control/flexible-color/$name.NP3")!!.use { it.readBytes() }

    private fun parameters(parsed: ParsedPhotoNp3) = parsed.preset.parameters as Np3PhotoFilterParameters
    private fun controls(parameters: Np3PhotoFilterParameters) = with(parameters) {
        listOf(contrast, highlights, shadows, whites, blacks, saturation)
    }
    private fun setting(value: Int) = (128 + value).toByte()

    private fun changed(name: String = "vanilla", change: LinkedHashMap<Int, ByteArray>.() -> Unit) =
        encode(fields(sample(name)).apply(change))

    private fun fields(bytes: ByteArray): LinkedHashMap<Int, ByteArray> {
        val input = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN).apply { position(4) }
        val fields = linkedMapOf<Int, ByteArray>()
        while (true) {
            val tag = input.int
            if (tag == 0) return fields
            fields[tag] = ByteArray(input.int).also(input::get)
        }
    }

    private fun encode(fields: Map<Int, ByteArray>): ByteArray = ByteArrayOutputStream().also { output ->
        DataOutputStream(output).use { stream ->
            stream.write(byteArrayOf(78, 67, 80, 0))
            fields.forEach { (tag, value) ->
                stream.writeInt(tag)
                stream.writeInt(value.size)
                stream.write(value)
            }
            stream.writeInt(0)
        }
    }.toByteArray()

    private fun assertFailure(reason: PhotoNp3Failure, bytes: ByteArray) {
        assertEquals(reason, assertThrows(PhotoNp3Exception::class.java) { PhotoNp3Parser.parse(bytes) }.reason)
    }
}
