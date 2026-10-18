package com.ztransfer.protocol

import java.io.File
import org.junit.Assert.*
import org.junit.Test

class NikonPictureControlV2EncoderTest {
    private val format = NikonPictureControlFormat.LEGACY_V2
    private fun file(name: String = "Kodak Ektar Green") = NikonPictureControlFile.parse(
        File("src/main/assets/picture_controls/$name.NP3").readBytes())

    @Test fun builtinPresetsPreserveTheCurvesFromTheirIndependentOfficialUtilityNp2Exports() {
        // Hashes of tag 2 in the author's paired NP2 exports, not of generated camera data.
        // Source: https://phpstone.com/nikon-picture-control/ (Picture Control Utility 2).
        val curves = mapOf(
            "Kodak Ektar Green" to "4f41279ce59e1c543289785563b435dea08f600df5392e8764f59be7ca4af5e6",
            "LINKS-Nature" to "e84a01548e1e0858d9271acfbeeff90a7764b30438e2e1c59f2bf302f5eaa5c2",
        )
        for ((name, hash) in curves) {
            val data = file(name).encodePictureControl(format)
            assertEquals(610, data.size)
            assertEquals(1, data[31].toInt())
            assertEquals(hash, pictureControlDigest(data.copyOfRange(32, 610)))
            assertEquals(name, NikonPictureControlData.parseResponse(209, 0x2001, data, format).name)
        }
    }

    @Test fun headerHasExplicitCustomRegistrationAndV2FieldOrder() {
        val actual = file().encodePictureControl(format)
        val expected = ByteArray(32)
        expected[0] = 3 // Vivid
        expected[2] = 1 // Custom
        "Kodak Ektar Green".toByteArray(Charsets.US_ASCII).copyInto(expected, 3)
        expected[25] = 1 // Saturation +0.25
        expected[26] = 6 // Hue +1.5
        expected[31] = 1 // Curve overrides contrast/brightness.
        assertArrayEquals(expected, actual.copyOf(32))
    }

    @Test fun scalarUnitsAndAutoFlagsArePreservedWithoutAddingCurveData() {
        val classic = file().encodeClassicPictureControl().copyOf(36).apply {
            this[25] = 36; this[27] = -20; this[28] = -128; this[29] = 6
            this[30] = -128; this[31] = -12; this[35] = 0
        }
        val before = classic.copyOf()
        val data = encodeV2PictureControl(classic)
        assertEquals(32, data.size)
        assertArrayEquals(byteArrayOf(0, 0, -128, -12, 36, -128, 6, -20, 0), data.copyOfRange(23, 32))
        assertArrayEquals(before, classic)
        val capabilities = ByteArray(39).apply { this[0] = 1; fill(0x81.toByte(), 1, 8) }
        validateV2PictureControlCapabilities(data, capabilities)
        capabilities[4] = 0x80.toByte()
        assertThrows(PictureControlPresetUnsupportedException::class.java) {
            validateV2PictureControlCapabilities(data, capabilities)
        }
    }

    @Test fun newerAdjustmentsAreRejectedInsteadOfSilentlyDropped() {
        val valid = file().encodeClassicPictureControl()
        for ((offset, value) in listOf(0 to 111, 25 to -1, 26 to 4, 22 to 10, 23 to 1, 32 to 1)) {
            assertThrows("offset=$offset", PictureControlPresetUnsupportedException::class.java) {
                encodeV2PictureControl(valid.copyOf().apply { this[offset] = value.toByte() })
            }
        }
        // The bundled Sun preset has mid-range sharpening +1, which D5600 cannot represent.
        assertThrows(PictureControlPresetUnsupportedException::class.java) {
            file("Kodak-Sun-Nature").encodePictureControl(format)
        }
    }

    @Test fun unexpectedCapabilitiesCannotAuthorizeAWrite() {
        val data = file().encodePictureControl(format)
        for (capabilities in listOf(ByteArray(28), ByteArray(39), ByteArray(40))) {
            assertThrows(IllegalArgumentException::class.java) { validateV2PictureControlCapabilities(data, capabilities) }
        }
        val capabilities = ByteArray(39).apply { this[0] = 1; fill(0x80.toByte(), 1, 8) }
        validateV2PictureControlCapabilities(data, capabilities)
        capabilities[6] = 0 // Saturation +0.25 needs a selectable saturation field.
        assertThrows(PictureControlPresetUnsupportedException::class.java) {
            validateV2PictureControlCapabilities(data, capabilities)
        }
    }

    @Test fun existingZEncodingIsUnchanged() {
        for (name in listOf("Kodak Ektar Green", "Kodak-Sun-Nature", "LINKS-Nature")) {
            val preset = file(name)
            assertArrayEquals(preset.encodeClassicPictureControl(), preset.encodePictureControl(NikonPictureControlFormat.CLASSIC_Z))
        }
    }

    @Test fun bundledPresetsEitherConvertCompletelyOrReportSpecificModelIncompatibility() {
        val unsupported = mutableSetOf<String>()
        val directory = File("src/main/assets/picture_controls")
        val catalog = File(directory, "catalog.json").readText().substringBefore("\"unlistedResearchSamples\"")
        val files = Regex("\"file\"\\s*:\\s*\"([^\"]+)\"").findAll(catalog)
            .map { File(directory, it.groupValues[1]) }.toList()
        assertTrue(files.isNotEmpty())
        for (source in files) {
            val preset = NikonPictureControlFile.parse(source.readBytes())
            try {
                val wire = preset.encodePictureControl(format)
                val readback = NikonPictureControlData.parseResponse(201, 0x2001, wire, format)
                assertEquals(preset.name, readback.name)
                assertFalse(readback.isEmpty)
            } catch (_: PictureControlPresetUnsupportedException) { unsupported += source.nameWithoutExtension }
        }
        assertEquals(setOf("Kodak-Sun-Nature"), unsupported)
    }
}
