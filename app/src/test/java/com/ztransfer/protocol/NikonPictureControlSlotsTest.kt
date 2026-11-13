package com.ztransfer.protocol

import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Independent 18-slot camera fixture: every command is checked against its actual target/bank. */
class NikonPictureControlSlotsTest {
    @get:Rule val temporary = TemporaryFolder()
    private val operations = setOf(0x1014, 0x1015, 0x1016, 0x90CC, 0x90CD, 0x90CE, 0x90CF)
    private data class Call(val op: Int, val params: List<Int>, val value: Int? = null)
    private fun captured(op: Int, params: String): ByteArray = javaClass
        .getResourceAsStream("/picture_control/z30-v3.tsv")!!.bufferedReader().useLines { lines ->
            val cells = lines.filter { !it.startsWith('#') && it.isNotBlank() }.map { it.split('\t') }
                .single { it[1].toInt(16) == op && it[2] == params && it[3] == "2001" }
            cells[4].chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        }
    private fun preset(name: String = "Kodak Ektar Green") = NikonPictureControlFile.parse(
        File("src/main/assets/picture_controls/$name.NP3").readBytes()).encodeClassicPictureControl()
    private data class Slot(var defaults: ByteArray, var current: ByteArray)
    private inner class Camera : PictureControlTransport {
        val banks = List(2) { mode -> (201..209).associateWith { slot ->
            val data = captured(0x90CC, "$slot,0")
            if (mode == 1 && data.any { it != 0.toByte() }) {
                data.fill(0, 2, 22); "Movie ${slot - 200}".toByteArray().copyInto(data, 2)
            }
            Slot(data.copyOf(), data.copyOf())
        } }
        val selected = intArrayOf(5, 100)
        val calls = mutableListOf<Call>()
        var registeredOnlySelection = false
        val unlistedSelections = mutableSetOf<Int>()
        val readResponses = mutableMapOf<Int, Int>()
        var selectionWritable = true
        var omitWrittenSelectionOnce = false
        private var omittedSelection: Pair<Int, Int>? = null
        var unavailable: Int? = null
        var unreadable: Int? = null
        var ignoredSelection: Int? = null
        var failedDelete = false
        var partialDelete = false
        var corruptWrite = false
        var connected = true
        var disconnectOnWrite = false
        var writeStarted: CompletableDeferred<Unit>? = null
        var finishWrite: CompletableDeferred<Unit>? = null

        fun access(slot: Int, mode: Int = 0, body: String = "body", ops: Set<Int> = operations,
                   log: ((String) -> Unit)? = null) =
            NikonPictureControlAccess("$body\u0000picture-control-${if (mode == 0) "photo" else "movie"}",
                slot, mode == 1, ops, { connected }, this, log)
        fun image() = banks.flatMap { bank -> bank.values.flatMap { listOf(it.defaults.copyOf(), it.current.copyOf()) } }
        fun emptyBank(mode: Int) {
            banks[mode].values.forEach { it.defaults = ByteArray(36); it.current = ByteArray(36) }
        }
        private fun registered(mode: Int, slot: Int): Boolean = banks[mode].getValue(slot).current.let {
            it.size >= 2 && (it[0] != 0.toByte() || it[1] != 0.toByte())
        }
        fun assertOtherSlotsUnchanged(before: List<ByteArray>, mode: Int, slot: Int) {
            val after = image()
            val first = (mode * 9 + slot - 201) * 2
            before.indices.filter { it != first && it != first + 1 }.forEach {
                assertArrayEquals("Unrelated slot/bank changed at $it", before[it], after[it])
            }
        }
        override suspend fun exchange(code: Int, params: IntArray, data: ByteArray?): Pair<Int, ByteArray?> {
            check(connected)
            val value = data?.takeIf { code == 0x1016 }?.let { (it[0].toInt() and 255) or ((it[1].toInt() and 255) shl 8) }
            calls += Call(code, params.toList(), value)
            return 0x2001 to when (code) {
                0x1014 -> {
                    val mode = if (params.single() == 0xD237) 1 else 0
                    val omitted = omittedSelection?.takeIf { it.first == mode }?.second
                    if (omitted != null) omittedSelection = null
                    val choices = listOf(1, 2, 3, 4, 5, 6, 7, 8, 100, 111, 112) + (201..209).filter {
                        it != unavailable && it !in unlistedSelections && it != omitted &&
                            (!registeredOnlySelection || registered(mode, it))
                    }
                    ByteBuffer.allocate(12 + choices.size * 2).order(ByteOrder.LITTLE_ENDIAN)
                        .putShort(params[0].toShort()).putShort(4).put(if (selectionWritable) 1.toByte() else 0.toByte()).putShort(8)
                        .putShort(selected[mode].toShort()).put(2).putShort(choices.size.toShort())
                        .also { buffer -> choices.forEach { buffer.putShort(it.toShort()) } }.array()
                }
                0x1015 -> {
                    val item = params.single()
                    val number = if (item == 0x500E) 1 else selected[if (item == 0xD237) 1 else 0]
                    byteArrayOf(number.toByte(), (number shr 8).toByte())
                }
                0x90CC -> {
                    assertEquals(3, params.size)
                    val item = params[0]; val mode = params[2]
                    assertTrue(mode in 0..1)
                    if (item == unavailable) return 0x2006 to null
                    readResponses[item]?.let { return it to null }
                    if (item == unreadable) byteArrayOf(1, 2, 3)
                    else if (item in 201..209) banks[mode].getValue(item).let {
                        if (params[1] == 0) it.current.copyOf() else it.defaults.copyOf()
                    } else captured(code, "$item,${params[1]}")
                }
                0x90CF -> captured(code, "${params[0]}")
                0x90CD -> {
                    assertTrue(params[0] in 201..209)
                    val entry = banks[params[2]].getValue(params[0])
                    val bytes = requireNotNull(data).copyOf()
                    if (params[1] == 0) { entry.defaults = bytes.copyOf(); entry.current = bytes.copyOf() }
                    else { assertEquals(1, params[1]); entry.current = bytes.copyOf() }
                    if (omitWrittenSelectionOnce) {
                        omittedSelection = params[2] to params[0]
                        omitWrittenSelectionOnce = false
                    }
                    if (corruptWrite) { entry.current[25] = (entry.current[25] + 1).toByte(); corruptWrite = false }
                    writeStarted?.complete(Unit); finishWrite?.await()
                    if (disconnectOnWrite) { connected = false; throw IOException("Disconnected after write") }
                    null
                }
                0x90CE -> {
                    assertTrue(params[0] in 201..209)
                    assertEquals(2, params.size)
                    val mode = params[1]
                    check(selected[mode] != params[0]) { "Never delete the active slot" }
                    if (failedDelete) { failedDelete = false; return 0x2002 to null }
                    banks[mode].getValue(params[0]).apply {
                        if (!partialDelete) defaults = ByteArray(36)
                        current = ByteArray(36)
                    }
                    partialDelete = false
                    null
                }
                0x1016 -> {
                    val mode = if (params.single() == 0xD237) 1 else 0
                    val requested = requireNotNull(value)
                    check(selectionWritable)
                    if (requested in 201..209) check(registered(mode, requested))
                    if (ignoredSelection == requested) ignoredSelection = null else selected[mode] = requested
                    null
                }
                else -> error("Unexpected operation $code")
            }
        }
    }

    @Test fun readsNineRealNamesAndExplicitEmptyStatesWithoutMutation() = runBlocking {
        val camera = Camera()
        val overview = camera.access(201).overview(PictureControlBackupStore(temporary.newFolder()))
        assertEquals((201..209).toList(), overview.slots.map { it.slot })
        assertEquals(listOf("FUJI CC", "FUJI NC", "American movie", "ADelicate portrait ", "Fuji side axis", "TOY-02"),
            overview.slots.take(6).map { it.name })
        assertTrue(overview.slots.drop(6).all { it.availability == PictureControlSlotAvailability.EMPTY })
        assertEquals(5, overview.selected)
        assertEquals((201..209).toList(), camera.calls.filter { it.op == 0x90CC }.map { it.params[0] })
        assertFalse(camera.calls.any { it.op in setOf(0x90CD, 0x90CE, 0x1016) })
    }

    @Test fun unreadableAndUnsupportedAreNeverReportedAsEmptyAndBackupRemainsRecoverable() = runBlocking {
        val camera = Camera().apply { unreadable = 203; unavailable = 204 }
        val access = camera.access(201)
        val store = PictureControlBackupStore(temporary.newFolder())
        store.saveOriginal(PictureControlSlotSnapshot(access.cameraIdentity, 203, byteArrayOf(1), 5))
        val slots = access.overview(store).slots.associateBy { it.slot }
        assertEquals(PictureControlSlotAvailability.UNREADABLE, slots.getValue(203).availability)
        assertTrue(slots.getValue(203).hasOriginal)
        assertEquals(PictureControlSlotAvailability.UNSUPPORTED, slots.getValue(204).availability)
        assertTrue(camera.calls.any { it.op == 0x90CC && it.params[0] == 204 })
    }

    @Test fun registeredOnlyEnumerationSupportsEmptyWriteActivateClearAndWriteAgainInEitherBank() = runBlocking {
        for (mode in 0..1) for (slot in listOf(201, 209)) {
            val camera = Camera().apply { registeredOnlySelection = true; emptyBank(mode) }
            val before = camera.image()
            val otherSelection = camera.selected[1 - mode]
            val access = camera.access(slot, mode)
            val store = PictureControlBackupStore(temporary.newFolder())
            val replacement = PictureControlReplacement(store)
            val empty = access.overview(store)
            assertEquals((201..209).toList(), empty.slots.map { it.slot })
            assertTrue(empty.slots.all {
                it.availability == PictureControlSlotAvailability.EMPTY && !it.selectable && it.editable
            })
            assertTrue(empty.canEdit)
            assertFalse(camera.calls.any { it.op in setOf(0x90CD, 0x90CE, 0x1016) })
            for (name in listOf("Kodak Ektar Green", "LINKS-Nature")) {
                val dataset = preset(name)
                access.prepare(dataset)
                replacement.apply(access, NikonPictureControlSlotState.fromDataset(slot, dataset).bytes())
                assertEquals(slot, camera.selected[mode])
                assertArrayEquals(dataset, camera.banks[mode].getValue(slot).current)
                val occupied = access.overview(store).slots.single { it.slot == slot }
                assertEquals(PictureControlSlotAvailability.OCCUPIED, occupied.availability)
                assertTrue(occupied.selectable)
                assertTrue(occupied.editable)
                assertEquals(otherSelection, camera.selected[1 - mode])
                camera.assertOtherSlotsUnchanged(before, mode, slot)

                access.prepare()
                replacement.clear(access)
                assertNull(access.readSlot())
                assertEquals(1, camera.selected[mode])
                val cleared = access.overview(store).slots.single { it.slot == slot }
                assertEquals(PictureControlSlotAvailability.EMPTY, cleared.availability)
                assertFalse(cleared.selectable)
                assertTrue(cleared.editable)
                assertEquals(otherSelection, camera.selected[1 - mode])
                camera.assertOtherSlotsUnchanged(before, mode, slot)
            }
            assertNotNull(store.load(access.cameraIdentity, slot))
            assertNull(store.load(access.cameraIdentity, slot)!!.data())
            assertTrue(camera.calls.filter { it.op == 0x90CD || it.op == 0x90CE }.all { it.params[0] == slot })
            assertEquals(2, camera.calls.count { it.op == 0x90CD })
        }
    }

    @Test fun missingSelectionEntriesAreReadAndOnlyExplicitUnsupportedResponsesMeanUnsupported() = runBlocking {
        for (response in listOf(0x2005, 0x2006, 0x201D, 0x2019, 0x2002, 0x200A, 0x2001)) {
            val camera = Camera().apply {
                registeredOnlySelection = true
                emptyBank(0)
                readResponses[204] = response
            }
            val rows = camera.access(201).overview(PictureControlBackupStore(temporary.newFolder())).slots
            val expected = if (response in setOf(0x2005, 0x2006, 0x201D))
                PictureControlSlotAvailability.UNSUPPORTED else PictureControlSlotAvailability.UNREADABLE
            val failed = rows.single { it.slot == 204 }
            assertEquals("Response 0x%04X".format(response), expected, failed.availability)
            assertFalse(failed.readable)
            assertFalse(failed.selectable)
            assertFalse(failed.editable)
            assertTrue(rows.filter { it.slot != 204 }.all { it.availability == PictureControlSlotAvailability.EMPTY })
            assertTrue(camera.calls.any { it.op == 0x90CC && it.params[0] == 204 })
            assertFalse(camera.calls.any { it.op in setOf(0x90CD, 0x90CE, 0x1016) })
        }
        val malformed = Camera().apply { registeredOnlySelection = true; emptyBank(0); unreadable = 204 }
        val row = malformed.access(201).overview(PictureControlBackupStore(temporary.newFolder())).slots.single { it.slot == 204 }
        assertEquals(PictureControlSlotAvailability.UNREADABLE, row.availability)
        assertFalse(row.editable)
    }

    @Test fun anOccupiedSlotMissingFromSelectionCanBeReadButCannotBeActivatedWrittenOrCleared() = runBlocking {
        for (mode in 0..1) {
            val camera = Camera().apply { registeredOnlySelection = true; unlistedSelections += 203 }
            val before = camera.image()
            val access = camera.access(203, mode)
            val store = PictureControlBackupStore(temporary.newFolder())
            val row = access.overview(store).slots.single { it.slot == 203 }
            assertEquals(PictureControlSlotAvailability.OCCUPIED, row.availability)
            assertTrue(row.readable)
            assertFalse(row.selectable)
            assertFalse(row.editable)
            assertThrows(IllegalStateException::class.java) { runBlocking { access.prepareSelection() } }
            assertThrows(IllegalStateException::class.java) { runBlocking { access.prepare(preset()) } }
            assertThrows(IllegalStateException::class.java) { runBlocking { access.prepare() } }
            assertNull(store.load(access.cameraIdentity, 203))
            before.zip(camera.image()).forEach { (original, current) -> assertArrayEquals(original, current) }
            assertFalse(camera.calls.any { it.op in setOf(0x90CD, 0x90CE, 0x1016) })
        }
    }

    @Test fun activationRechecksWritableAndChoicesAfterPreparation() = runBlocking {
        for (readOnly in listOf(false, true)) {
            val camera = Camera()
            val access = camera.access(203)
            access.prepareSelection()
            if (readOnly) camera.selectionWritable = false else camera.unlistedSelections += 203
            assertThrows(RuntimeException::class.java) { runBlocking { access.select(203) } }
            assertEquals(5, camera.selected[0])
            assertFalse(camera.calls.any { it.op in setOf(0x90CD, 0x90CE, 0x1016) })
        }
    }

    @Test fun aWrittenSlotRejectedByTheNewEnumerationRollsBackEmptyAndOccupiedOriginals() = runBlocking {
        for (mode in 0..1) for (occupied in listOf(false, true)) {
            val slot = 203
            val camera = Camera().apply {
                registeredOnlySelection = true
                if (occupied) {
                    selected[mode] = slot
                    banks[mode].getValue(slot).current[30] = -8
                } else banks[mode].getValue(slot).apply { defaults = ByteArray(36); current = ByteArray(36) }
            }
            val before = camera.image()
            val selectedBefore = camera.selected.copyOf()
            val access = camera.access(slot, mode)
            val original = access.readSlot()
            val store = PictureControlBackupStore(temporary.newFolder())
            val dataset = preset()
            access.prepare(dataset)
            camera.omitWrittenSelectionOnce = true
            try {
                PictureControlReplacement(store).apply(access, NikonPictureControlSlotState.fromDataset(slot, dataset).bytes())
                fail("A newly rejected selection must fail activation")
            } catch (error: PictureControlReplacementException) {
                assertEquals(PictureControlWriteStage.ACTIVATE, error.stage)
                assertTrue(error.originalRestored)
            }
            assertArrayEquals(original, access.readSlot())
            assertArrayEquals(original, store.load(access.cameraIdentity, slot)!!.data())
            assertArrayEquals(selectedBefore, camera.selected)
            before.zip(camera.image()).forEach { (expected, actual) -> assertArrayEquals(expected, actual) }
            camera.assertOtherSlotsUnchanged(before, mode, slot)
            assertTrue(camera.calls.filter { it.op == 0x90CD || it.op == 0x90CE }.all { it.params[0] == slot })
        }
    }

    @Test fun everyUnreadableSlotRetainsRawResponseAndFailureInTheReadReport() = runBlocking {
        val camera = Camera()
        camera.banks[0].values.forEach { it.current = byteArrayOf(1, 2, 3) }
        val lines = mutableListOf<String>()
        val overview = camera.access(201, log = lines::add).overview(PictureControlBackupStore(temporary.newFolder()))
        assertTrue(overview.slots.all { it.availability == PictureControlSlotAvailability.UNREADABLE })
        for (slot in 201..209) {
            assertTrue(lines.any { it.startsWith("out op=0x90CC params=$slot, 0, 0") })
            assertTrue(lines.any { it.startsWith("in op=0x90CC params=$slot, 0, 0") && it.contains("data=010203") })
            assertTrue(lines.any { it.startsWith("C${slot - 200} READ_FAILED:") })
        }
        assertFalse(camera.calls.any { it.op in setOf(0x90CD, 0x90CE, 0x1016) })
    }

    @Test fun readReportIdentifiesTheRequestEvenWhenTransportDisconnects() {
        val camera = Camera().apply { registeredOnlySelection = true; emptyBank(0) }
        val lines = mutableListOf<String>()
        val access = NikonPictureControlAccess("body-photo", 201, false, operations, { true },
            PictureControlTransport { code, params, data ->
                if (code == 0x90CC) throw IOException("Connection lost")
                camera.exchange(code, params, data)
            }, lines::add)
        assertThrows(IOException::class.java) {
            runBlocking { access.overview(PictureControlBackupStore(temporary.newFolder())) }
        }
        assertEquals("out op=0x90CC params=201, 0, 0", lines.last())
        assertFalse(lines.any { it.startsWith("C1 EMPTY") || it.contains("params=202") })
    }

    @Test fun everySlotInBothBanksCanBeReplacedTwiceAndRestoredWithoutTouchingTheOtherSeventeen() = runBlocking {
        val store = PictureControlBackupStore(temporary.newFolder())
        val replacement = PictureControlReplacement(store)
        for (mode in 0..1) for (slot in 201..209) {
            val camera = Camera()
            val before = camera.image()
            val access = camera.access(slot, mode)
            val original = access.readSlot()
            for (name in listOf("Kodak Ektar Green", "LINKS-Nature")) {
                val data = preset(name)
                access.prepare(data)
                replacement.apply(access, NikonPictureControlSlotState.fromDataset(slot, data).bytes())
                assertEquals(slot, camera.selected[mode])
                assertArrayEquals(data, camera.banks[mode].getValue(slot).current)
                camera.assertOtherSlotsUnchanged(before, mode, slot)
            }
            assertArrayEquals(original, store.load(access.cameraIdentity, slot)!!.data())
            replacement.restoreOriginal(access)
            assertArrayEquals(original, access.readSlot())
            assertEquals(if (original == null) 1 else slot, camera.selected[mode])
            camera.assertOtherSlotsUnchanged(before, mode, slot)
            assertTrue(camera.calls.filter { it.op == 0x90CD || it.op == 0x90CE }.all { it.params[0] == slot })
        }
    }

    @Test fun activatingEachRegisteredSlotOnlyChangesSelectionAndEmptySlotsAreRejected() = runBlocking {
        for (mode in 0..1) for (slot in 201..209) {
            val camera = Camera(); val before = camera.image()
            val store = PictureControlBackupStore(temporary.newFolder())
            val access = camera.access(slot, mode, ops = operations - setOf(0x90CD, 0x90CE, 0x90CF))
            access.prepareSelection()
            if (slot <= 206) {
                PictureControlReplacement(store).activate(access)
                assertEquals(slot, camera.selected[mode])
            } else {
                try { PictureControlReplacement(store).activate(access); fail("Empty slot activated") }
                catch (_: IllegalStateException) {}
            }
            before.zip(camera.image()).forEach { (a, b) -> assertArrayEquals(a, b) }
            assertNull(store.load(access.cameraIdentity, slot))
            assertFalse(camera.calls.any { it.op == 0x90CD || it.op == 0x90CE })
        }
    }

    @Test fun clearingActiveAndInactiveSlotsPreservesOthersAndSwitchesBeforeDeleting() = runBlocking {
        for (mode in 0..1) for (slot in 201..209) for (active in listOf(false, true)) {
            val camera = Camera()
            camera.banks[mode].getValue(slot).apply { defaults = preset(); current = preset() }
            camera.selected[mode] = if (active) slot else 202
            val before = camera.image(); val access = camera.access(slot, mode)
            val store = PictureControlBackupStore(temporary.newFolder())
            access.prepare()
            PictureControlReplacement(store).clear(access)
            assertNull(access.readSlot())
            assertEquals(if (active || slot == 202) 1 else 202, camera.selected[mode])
            camera.assertOtherSlotsUnchanged(before, mode, slot)
            assertNotNull(store.load(access.cameraIdentity, slot)?.data())
            val mutations = camera.calls.filter { it.op in setOf(0x90CE, 0x1016) }
            if (active || slot == 202) {
                assertEquals(0x1016, mutations.first().op)
                assertEquals(1, mutations.first().value)
            } else assertTrue(mutations.none { it.op == 0x1016 })
        }
    }

    @Test fun failureToSwitchAwayPreventsDeletionAndDeleteFailureRestoresPreviousSelection() = runBlocking {
        for (switchFails in listOf(true, false)) {
            val camera = Camera().apply { selected[0] = 203 }
            if (switchFails) camera.ignoredSelection = 1 else camera.failedDelete = true
            val before = camera.image(); val access = camera.access(203)
            access.prepare()
            try { PictureControlReplacement(PictureControlBackupStore(temporary.newFolder())).clear(access); fail("Expected failure") }
            catch (error: PictureControlReplacementException) { assertTrue(error.originalRestored) }
            assertEquals(203, camera.selected[0])
            before.zip(camera.image()).forEach { (a, b) -> assertArrayEquals(a, b) }
            if (switchFails) assertFalse(camera.calls.any { it.op == 0x90CE })
        }
    }

    @Test fun successfulDeleteAckWithOnlyPartiallyClearedDataRollsBackBothDatasets() = runBlocking {
        val camera = Camera().apply { selected[0] = 203; partialDelete = true }
        camera.banks[0].getValue(203).current[30] = -8
        val before = camera.image(); val access = camera.access(203); access.prepare()
        try { PictureControlReplacement(PictureControlBackupStore(temporary.newFolder())).clear(access); fail("Expected verification failure") }
        catch (error: PictureControlReplacementException) { assertTrue(error.originalRestored) }
        before.zip(camera.image()).forEach { (a, b) -> assertArrayEquals(a, b) }
        assertEquals(203, camera.selected[0])
    }

    @Test fun unsupportedTargetNeverFallsBackAndFailedPreflightCannotReuseAnEarlierWritePermission() = runBlocking {
        val camera = Camera(); val access = camera.access(205); val data = preset()
        access.prepare(data)
        camera.unavailable = 205
        try { access.prepareSelection(); fail("Unsupported slot passed preflight") }
        catch (_: IllegalStateException) {}
        try { access.writeSlot(NikonPictureControlSlotState.fromDataset(205, data).bytes()); fail("Stale write permission") }
        catch (_: IllegalStateException) {}
        try { access.select(205); fail("Stale selection permission") }
        catch (_: IllegalStateException) {}
        assertFalse(camera.calls.any { it.op in setOf(0x90CD, 0x90CE, 0x1016) })
    }

    @Test fun rollbackIsBoundToTheRequestedSlotAndPreservesCurrentAdjustments() = runBlocking {
        for (mode in 0..1) for (slot in 201..209) {
            val camera = Camera()
            camera.banks[mode].getValue(slot).apply { defaults = preset(); current = preset().also { it[30] = -8 } }
            val before = camera.image(); val selectedBefore = camera.selected.copyOf()
            val access = camera.access(slot, mode); val data = preset("LINKS-Nature")
            access.prepare(data); camera.corruptWrite = true
            try {
                PictureControlReplacement(PictureControlBackupStore(temporary.newFolder())).apply(access,
                    NikonPictureControlSlotState.fromDataset(slot, data).bytes())
                fail("Expected verification failure")
            } catch (error: PictureControlReplacementException) { assertTrue(error.originalRestored) }
            before.zip(camera.image()).forEach { (a, b) -> assertArrayEquals(a, b) }
            assertArrayEquals(selectedBefore, camera.selected)
            assertTrue(camera.calls.filter { it.op == 0x90CD }.all { it.params[0] == slot })
        }
    }

    @Test fun restoringOneSlotNeverReactivatesAnOldSelectionInAnotherNowEmptySlot() = runBlocking {
        val camera = Camera().apply { selected[0] = 202 }
        val access = camera.access(203); val store = PictureControlBackupStore(temporary.newFolder())
        val original = access.readSlot(); val replacement = PictureControlReplacement(store); val data = preset()
        access.prepare(data); replacement.apply(access, NikonPictureControlSlotState.fromDataset(203, data).bytes())
        camera.banks[0].getValue(202).apply { defaults = ByteArray(36); current = ByteArray(36) }
        camera.selected[0] = 205
        replacement.restoreOriginal(access)
        assertEquals(205, camera.selected[0])
        assertArrayEquals(original, access.readSlot())
    }

    @Test fun cancellationAfterWriteStillFinishesVerificationAndActivation() = runBlocking {
        val camera = Camera().apply { writeStarted = CompletableDeferred(); finishWrite = CompletableDeferred() }
        val access = camera.access(204); val data = preset(); access.prepare(data)
        val job = launch { PictureControlReplacement(PictureControlBackupStore(temporary.newFolder())).apply(access,
            NikonPictureControlSlotState.fromDataset(204, data).bytes()) }
        camera.writeStarted!!.await()
        job.cancel(); camera.finishWrite!!.complete(Unit); job.join()
        assertArrayEquals(data, camera.banks[0].getValue(204).current)
        assertEquals(204, camera.selected[0])
        assertTrue(camera.calls.any { it.op == 0x90CC && it.params[0] == 204 })
    }

    @Test fun disconnectRetainsOnlyTheCorrectBodyBankAndSlotBackup() = runBlocking {
        val camera = Camera(); val access = camera.access(206, 1, "second-body")
        val store = PictureControlBackupStore(temporary.newFolder()); val original = access.readSlot(); val data = preset()
        access.prepare(data); camera.disconnectOnWrite = true
        try {
            PictureControlReplacement(store).apply(access, NikonPictureControlSlotState.fromDataset(206, data).bytes())
            fail("Expected disconnect")
        } catch (error: PictureControlReplacementException) { assertFalse(error.originalRestored) }
        assertArrayEquals(original, store.load(access.cameraIdentity, 206)!!.data())
        assertNull(store.load(camera.access(206, 0, "second-body").cameraIdentity, 206))
        assertNull(store.load(camera.access(206, 1, "first-body").cameraIdentity, 206))
        assertNull(store.load(access.cameraIdentity, 205))
    }
}
