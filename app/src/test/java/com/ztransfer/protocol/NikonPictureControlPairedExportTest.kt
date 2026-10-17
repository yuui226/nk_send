package com.ztransfer.protocol

import org.junit.Assert.*
import org.junit.Test

/**
 * Independent evidence: files exported through the Z 30 camera menu, paired with
 * earlier GetPicCtrlData responses. These are not outputs of an app encoder.
 * NP3 field mapping is established by these samples; the SetPicCtrlData contract
 * is separately documented by Nikon Z 30 MTP sections 6.2.2.44 and 9.8.
 */
class NikonPictureControlPairedExportTest {
    private data class Pairing(val number: Int, val file: NikonPictureControlFile, val camera: NikonPictureControlData)

    private fun resource(path: String): ByteArray =
        javaClass.getResourceAsStream("/picture_control/$path")!!.use { it.readBytes() }

    private fun pairs(): List<Pairing> {
        val reads = resource("z30-v3.tsv").toString(Charsets.UTF_8).lineSequence()
            .filter { it.isNotBlank() && !it.startsWith('#') }
            .map { it.split('\t') }
            .filter { it[1] == "90CC" && it[3] == "2001" && it[2].endsWith(",0") }
            .associate { fields ->
                val slot = fields[2].substringBefore(',').toInt()
                slot to NikonPictureControlData.parseResponse(slot, 0x2001,
                    fields[4].chunked(2).map { it.toInt(16).toByte() }.toByteArray())
            }
        return (1..6).map { number ->
            Pairing(number, NikonPictureControlFile.parse(resource("z30-exported/PICCON%02d.NP3".format(number))),
                reads.getValue(200 + number))
        }
    }

    @Test fun sixCameraExportsMatchNamesAndExplicitBaseMappings() {
        // NP3 identifiers are opaque. In particular, their low byte is not a PTP item.
        val observedBases = mapOf(0x080B to 111, 0x080C to 112, 0x03C2 to 2, 0x0001 to 1)
        pairs().forEach { (_, file, camera) ->
            assertEquals("0300", file.version)
            assertEquals(file.name, camera.name)
            assertArrayEquals(file.field(0x0200), camera.bytes().copyOfRange(2, 22))
            val id = file.field(0x0300)!!
            assertEquals(2, id.size)
            val np3Base = ((id[0].toInt() and 255) shl 8) or (id[1].toInt() and 255)
            assertEquals(observedBases.getValue(np3Base), camera.baseItem)
            assertNotEquals(camera.requestedItem, camera.baseItem)
        }
        assertEquals("ADelicate portrait ", pairs()[3].file.name) // Preserve the trailing space.
    }

    @Test fun allThreeExportedCurvesMatchEveryByteOfTheIndependentCameraReads() {
        pairs().forEach { (number, file, camera) ->
            val exported = file.field(2)
            if (number in 3..5) {
                assertEquals(834, file.bytes().size)
                assertEquals(578, exported!!.size)
                assertArrayEquals(exported, camera.curve!!.bytes())
                assertArrayEquals(NikonPictureControlToneCurve.parse(exported).samples(), camera.curve.samples())
                assertEquals(614, camera.bytes().size)
            } else {
                assertEquals(248, file.bytes().size)
                assertNull(exported)
                assertNull(camera.curve)
                assertEquals(36, camera.bytes().size)
            }
        }
    }

    @Test fun observedColorParameterMappingAccountsForAllHeaderBytesExceptOffset23() {
        pairs().forEach { (_, file, camera) ->
            val read = camera.bytes()
            // Values remain in encoded quarter steps; dividing by four would lose precision.
            fun value(tag: Int, encoding: Int): Int {
                val field = file.field(tag)!!
                assertEquals(2, field.size)
                assertEquals(encoding, field[1].toInt() and 255)
                return field[0].toInt() and 255
            }
            fun signed(tag: Int): Byte {
                val raw = value(tag, 4)
                assertTrue(raw in 2..254)
                return (raw - 128).toByte()
            }
            val effect = value(0x1500, 10)
            assertEquals((if (effect == 255) 0 else (effect - 128) * 10).toByte(), read[22])
            assertEquals((value(0x1400, 1) - 128).toByte(), read[24])
            assertEquals(signed(0x0600), read[25])
            assertEquals(signed(0x1600), read[26])
            assertEquals(signed(0x0700), read[27])
            for ((tag, offset) in listOf(0x0800 to 28, 0x0900 to 29)) {
                val raw = value(tag, 4)
                when (raw) {
                    1 -> { // Only observed in the three files containing a custom curve.
                        assertNotNull(file.field(2))
                        assertEquals(0.toByte(), read[offset])
                    }
                    255 -> {
                        assertEquals(0x0900, tag) // Do not generalize this sentinel to other fields.
                        assertEquals(0.toByte(), read[offset])
                    }
                    else -> assertEquals(signed(tag), read[offset])
                }
            }
            assertEquals(signed(0x0A00), read[30])
            val hue = value(0x0B00, 4)
            assertEquals((if (hue == 255) 0 else hue - 128).toByte(), read[31])
            // These six are color presets; no mapping for monochrome filter/toning is established.
            assertEquals(255, value(0x0C00, 0))
            assertEquals(255, value(0x0D00, 0))
            assertEquals(255, value(0x0E00, 4))
            assertArrayEquals(byteArrayOf(0, 0, 0), read.copyOfRange(32, 35))
            assertEquals((if (file.field(2) == null) 0 else 1).toByte(), read[35])
        }
    }

    @Test fun quickSharpFlagIsNotTheReservedNp3Field() {
        val pairs = pairs()
        assertEquals(listOf(0, 0, 0, 0, 0, 1), pairs.map { it.camera.bytes()[23].toInt() })
        // Both fields are identical across the files despite different camera mode bytes.
        // Neither is evidence for a direct mapping to offset 23.
        pairs.forEach { (_, file, _) ->
            assertArrayEquals(byteArrayOf(0, 0), file.field(0x0400))
            assertArrayEquals(byteArrayOf(0x80.toByte(), 1), file.field(0x1400))
        }
    }

    @Test fun encoderReproducesRealCameraExportsWithExplicitManualSharpening() {
        pairs().forEach { (number, file, camera) ->
            val expected = camera.bytes()
            // Nikon 9.8.4: On ignores individual sharpening values. Encode manual
            // NP3 values with Off, including C6 whose matching default trio used On.
            if (number == 6) expected[23] = 0
            assertArrayEquals("PICCON$number", expected, file.encodeClassicPictureControl())
        }
    }
}
