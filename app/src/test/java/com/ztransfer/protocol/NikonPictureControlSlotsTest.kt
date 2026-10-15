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

        fun access(slot: Int, mode: Int = 0, body: String = "body", ops: Set<Int> = operations) =
            NikonPictureControlAccess("$body\u0000picture-control-${if (mode == 0) "photo" else "movie"}",
                slot, mode == 1, ops, { connected }, this, {})
        fun image() = banks.flatMap { bank -> bank.values.flatMap { listOf(it.defaults.copyOf(), it.current.copyOf()) } }
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
                    val choices = listOf(1, 2, 3, 4, 5, 6, 7, 8, 100, 111, 112) + (201..209).filter { it != unavailable }
                    ByteBuffer.allocate(12 + choices.size * 2).order(ByteOrder.LITTLE_ENDIAN)
                        .putShort(params[0].toShort()).putShort(4).put(1).putShort(8)
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
                    if (requested in 201..209) check(banks[mode].getValue(requested).current.any { it != 0.toByte() })
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
        assertFalse(camera.calls.any { it.op == 0x90CC && it.params[0] == 204 })
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
