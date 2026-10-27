package com.ztransfer.filter

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test

class ClassicPhotoNp3ParserTest {
    @Test fun allBundledAndPairedExportedClassicFilesRetainTheirRecordedCurves() {
        val bundled = File("src/main/assets/picture_controls").listFiles()!!
            .filter { it.extension.equals("np3", ignoreCase = true) }
        val exported = (1..6).map { index ->
            File("src/test/resources/picture_control/z30-exported/PICCON%02d.NP3".format(index))
        }
        assertEquals(22, bundled.size)
        for (file in bundled + exported) {
            val source = fields(file.readBytes())
            val actual = parse(source)
            val curve = source[2]
            if (curve == null) assertNull(file.name, actual.toneCurve) else {
                val expected = IntArray(257) { index ->
                    ((curve[64 + index * 2].toInt() and 255) shl 8) or
                        (curve[65 + index * 2].toInt() and 255)
                }
                assertArrayEquals(file.name, expected, actual.toneCurve)
                assertEquals(file.name, 0, actual.contrastQuarter)
                assertEquals(file.name, 0, actual.brightnessQuarter)
            }
        }
    }

    @Test fun quarterStepsAndAutomaticValuesNeverBecomeExtremeAdjustments() {
        val source = color().apply {
            this[0x0800] = pair(0, 4)
            this[0x0900] = pair(122, 4)
            this[0x0A00] = pair(129, 4)
            this[0x0B00] = pair(139, 4)
        }
        val actual = parse(source)
        assertEquals(CLASSIC_PHOTO_FILTER_AUTO, actual.contrastQuarter)
        assertEquals(-6, actual.brightnessQuarter)
        assertEquals(1, actual.saturationQuarter)
        assertEquals(11, actual.hueQuarter)
        source[0x0A00] = pair(0, 4)
        assertEquals(CLASSIC_PHOTO_FILTER_AUTO, parse(source).saturationQuarter)
    }

    @Test fun monochromeFiltersAndToningKeepTheirIndependentQuarterStepDensity() {
        val source = monochrome().apply {
            this[0x0C00] = pair(132, 0)
            this[0x0D00] = pair(137, 0)
            this[0x0E00] = pair(155, 4)
        }
        val actual = parse(source)
        assertEquals(ClassicNp3Style.MONOCHROME, actual.base)
        assertEquals(4, actual.filterEffect)
        assertEquals(9, actual.toningEffect)
        assertEquals(27, actual.toningDensityQuarter)
        assertEquals(0, actual.saturationQuarter)
        assertEquals(0, actual.hueQuarter)
    }

    @Test fun creativeFixedTonesUseBaseAndDensityWhenToningEnumIsUnavailable() {
        val source = monochrome().apply {
            this[0x0300] = pair(8, 15) // RED; independently observed in public NX output.
            this[0x0900] = pair(255, 4)
            this[0x0C00] = pair(132, 0)
            this[0x0D00] = pair(255, 0)
            this[0x0E00] = pair(156, 4)
            this[0x1500] = pair(130, 10)
        }
        val actual = parse(source)
        assertEquals(ClassicNp3Style.RED, actual.base)
        assertEquals(0, actual.toningEffect)
        assertEquals(28, actual.toningDensityQuarter)
        assertEquals(20, actual.effectLevel)
    }

    @Test fun traditional0310WithNeutralFlexibleFieldsIsNotMistakenForFlexibleColor() {
        val source = color().apply {
            this[0x0100] = "0310".toByteArray()
            this[0x0300] = pair(4, 0x93)
            for (tag in listOf(0x1700, 0x1800)) this[tag] = pair(255, 4)
            for (tag in 0x1900..0x1E00 step 0x100) this[tag] = pair(128, 1)
            this[0x1F00] = ByteArray(24) { 128.toByte() } + byteArrayOf(1, 1, 1, 0)
            this[0x2000] = byteArrayOf(-128, 0, -128, -128, -128, 0, -128, -128,
                -128, 0, -128, -128, 1, 1, 1, 0, -78, 1, -128, 1)
        }
        assertEquals(ClassicNp3Style.RICH_TONE_PORTRAIT, parse(source).base)
        source[0x1900] = pair(129, 1)
        failure(PhotoNp3Failure.UNSUPPORTED, source)
        source[0x1900] = pair(128, 1)
        source.getValue(0x1F00)[0] = 129.toByte()
        failure(PhotoNp3Failure.UNSUPPORTED, source)
    }

    @Test fun autoProfileAllowsOnlyNeutralRelativeOffsetsWithoutGuessingTheirMeaning() {
        val source = color().apply {
            this[0x0300] = pair(2, 0xCF)
            for (tag in listOf(0x0600, 0x0700, 0x0800, 0x0900, 0x0A00, 0x0B00, 0x1600)) {
                this[tag] = pair(255, 4)
            }
            for (tag in 0x0F00..0x1300 step 0x100) this[tag] = pair(128, 1)
        }
        val actual = parse(source)
        assertEquals(ClassicNp3Style.AUTO, actual.base)
        assertEquals(listOf(0, 0, 0, 0), listOf(actual.contrastQuarter, actual.brightnessQuarter,
            actual.saturationQuarter, actual.hueQuarter))
        source[0x1000] = pair(129, 1)
        failure(PhotoNp3Failure.UNSUPPORTED, source)
    }

    @Test fun corruptAndUnsupportedAdjustmentsRemainDistinct() {
        failure(PhotoNp3Failure.INVALID, color().apply { remove(0x0600) })
        failure(PhotoNp3Failure.INVALID, color().apply { this[0x0800] = pair(141, 4) })
        failure(PhotoNp3Failure.INVALID, color().apply { this[0x0800] = pair(1, 4) })
        failure(PhotoNp3Failure.INVALID, color().apply { this[0x0900] = pair(0, 4) })
        failure(PhotoNp3Failure.INVALID, monochrome().apply { this[0x0C00] = pair(133, 0) })
        failure(PhotoNp3Failure.INVALID, monochrome().apply { this[0x0E00] = pair(157, 4) })
        failure(PhotoNp3Failure.UNSUPPORTED, color().apply { this[0x0800] = pair(128, 7) })
        failure(PhotoNp3Failure.UNSUPPORTED, color().apply { this[0x0300] = pair(0x7F, 0xFF) })
        failure(PhotoNp3Failure.UNSUPPORTED, color().apply { this[0x2100] = pair(128, 1) })
        failure(PhotoNp3Failure.UNSUPPORTED, color().apply { this[0x0C00] = pair(131, 0) })
    }

    @Test fun recordedSamplesAreOwnedAndNonDefaultCurveEditingMetadataIsAccepted() {
        val source = fields(File("src/main/assets/picture_controls/Ferrania Solaris.NP3").readBytes())
        val original = source.getValue(2)
        assertFalse(original.copyOfRange(0, 8).contentEquals(byteArrayOf(0x49, 0x30, 0, -1, 0, -1, 1, 0)))
        val result = parse(source)
        val samples = requireNotNull(result.toneCurve).copyOf()
        original.fill(0)
        assertArrayEquals(samples, result.toneCurve)
        val invalid = fields(File("src/main/assets/picture_controls/Ferrania Solaris.NP3").readBytes())
        invalid.getValue(2)[64] = 128.toByte()
        failure(PhotoNp3Failure.INVALID, invalid)
    }

    private fun color() = fields(File("src/main/assets/picture_controls/Kodak Ektar Green.NP3").readBytes()).apply {
        remove(2)
        for (tag in 0x0800..0x0B00 step 0x100) this[tag] = pair(128, 4)
    }

    private fun monochrome() = color().apply {
        this[0x0300] = pair(6, 0x4D)
        this[0x0A00] = pair(255, 4)
        this[0x0B00] = pair(255, 4)
        this[0x0C00] = pair(128, 0)
        this[0x0D00] = pair(128, 0)
    }

    private fun fields(bytes: ByteArray): MutableMap<Int, ByteArray> {
        val input = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN).apply { position(4) }
        val fields = linkedMapOf<Int, ByteArray>()
        while (input.remaining() >= 4) {
            val tag = input.int
            if (tag == 0) break
            fields[tag] = ByteArray(input.int).also(input::get)
        }
        return fields
    }

    private fun parse(fields: Map<Int, ByteArray>) =
        ClassicPhotoNp3Parser.parse(fields, fields.getValue(0x0100).toString(Charsets.US_ASCII))

    private fun failure(reason: PhotoNp3Failure, fields: Map<Int, ByteArray>) {
        try {
            parse(fields)
            fail("Expected $reason")
        } catch (error: PhotoNp3Exception) {
            assertEquals(reason, error.reason)
        }
    }

    private fun pair(first: Int, second: Int) = byteArrayOf(first.toByte(), second.toByte())
}
