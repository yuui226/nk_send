package com.ztransfer.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Synthetic D5600 protocol fixtures, not hardware captures or NP3 container bytes. */
class NikonD5600PictureControlTest {
    @get:Rule val temporary = TemporaryFolder()
    private val format = NikonPictureControlFormat.LEGACY_V2
    private val operations = setOf(0x1014, 0x1015, 0x1016, 0x90CC, 0x940E, 0x90CE, 0x90CF)
    private data class Call(val code: Int, val params: List<Int>, val data: ByteArray?)
    private data class Slot(var defaults: ByteArray, var current: ByteArray)

    private fun fixtureDataset(name: String, custom: Boolean = true, mono: Boolean = false,
                               curve: Boolean = false): ByteArray = ByteArray(if (curve) 610 else 32).also {
        it[0] = if (mono) 4 else 1
        it[1] = if (mono) 1 else 0
        it[2] = if (custom) 1 else 0
        name.toByteArray(Charsets.US_ASCII).copyInto(it, 3)
        if (mono) {
            it[23] = 3 // Red filter.
            it[24] = 1 // Sepia.
            it[25] = 16 // Toning density in quarter steps.
        } else {
            it[25] = -7 // Saturation.
            it[26] = 5 // Hue.
        }
        it[27] = 18 // Sharpening.
        it[28] = -3 // Contrast.
        it[29] = 2 // Brightness.
        it[30] = -9 // Clarity.
        it[31] = if (curve) 1 else 0
        // Existing legacy curves are opaque. Deliberately unlike the NP3 I0 header.
        if (curve) for (offset in 32 until it.size) it[offset] = (offset * 37 + 11).toByte()
    }

    private fun fixtureEmpty(size: Int = 32): ByteArray = ByteArray(size) { 0x5A.toByte() }.also {
        // The other fields in an unused slot are not a registration to decode.
        it[2] = 2
    }

    private fun parsed(slot: Int, bytes: ByteArray) =
        NikonPictureControlData.parseResponse(slot, 0x2001, bytes, format)

    private inner class FixtureCamera : PictureControlTransport {
        val slots = (201..209).associateWith { item ->
            val bytes = if (item == 209) fixtureEmpty() else fixtureDataset("Fixture C${item - 200}",
                mono = item == 203, curve = item == 203)
            Slot(bytes.copyOf(), bytes.copyOf())
        }
        var selected = 5
        var failDeleteAfterMutation = false
        var rejectNextSelection: Int? = null
        var capabilities = ByteArray(39).also {
            it[0] = 1
            for (offset in 1..7) it[offset] = 0x81.toByte()
        }
        val calls = mutableListOf<Call>()

        fun access(slot: Int, movie: Boolean = false, advertised: Set<Int> = operations) = NikonPictureControlAccess(
            "synthetic-d5600\u0000picture-control-photo", slot, movie, advertised, { true }, this, null, format)
        fun snapshot() = slots.mapValues { (_, state) -> state.defaults.copyOf() to state.current.copyOf() }
        fun assertUnchanged(before: Map<Int, Pair<ByteArray, ByteArray>>, except: Int? = null) {
            for ((item, bytes) in before) if (item != except) {
                assertArrayEquals("C${item - 200} defaults changed", bytes.first, slots.getValue(item).defaults)
                assertArrayEquals("C${item - 200} current changed", bytes.second, slots.getValue(item).current)
            }
        }

        override suspend fun exchange(code: Int, params: IntArray, data: ByteArray?): Pair<Int, ByteArray?> {
            calls += Call(code, params.toList(), data?.copyOf())
            return 0x2001 to when (code) {
                0x1014 -> {
                    assertEquals(listOf(0xD200), params.toList())
                    val choices = (1..7).toList() + (201..209).toList()
                    ByteBuffer.allocate(12 + choices.size * 2).order(ByteOrder.LITTLE_ENDIAN)
                        .putShort(0xD200.toShort()).putShort(4).put(1).putShort(1)
                        .putShort(selected.toShort()).put(2).putShort(choices.size.toShort())
                        .also { buffer -> choices.forEach { buffer.putShort(it.toShort()) } }.array()
                }
                0x1015 -> {
                    assertEquals(1, params.size)
                    assertTrue(params.single() in setOf(0x500E, 0xD200))
                    val value = if (params.single() == 0x500E) 1 else selected
                    byteArrayOf(value.toByte(), (value shr 8).toByte())
                }
                0x1016 -> {
                    assertEquals(listOf(0xD200), params.toList())
                    assertEquals(2, requireNotNull(data).size)
                    val value = (data[0].toInt() and 255) or ((data[1].toInt() and 255) shl 8)
                    if (value == rejectNextSelection) {
                        rejectNextSelection = null
                        return 0x201F to null
                    }
                    if (value in 201..209) assertEquals(1, slots.getValue(value).current[2].toInt())
                    selected = value
                    null
                }
                0x90CC -> {
                    assertEquals("D5600 read has no movie parameter", 2, params.size)
                    assertTrue(params[1] in 0..1)
                    if (params[0] in 201..209) slots.getValue(params[0]).let {
                        if (params[1] == 0) it.current.copyOf() else it.defaults.copyOf()
                    } else {
                        assertEquals(1, params[0])
                        fixtureDataset("STANDARD", custom = false)
                    }
                }
                0x90CF -> {
                    assertEquals(listOf(1), params.toList())
                    capabilities.copyOf()
                }
                0x940E -> {
                    assertEquals("D5600 V2 write takes target, modified flag, and format", 3, params.size)
                    assertEquals(1, params[2])
                    val state = slots.getValue(params[0])
                    val bytes = requireNotNull(data).copyOf()
                    assertEquals(1, bytes[2].toInt())
                    if (params[1] == 0) {
                        state.defaults = bytes.copyOf()
                        state.current = bytes.copyOf()
                    } else {
                        assertEquals(1, params[1])
                        state.current = bytes.copyOf()
                    }
                    null
                }
                0x90CE -> {
                    assertEquals("D5600 delete takes only the target", 1, params.size)
                    val target = params.single()
                    assertNotEquals("Do not delete the active slot", target, selected)
                    slots.getValue(target).apply { defaults = fixtureEmpty(); current = fixtureEmpty() }
                    if (failDeleteAfterMutation) {
                        failDeleteAfterMutation = false
                        return 0x2002 to null
                    }
                    null
                }
                else -> error("Unexpected fixture command 0x%04X".format(code))
            }
        }
    }

    @Test fun legacyCommandsKeepTheirDocumentedParameterCountsAndBank() {
        for (movie in listOf(false, true)) {
            assertFalse(format.movieBank(movie))
            assertEquals(0xD200, format.selectionProperty(movie))
            assertArrayEquals(intArrayOf(209, 0), format.params(movie, 209, 0))
        }
        assertEquals(0xD237, NikonPictureControlFormat.CLASSIC_Z.selectionProperty(true))
        assertArrayEquals(intArrayOf(209, 0, 1), NikonPictureControlFormat.CLASSIC_Z.params(true, 209, 0))
    }

    @Test fun registrationFlagIdentifiesAnEmptySlotEvenWhenThePayloadIsNotZeroFilled() {
        for (size in listOf(32, 610)) {
            val bytes = fixtureEmpty(size)
            val empty = parsed(209, bytes)
            assertTrue(empty.isEmpty)
            assertEquals("", empty.name)
            assertEquals(0, empty.baseItem)
            assertArrayEquals(bytes, empty.bytes())
        }
        assertThrows(IllegalArgumentException::class.java) { parsed(1, fixtureEmpty()) }
        assertThrows(IllegalArgumentException::class.java) { parsed(209, ByteArray(32)) }
    }

    @Test fun colorAndMonochromeNamesAndOpaqueCurvesRoundTripExactly() {
        for (mono in listOf(false, true)) for (curve in listOf(false, true)) {
            val bytes = fixtureDataset("Fixture C3", mono = mono, curve = curve)
            val result = parsed(203, bytes)
            assertFalse(result.isEmpty)
            assertEquals(if (mono) 4 else 1, result.baseItem)
            assertEquals("Fixture C3", result.name)
            assertArrayEquals(bytes, result.bytes())
            assertArrayEquals(bytes.copyOfRange(23, 31), result.parameterBytes())
            bytes[23] = 99
            assertNotEquals(99, result.bytes()[23].toInt())
        }
        val unusedCurve = fixtureDataset("Unused curve", curve = true).also { it[31] = 0 }
        assertArrayEquals(unusedCurve, parsed(201, unusedCurve).bytes())
        val paddedName = fixtureDataset("Short").also { it[22] = 99 }
        assertEquals("Short", parsed(201, paddedName).name)
        assertArrayEquals(paddedName, parsed(201, paddedName).bytes())
    }

    @Test fun malformedOrZFormatDataNeverMasqueradesAsAnEmptyV2Slot() {
        val invalid = listOf(
            ByteArray(31), ByteArray(36), ByteArray(614),
            fixtureDataset("Bad flag").also { it[2] = 3 },
            fixtureDataset("Bad mono").also { it[1] = 2 },
            fixtureDataset("No base").also { it[0] = 0 },
            fixtureDataset("Bad curve").also { it[31] = 1 },
            fixtureDataset("Bad name").also { it.fill('x'.code.toByte(), 3, 23) },
        )
        invalid.forEach { bytes ->
            assertThrows(RuntimeException::class.java) { parsed(201, bytes) }
        }
        assertThrows(IllegalStateException::class.java) {
            NikonPictureControlData.parseResponse(209, 0x2002, fixtureEmpty(), format)
        }
        assertThrows(IllegalArgumentException::class.java) {
            NikonPictureControlData.parseResponse(201, 0x2001, fixtureDataset("Legacy"))
        }
    }

    @Test fun snapshotsKeepDifferentRegisteredAndCurrentMonochromeCurvesWithoutReencoding() {
        val defaults = fixtureDataset("Mono", mono = true, curve = true)
        val current = defaults.copyOf().also { it[25] = 20; it[120] = (it[120].toInt() xor 0x55).toByte() }
        val snapshot = NikonPictureControlSlotState(parsed(203, defaults), parsed(203, current)).bytes()
        val restored = NikonPictureControlSlotState.parse(203, snapshot, format)
        assertArrayEquals(defaults, restored.defaults.bytes())
        assertArrayEquals(current, restored.current.bytes())
        assertThrows(IllegalArgumentException::class.java) {
            NikonPictureControlSlotState.parse(203, snapshot)
        }
    }

    @Test fun overviewReadsNineExplicitSlotsWithoutMutationInEitherShootingMode() = runBlocking {
        for (movie in listOf(false, true)) {
            val camera = FixtureCamera()
            val overview = camera.access(201, movie).overview(PictureControlBackupStore(temporary.newFolder()))
            assertEquals((201..209).toList(), overview.slots.map { it.slot })
            assertTrue(overview.slots.take(8).all { it.availability == PictureControlSlotAvailability.OCCUPIED })
            assertEquals((1..8).map { "Fixture C$it" }, overview.slots.take(8).map { it.name })
            assertEquals(PictureControlSlotAvailability.EMPTY, overview.slots.last().availability)
            assertEquals(5, overview.selected)
            assertTrue(overview.canActivate)
            assertTrue(overview.canEdit)
            assertEquals((201..209).map { listOf(it, 0) }, camera.calls.filter { it.code == 0x90CC }.map { it.params })
            assertFalse(camera.calls.any { it.code in setOf(0x940E, 0x90CE, 0x1016) })
        }
    }

    @Test fun invalidReadIsUnreadableAndDoesNotHideTheOtherEightSlots() = runBlocking {
        val camera = FixtureCamera()
        camera.slots.getValue(204).current = ByteArray(32)
        val rows = camera.access(201).overview(PictureControlBackupStore(temporary.newFolder())).slots
        assertEquals(PictureControlSlotAvailability.UNREADABLE, rows.single { it.slot == 204 }.availability)
        assertTrue(rows.filter { it.slot != 204 }.all { it.readable })
    }

    @Test fun clearingCannotBypassLegacyCapabilityLayoutVerification() = runBlocking {
        val camera = FixtureCamera().apply { capabilities = ByteArray(28) }
        val before = camera.snapshot()
        val access = camera.access(203)
        try { access.prepare(); fail("Unexpected capability layout must block editing") }
        catch (_: IllegalArgumentException) {}
        try { access.clearSlot(); fail("Failed preparation must not authorize deletion") }
        catch (_: IllegalStateException) {}
        camera.assertUnchanged(before)
        assertFalse(camera.calls.any { it.code in setOf(0x940E, 0x90CE, 0x1016) })
    }

    @Test fun activatingAnyRegisteredSlotNeverWritesSlotContentsOrCreatesABackup() = runBlocking {
        for (movie in listOf(false, true)) for (slot in 201..208) {
            val camera = FixtureCamera()
            val before = camera.snapshot()
            val access = camera.access(slot, movie)
            val store = PictureControlBackupStore(temporary.newFolder())
            access.prepareSelection()
            PictureControlReplacement(store).activate(access)
            assertEquals(slot, camera.selected)
            camera.assertUnchanged(before)
            assertNull(store.load(access.cameraIdentity, slot))
            assertFalse(camera.calls.any { it.code in setOf(0x940E, 0x90CE) })
            assertEquals(listOf(0xD200), camera.calls.single { it.code == 0x1016 }.params)
        }
    }

    @Test fun movieAndPhotoAccessShareSelectionAndDoNotCreateIndependentBanks() = runBlocking {
        val camera = FixtureCamera()
        val movie = camera.access(203, movie = true)
        val photo = camera.access(203, movie = false)
        assertEquals(movie.cameraIdentity, photo.cameraIdentity)
        movie.prepareSelection()
        PictureControlReplacement(PictureControlBackupStore(temporary.newFolder())).activate(movie)
        assertEquals(203L, photo.readSelection())
        assertArrayEquals(movie.readSlot(), photo.readSlot())
    }

    @Test fun replacementChecksLegacyCapabilitiesAndOnlyWritesItsExplicitTarget() = runBlocking {
        for (movie in listOf(false, true)) {
            val camera = FixtureCamera()
            val before = camera.snapshot()
            val target = 207
            val dataset = fixtureDataset("New registration", curve = true)
            val access = camera.access(target, movie)
            access.prepare(dataset)
            PictureControlReplacement(PictureControlBackupStore(temporary.newFolder())).apply(access,
                NikonPictureControlSlotState.fromDataset(target, dataset, format).bytes())
            camera.assertUnchanged(before, except = target)
            assertArrayEquals(dataset, camera.slots.getValue(target).defaults)
            assertArrayEquals(dataset, camera.slots.getValue(target).current)
            assertEquals(target, camera.selected)
            assertEquals(listOf(1), camera.calls.single { it.code == 0x90CF }.params)
            assertEquals(listOf(target, 0, 1), camera.calls.single { it.code == 0x940E }.params)
            assertFalse(camera.calls.any { it.code == 0x90CE })
        }
    }

    @Test fun clearingAnySlotOnlySwitchesToStandardWhenNecessaryAndPreservesItsNeighbors() = runBlocking {
        for (movie in listOf(false, true)) for (slot in 201..209) for (active in listOf(false, true)) {
            val camera = FixtureCamera()
            camera.slots.getValue(slot).apply {
                defaults = fixtureDataset("Clear test", curve = true)
                current = defaults.copyOf()
            }
            camera.selected = if (active) slot else 5
            val before = camera.snapshot()
            val access = camera.access(slot, movie)
            access.prepare()
            PictureControlReplacement(PictureControlBackupStore(temporary.newFolder())).clear(access)
            assertNull(access.readSlot())
            assertEquals(if (active) 1 else 5, camera.selected)
            camera.assertUnchanged(before, except = slot)
            val mutations = camera.calls.filter { it.code in setOf(0x940E, 0x90CE, 0x1016) }
            assertEquals(listOf(slot), mutations.last().params)
            if (active) {
                assertEquals(listOf(0x1016, 0x90CE), mutations.map { it.code })
                assertArrayEquals(byteArrayOf(1, 0), mutations.first().data)
            } else assertEquals(listOf(0x90CE), mutations.map { it.code })
        }
    }

    @Test fun deletionFailureRestoresOpaqueMonochromeDefaultsAndAdjustmentsThenTheSelection() = runBlocking {
        for (movie in listOf(false, true)) {
            val camera = FixtureCamera().apply { selected = 203; failDeleteAfterMutation = true }
            camera.slots.getValue(203).current.let {
                it[25] = 24
                it[197] = (it[197].toInt() xor 0x42).toByte()
            }
            val before = camera.snapshot()
            val access = camera.access(203, movie)
            val store = PictureControlBackupStore(temporary.newFolder())
            access.prepare()
            try {
                PictureControlReplacement(store).clear(access)
                fail("Expected failed delete")
            } catch (error: PictureControlReplacementException) {
                assertTrue(error.originalRestored)
            }
            camera.assertUnchanged(before)
            assertEquals(203, camera.selected)
            val writes = camera.calls.filter { it.code == 0x940E }
            assertEquals(listOf(listOf(203, 0, 1), listOf(203, 1, 1)), writes.map { it.params })
            assertArrayEquals(before.getValue(203).first, writes[0].data)
            assertArrayEquals(before.getValue(203).second, writes[1].data)
            assertArrayEquals(access.readSlot(), store.load(access.cameraIdentity, 203)!!.data())
        }
    }

    @Test fun failedActivationRestoresSelectionWithoutRewritingAnySlot() = runBlocking {
        val camera = FixtureCamera().apply { rejectNextSelection = 203 }
        val before = camera.snapshot()
        val access = camera.access(203)
        access.prepareSelection()
        try {
            PictureControlReplacement(PictureControlBackupStore(temporary.newFolder())).activate(access)
            fail("Expected failed selection")
        } catch (error: PictureControlReplacementException) {
            assertTrue(error.originalRestored)
        }
        assertEquals(5, camera.selected)
        camera.assertUnchanged(before)
        assertFalse(camera.calls.any { it.code in setOf(0x940E, 0x90CE) })
    }

    @Test fun missingExplicitV2WriteOperationDisablesEditingWithoutDisablingReadsAndSelection() = runBlocking {
        val camera = FixtureCamera()
        val before = camera.snapshot()
        val access = camera.access(203, advertised = operations - 0x940E + 0x90CD)
        val store = PictureControlBackupStore(temporary.newFolder())
        val overview = access.overview(store)
        assertTrue(overview.slots.all { it.readable })
        assertTrue(overview.canActivate)
        assertFalse(overview.canEdit)
        access.prepareSelection()
        PictureControlReplacement(store).activate(access)
        assertEquals(203, camera.selected)
        try {
            access.prepare()
            fail("Legacy write advertisement must not substitute for explicit V2 support")
        } catch (_: IllegalStateException) { }
        camera.assertUnchanged(before)
        assertFalse(camera.calls.any { it.code in setOf(0x90CD, 0x940E, 0x90CE) })
    }
}
