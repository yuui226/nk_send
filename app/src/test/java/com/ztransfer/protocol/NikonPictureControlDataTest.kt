package com.ztransfer.protocol

import java.io.File
import org.junit.Assert.*
import org.junit.Test

class NikonPictureControlDataTest {
    private data class Response(val id: String, val op: Int, val params: List<Int>, val code: Int, val bytes: ByteArray)
    private val capture: List<Response> = javaClass.getResourceAsStream("/picture_control/z30-v3.tsv")!!
        .bufferedReader().useLines { lines ->
            lines.filter { !it.startsWith('#') && it.isNotBlank() }.map { line ->
                val fields = line.split('\t')
                Response(fields[0], fields[1].toInt(16), fields[2].split(',').filter { it.isNotBlank() }.map(String::toInt),
                    fields[3].toInt(16), fields[4].chunked(2).map { it.toInt(16).toByte() }.toByteArray())
            }.toList()
        }
    private fun data(item: Int, argument: Int = 0): NikonPictureControlData {
        val response = capture.single { it.op == 0x90CC && it.params == listOf(item, argument) }
        return NikonPictureControlData.parseResponse(item, response.code, response.bytes)
    }

    @Test fun completeCaptureParsesAllSuccessfulReadsAndRoundTripsEveryByte() {
        assertEquals(134, capture.size)
        val successful = capture.filter { it.op == 0x90CC && it.code == 0x2001 }
        assertEquals(74, successful.size)
        successful.forEach { response ->
            assertArrayEquals(response.id, response.bytes,
                NikonPictureControlData.parseResponse(response.params[0], response.code, response.bytes).bytes())
        }
    }

    @Test fun occupiedCustomSlotsRetainBaseIdsSeparateFromDestinationSlot() {
        assertEquals(201, data(201).requestedItem)
        assertEquals(111, data(201).baseItem)
        assertEquals("FUJI CC", data(201).name)
        assertEquals(112, data(202).baseItem)
        assertEquals(2, data(203).baseItem)
        assertEquals(1, data(204).baseItem)
        assertEquals(1, data(205).baseItem)
        assertEquals(112, data(206).baseItem)
        (201..206).forEach { assertFalse(data(it).isEmpty) }
    }

    @Test fun emptyC9DoesNotRedirectToOtherEmptySlots() {
        for (slot in 207..209) assertTrue(data(slot).isEmpty)
        val photo = capture.single { it.op == 0x1014 && it.params == listOf(0xD200) }
        val movie = capture.single { it.op == 0x1014 && it.params == listOf(0xD237) }
        assertEquals(209, NikonPictureControlSelection.parse(photo.bytes).confirmedLastCustomSlot)
        assertEquals(209, NikonPictureControlSelection.parse(movie.bytes, 0xD237).confirmedLastCustomSlot)
        assertEquals(100, NikonPictureControlSelection.parse(movie.bytes, 0xD237).current)
    }

    @Test fun fullCurvesIncludeControlPointsAnd257SamplesWithoutTruncation() {
        val expectedPoints = mapOf(203 to 2, 204 to 7, 205 to 10)
        for ((slot, points) in expectedPoints) {
            val preset = data(slot)
            assertEquals(614, preset.bytes().size)
            val curve = preset.curve!!
            assertEquals(578, curve.bytes().size)
            assertEquals(points, curve.points.size)
            assertEquals(257, curve.samples().size)
            assertEquals(0, curve.samples().first())
            assertArrayEquals(preset.bytes().copyOfRange(36, 614), curve.bytes())
        }
        assertEquals(32767, data(203).curve!!.samples().last())
        assertEquals(29426, data(205).curve!!.samples().last())
        assertEquals(listOf(NikonPictureControlToneCurve.Point(0, 0), NikonPictureControlToneCurve.Point(255, 255)),
            data(203).curve!!.points)
    }

    @Test fun readErrorsAndTruncatedCurvesCannotBeMisclassifiedAsEmptySlots() {
        for (response in capture.filter { it.op == 0x90CC && it.code != 0x2001 }) {
            assertThrows(IllegalStateException::class.java) {
                NikonPictureControlData.parseResponse(response.params[0], response.code, response.bytes)
            }
        }
        assertThrows(IllegalArgumentException::class.java) { NikonPictureControlData.parseResponse(209, 0x2001, null) }
        assertThrows(IllegalArgumentException::class.java) { NikonPictureControlData.parseResponse(209, 0x2001, byteArrayOf()) }
        assertThrows(IllegalArgumentException::class.java) { NikonPictureControlData.parseResponse(209, 0x2001, ByteArray(614)) }
        val curve = data(203).bytes()
        for (length in listOf(0, 35, 36, 37, 613, 615)) {
            assertThrows(IllegalArgumentException::class.java) {
                NikonPictureControlData.parseResponse(209, 0x2001, curve.copyOf(length))
            }
        }
    }

    @Test fun capturedCurvesAndBundledNp3CurvesShareTheObservedCurveLayout() {
        val folder = File("src/main/assets/picture_controls").takeIf { it.exists() }
            ?: File("app/src/main/assets/picture_controls")
        val files = folder.listFiles()!!.filter { it.extension == "NP3" }
        assertEquals(5, files.size)
        files.forEach {
            val block = NikonPictureControlFile.parse(it.readBytes()).field(2)!!
            val curve = NikonPictureControlToneCurve.parse(block)
            assertArrayEquals(block, curve.bytes())
            assertEquals(257, curve.samples().size)
        }
        // Matching curve structure is NOT proof of NP3 -> SetPicCtrlData conversion.
    }

    @Test fun mutableCallerBuffersCannotDamageTheSavedReadback() {
        val original = data(203).bytes()
        val parsed = NikonPictureControlData.parseResponse(203, 0x2001, original)
        original.fill(0)
        parsed.bytes().fill(0)
        parsed.parameterBytes().fill(0)
        parsed.curve!!.bytes().fill(0)
        parsed.curve.samples().fill(0)
        assertEquals("American movie", parsed.name)
        assertEquals(2, parsed.baseItem)
        assertEquals(32767, parsed.curve.samples().last())
    }
}
