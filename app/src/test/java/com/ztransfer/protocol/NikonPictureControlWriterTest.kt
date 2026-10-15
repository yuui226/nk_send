package com.ztransfer.protocol

import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class NikonPictureControlWriterTest {
    @get:Rule val temporary = TemporaryFolder()
    private data class Call(val code: Int, val params: List<Int>, val data: ByteArray?)
    private fun captured(code: Int, params: String): ByteArray = javaClass
        .getResourceAsStream("/picture_control/z30-v3.tsv")!!.bufferedReader().useLines { lines ->
            val cells = lines.filter { !it.startsWith('#') && it.isNotBlank() }.map { it.split('\t') }
                .single { it[1].toInt(16) == code && it[2] == params && it[3] == "2001" }
            cells[4].chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        }
    private fun preset(name: String = "Kodak Ektar Green"): ByteArray = NikonPictureControlFile.parse(
        File("src/main/assets/picture_controls/$name.NP3").readBytes()).encodeClassicPictureControl()
    private fun bundledPresetNames() = File("src/main/assets/picture_controls").listFiles()!!
        .filter { it.extension == "NP3" && it.nameWithoutExtension !in setOf("PORTRAIT-02", "PORTRAIT-03") }
        .map { it.nameWithoutExtension }.sorted()
    private fun writeCapture(direction: String, code: Int, params: String): ByteArray = javaClass
        .getResourceAsStream("/picture_control/z30-write-v4.tsv")!!.bufferedReader().useLines { lines ->
            val cells = lines.filter { !it.startsWith('#') && it.isNotBlank() }.map { it.split('\t') }
                .first { it[0] == direction && it[1].toInt(16) == code && it[2] == params && it[4].startsWith("0200") }
            cells[4].chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        }
    private fun withoutCurve(data: ByteArray) = data.copyOf(36).also { it[35] = 0 }
    private fun state(defaults: ByteArray, current: ByteArray): ByteArray = NikonPictureControlSlotState(
        NikonPictureControlData.parseResponse(209, 0x2001, defaults),
        NikonPictureControlData.parseResponse(209, 0x2001, current)).bytes()
    private val operations = setOf(0x1014, 0x1015, 0x1016, 0x90CC, 0x90CD, 0x90CE, 0x90CF)

    private inner class Wire(val movie: Boolean = false, initial: ByteArray = captured(0x90CC, "203,0")) : PictureControlTransport {
        var defaults = initial.copyOf()
        var current = initial.copyOf()
        var selection = 5
        var exposure = 1
        var rejectActivation = false
        var malformedCapabilities = false
        var omitDefaultCurve = false
        var corruptNextCurve = false
        val calls = mutableListOf<Call>()
        override suspend fun exchange(code: Int, params: IntArray, data: ByteArray?): Pair<Int, ByteArray?> {
            calls += Call(code, params.toList(), data?.copyOf())
            val mode = if (movie) 1 else 0
            val property = if (movie) 0xD237 else 0xD200
            val result: ByteArray? = when (code) {
                0x1014 -> {
                    assertEquals(listOf(property), params.toList())
                    captured(code, "$property")
                }
                0x1015 -> {
                    assertTrue(params.single() in listOf(0x500E, property))
                    val value = if (params[0] == 0x500E) exposure else selection
                    byteArrayOf(value.toByte(), (value shr 8).toByte())
                }
                0x90CF -> {
                    assertEquals(mode, params[1])
                    if (malformedCapabilities) byteArrayOf(1) else captured(code, "${params[0]}")
                }
                0x90CC -> {
                    assertEquals(3, params.size)
                    assertEquals(mode, params[2])
                    if (params[0] == 209) {
                        if (params[1] == 0) current.copyOf()
                        else if (omitDefaultCurve) withoutCurve(defaults) else defaults.copyOf()
                    }
                    else captured(code, "${params[0]},${params[1]}")
                }
                0x90CD -> {
                    assertEquals(209, params[0])
                    assertEquals(3, params.size)
                    assertEquals(mode, params[2])
                    requireNotNull(data)
                    if (params[1] == 0) { defaults = data.copyOf(); current = data.copyOf() }
                    else { assertEquals(1, params[1]); current = data.copyOf() }
                    if (corruptNextCurve) {
                        current[101] = (current[101].toInt() xor 1).toByte()
                        corruptNextCurve = false
                    }
                    null
                }
                0x90CE -> {
                    assertEquals(listOf(209, mode), params.toList())
                    defaults = ByteArray(36); current = ByteArray(36)
                    null
                }
                0x1016 -> {
                    assertEquals(listOf(property), params.toList())
                    requireNotNull(data)
                    val requested = (data[0].toInt() and 255) or ((data[1].toInt() and 255) shl 8)
                    if (requested == 209 && rejectActivation) { rejectActivation = false; return 0x201F to null }
                    selection = requested
                    null
                }
                else -> error("Unexpected camera command")
            }
            return 0x2001 to result
        }
        fun access(ops: Set<Int> = operations) = NikonPictureControlAccess("body-${if (movie) "movie" else "photo"}",
            209, movie, ops, { true }, this, {})
        fun mutations() = calls.filter { it.code in setOf(0x90CD, 0x90CE, 0x1016) }
    }

    @Test fun everyDisplayedPresetConvertsAndRetainsItsWholeCurve() {
        val names = bundledPresetNames()
        assertEquals(20, names.size)
        names.forEach { name ->
            val file = NikonPictureControlFile.parse(File("src/main/assets/picture_controls/$name.NP3").readBytes())
            val bytes = file.encodeClassicPictureControl()
            assertEquals(614, bytes.size)
            assertEquals(name, NikonPictureControlData.parseResponse(209, 0x2001, bytes).name)
            assertArrayEquals(file.field(2), bytes.copyOfRange(36, bytes.size))
        }
        // No speculative low-byte/bit-mask mapping for a source identifier not established by evidence.
        assertThrows(IllegalStateException::class.java) { preset("PORTRAIT-02") }
    }

    @Test fun nikonPcConversionsPreservePublishedScalarsAndOriginalLookupSamples() {
        val rows = javaClass.getResourceAsStream("/picture_control/nikonpc-source.tsv")!!
            .bufferedReader().useLines { lines -> lines.filter { !it.startsWith('#') && it.isNotBlank() }.toList() }
        assertEquals(17, rows.size)
        for (row in rows) {
            val cells = row.split('\t')
            val bytes = preset(cells[0])
            assertEquals(cells[0], cells[1].toInt(), (bytes[0].toInt() and 255) or ((bytes[1].toInt() and 255) shl 8))
            assertEquals(cells[2].toInt() * 4, bytes[25].toInt())
            assertEquals(cells[3].toInt() * 4, bytes[30].toInt())
            assertEquals(cells[4].toInt() * 4, bytes[31].toInt())
            assertEquals(0, bytes[23].toInt()) // Explicit sharpening; no automatic override.
            assertEquals(0, bytes[26].toInt()) // NCP has no mid-range sharpening or clarity.
            assertEquals(0, bytes[27].toInt())
            assertEquals(1, bytes[35].toInt())
            assertEquals(cells[0], cells[5], pictureControlDigest(bytes.copyOfRange(100, 614)))
        }
    }

    @Test fun everyBundledPresetPassesZ30CapabilitiesAndOnlyReplacesC9() = runBlocking {
        val wire = Wire(initial = ByteArray(36)).apply { omitDefaultCurve = true }
        val access = wire.access()
        val store = PictureControlBackupStore(temporary.newFolder())
        val replacement = PictureControlReplacement(store)
        for (name in bundledPresetNames()) {
            val data = preset(name)
            access.prepare(data)
            replacement.apply(access, NikonPictureControlSlotState.fromDataset(209, data).bytes())
            assertArrayEquals(name, data, wire.current)
            assertEquals(209, wire.selection)
        }
        assertNull(store.load(access.cameraIdentity, 209)!!.data())
        replacement.restoreOriginal(access)
        assertTrue(wire.current.all { it == 0.toByte() })
        assertEquals(1, wire.selection)
        assertTrue(wire.calls.filter { it.code == 0x90CD || it.code == 0x90CE }.all { it.params[0] == 209 })
    }

    @Test fun replacementUsesC9NewRegistrationAndExplicitBankForBothPhotoAndMovie() = runBlocking {
        for (movie in listOf(false, true)) {
            val wire = Wire(movie)
            val access = wire.access()
            val dataset = preset()
            access.prepare(dataset)
            PictureControlReplacement(PictureControlBackupStore(temporary.newFolder())).apply(access,
                NikonPictureControlSlotState.fromDataset(209, dataset).bytes())
            assertEquals(209, wire.selection)
            assertArrayEquals(dataset, wire.current)
            assertArrayEquals(dataset, wire.defaults)
            val writes = wire.calls.filter { it.code == 0x90CD }
            assertEquals(1, writes.size)
            assertEquals(listOf(209, 0, if (movie) 1 else 0), writes.single().params)
            assertTrue(wire.calls.indexOfFirst { it.code == 0x1016 } > wire.calls.indexOfLast { it.code == 0x90CC })
        }
    }

    @Test fun activationFailureRestoresRegisteredDefaultAndDifferentCurrentAdjustments() = runBlocking {
        val wire = Wire().apply { current[30] = -8; rejectActivation = true }
        val defaults = wire.defaults.copyOf(); val current = wire.current.copyOf()
        val access = wire.access(); val dataset = preset()
        access.prepare(dataset)
        try {
            PictureControlReplacement(PictureControlBackupStore(temporary.newFolder())).apply(access,
                NikonPictureControlSlotState.fromDataset(209, dataset).bytes())
            fail("Expected failed activation")
        } catch (error: PictureControlReplacementException) { assertTrue(error.originalRestored) }
        assertArrayEquals(defaults, wire.defaults)
        assertArrayEquals(current, wire.current)
        assertEquals(5, wire.selection)
        assertEquals(listOf(listOf(209, 0, 0), listOf(209, 0, 0), listOf(209, 1, 0)),
            wire.calls.filter { it.code == 0x90CD }.map { it.params })
    }

    @Test fun manualRestoreSurvivesNewStoreAndWriterInstancesIncludingOriginallyEmptyC9() = runBlocking {
        val wire = Wire(initial = ByteArray(36))
        val folder = temporary.newFolder(); val access = wire.access(); val dataset = preset()
        access.prepare(dataset)
        PictureControlReplacement(PictureControlBackupStore(folder)).apply(access,
            NikonPictureControlSlotState.fromDataset(209, dataset).bytes())
        val saved = PictureControlBackupStore(folder).load(access.cameraIdentity, 209)!!
        assertNull(saved.data()); assertEquals(5L, saved.selection)
        PictureControlReplacement(PictureControlBackupStore(folder)).restoreOriginal(access)
        assertTrue(wire.current.all { it == 0.toByte() })
        assertEquals(1, wire.selection)
        assertEquals(listOf(209, 0), wire.calls.single { it.code == 0x90CE }.params)
    }

    @Test fun actualZ30WriteCaptureIsVerifiedWithoutFalseRollbackAndCanBeReplacedAndRestored() = runBlocking {
        val sent = writeCapture("out", 0x90CD, "209,0,0")
        val current = writeCapture("in", 0x90CC, "209,0,0")
        val defaults = writeCapture("in", 0x90CC, "209,1,0")
        assertArrayEquals(preset("LINKS-Nature"), sent)
        assertArrayEquals(sent, current)
        assertArrayEquals(withoutCurve(sent), defaults)
        val wire = Wire(initial = ByteArray(36)).apply { omitDefaultCurve = true }
        val access = wire.access()
        val folder = temporary.newFolder()
        val replacement = PictureControlReplacement(PictureControlBackupStore(folder))
        access.prepare(sent)
        replacement.apply(access, NikonPictureControlSlotState.fromDataset(209, sent).bytes())
        assertArrayEquals(state(defaults, current), access.readSlot())
        assertEquals(209, wire.selection)
        assertFalse(wire.calls.any { it.code == 0x90CE })
        // The accepted 36-byte default must also avoid redundant registration on a second tap.
        replacement.apply(access, NikonPictureControlSlotState.fromDataset(209, sent).bytes())
        assertEquals(1, wire.calls.count { it.code == 0x90CD })
        val next = preset()
        access.prepare(next)
        replacement.apply(access, NikonPictureControlSlotState.fromDataset(209, next).bytes())
        assertArrayEquals(next, wire.current)
        PictureControlReplacement(PictureControlBackupStore(folder)).restoreOriginal(access)
        assertTrue(wire.current.all { it == 0.toByte() })
        assertEquals(1, wire.selection)
        assertEquals(listOf(209, 0), wire.calls.single { it.code == 0x90CE }.params)
    }

    @Test fun omittedDefaultCurveNeverHidesScalarOrCurrentCurveCorruption() {
        val current = writeCapture("in", 0x90CC, "209,0,0")
        val defaults = writeCapture("in", 0x90CC, "209,1,0")
        val expected = state(current, current)
        val access = Wire().access()
        assertTrue(access.matchesSlot(expected, state(defaults, current)))
        // Every default scalar (including the name) is still checked byte-for-byte.
        for (offset in listOf(2, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34)) {
            val corrupt = defaults.copyOf().also { it[offset] = (it[offset].toInt() xor 1).toByte() }
            assertFalse("Default mismatch at $offset", access.matchesSlot(expected, state(corrupt, current)))
        }
        for (offset in listOf(25, 36 + 9, 36 + 65, 613)) {
            val corrupt = current.copyOf().also { it[offset] = (it[offset].toInt() xor 1).toByte() }
            assertFalse("Current mismatch at $offset", access.matchesSlot(expected, state(defaults, corrupt)))
        }
        assertFalse(access.matchesSlot(expected, state(defaults, withoutCurve(current))))
        val differentDefaultCurve = current.copyOf().also { it[101] = (it[101].toInt() xor 1).toByte() }
        assertFalse(access.matchesSlot(expected, state(differentDefaultCurve, current)))
        assertFalse(access.matchesSlot(expected, null))
        assertFalse(access.matchesSlot(null, state(defaults, current)))
    }

    @Test fun corruptedCurrentCurveStillRollsBackWithCurveOmittedFromDefaults() = runBlocking {
        val wire = Wire().apply { omitDefaultCurve = true; current[30] = -8; corruptNextCurve = true }
        val previousCurrent = wire.current.copyOf()
        val access = wire.access(); val dataset = preset()
        access.prepare(dataset)
        val previous = access.readSlot()
        try {
            PictureControlReplacement(PictureControlBackupStore(temporary.newFolder())).apply(access,
                NikonPictureControlSlotState.fromDataset(209, dataset).bytes())
            fail("Expected failed curve verification")
        } catch (error: PictureControlReplacementException) {
            assertEquals(PictureControlWriteStage.VERIFY, error.stage)
            assertTrue(error.originalRestored)
        }
        assertArrayEquals(previous, access.readSlot())
        assertArrayEquals(previousCurrent, wire.current)
        assertEquals(5, wire.selection)
        assertEquals(listOf(listOf(209, 0, 0), listOf(209, 0, 0), listOf(209, 1, 0)),
            wire.calls.filter { it.code == 0x90CD }.map { it.params })
    }

    @Test fun unsupportedOperationsExposureOrCapabilityLayoutsNeverStartMutation() = runBlocking {
        val cases = listOf(Wire() to (operations - 0x90CD),
            Wire().apply { exposure = 6 } to operations,
            Wire().apply { malformedCapabilities = true } to operations)
        for ((wire, ops) in cases) {
            try { wire.access(ops).prepare(preset()); fail("Expected preflight failure") }
            catch (_: Exception) { }
            assertTrue(wire.mutations().isEmpty())
        }
    }

    @Test fun invalidSnapshotsCannotBeSentAsWirePayloads() = runBlocking {
        val wire = Wire(); val access = wire.access(); access.prepare(preset())
        for (bytes in listOf(ByteArray(0), preset(), ByteArray(12), NikonPictureControlSlotState.fromDataset(209, preset()).bytes().dropLast(1).toByteArray())) {
            try { access.writeSlot(bytes); fail("Expected invalid snapshot rejection") }
            catch (_: IllegalArgumentException) { }
        }
        assertTrue(wire.mutations().isEmpty())
    }
}
