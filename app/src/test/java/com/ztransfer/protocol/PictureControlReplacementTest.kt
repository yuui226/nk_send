package com.ztransfer.protocol

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class PictureControlReplacementTest {
    @get:Rule val temporary = TemporaryFolder()

    private class Camera(var bytes: ByteArray? = byteArrayOf(10), override val slot: Int = 209) : PictureControlSlotAccess {
        override val cameraIdentity = "Nikon\u0000Z 30\u0000123456"
        var selection = 1L
        var connected = true
        var corruptNextWrite = false
        var rejectNextActivation = false
        val operations = mutableListOf<String>()
        override suspend fun checkSession() { check(connected) }
        override suspend fun readSlot(): ByteArray? { checkSession(); operations += "read C9"; return bytes?.copyOf() }
        override suspend fun writeSlot(data: ByteArray) {
            checkSession(); operations += "write C9"
            bytes = if (corruptNextWrite) byteArrayOf(99) else data.copyOf()
            corruptNextWrite = false
        }
        override suspend fun clearSlot() { checkSession(); operations += "clear C9"; bytes = null }
        override suspend fun readSelection(): Long { checkSession(); operations += "read selection"; return selection }
        override suspend fun select(value: Long) {
            checkSession(); operations += "select $value"
            if (rejectNextActivation) rejectNextActivation = false else selection = value
        }
    }

    @Test fun systemAndOutOfRangeSlotsAreRejectedBeforeAnyCameraOperation() = runBlocking {
        for (slot in listOf(0, 1, 8, 200, 210, 65535)) {
            val camera = Camera(slot = slot)
            val folder = temporary.newFolder()
            try {
                PictureControlReplacement(PictureControlBackupStore(folder)).apply(camera, byteArrayOf(20))
                fail("A non-custom slot must never be edited")
            } catch (_: IllegalArgumentException) { }
            assertArrayEquals(byteArrayOf(10), camera.bytes)
            assertTrue(camera.operations.isEmpty())
            assertTrue(folder.listFiles()!!.isEmpty())
        }
    }

    @Test fun onlyLastSlotIsReplacedAndReadBeforeActivation() = runBlocking {
        val camera = Camera()
        val store = PictureControlBackupStore(temporary.newFolder())
        PictureControlReplacement(store).apply(camera, byteArrayOf(20))
        assertArrayEquals(byteArrayOf(20), camera.bytes)
        assertEquals(209L, camera.selection)
        assertEquals(listOf("read C9", "read selection", "write C9", "read C9", "select 209", "read selection"), camera.operations)
        assertArrayEquals(byteArrayOf(10), store.load(camera.cameraIdentity, 209)!!.data())
    }

    @Test fun repeatedReplacementPreservesFirstOriginalAcrossAppRestart() = runBlocking {
        val folder = temporary.newFolder()
        val camera = Camera()
        PictureControlReplacement(PictureControlBackupStore(folder)).apply(camera, byteArrayOf(20))
        PictureControlReplacement(PictureControlBackupStore(folder)).apply(camera, byteArrayOf(30))
        assertArrayEquals(byteArrayOf(30), camera.bytes)
        assertArrayEquals(byteArrayOf(10), PictureControlBackupStore(folder).load(camera.cameraIdentity, 209)!!.data())
    }

    @Test fun anotherWriterWaitsUntilFailedReplacementHasFinishedRollback() = runBlocking {
        val camera = Camera().apply { rejectNextActivation = true }
        val store = PictureControlBackupStore(temporary.newFolder())
        val resumeFirstWrite = CompletableDeferred<Unit>()
        var pauseWrite = true
        val firstAccess = object : PictureControlSlotAccess by camera {
            override suspend fun writeSlot(data: ByteArray) {
                camera.writeSlot(data)
                if (pauseWrite) {
                    pauseWrite = false
                    resumeFirstWrite.await()
                }
            }
        }
        val first = async(start = CoroutineStart.UNDISPATCHED) {
            runCatching { PictureControlReplacement(store).apply(firstAccess, byteArrayOf(20)) }
        }
        val beforeSecond = camera.operations.toList()
        val second = async(start = CoroutineStart.UNDISPATCHED) {
            PictureControlReplacement(store).apply(camera, byteArrayOf(30))
        }
        try {
            assertEquals("The queued writer must not read or mutate C9 yet", beforeSecond, camera.operations)
        } finally {
            // The first transaction is deliberately non-cancellable after its write.
            resumeFirstWrite.complete(Unit)
        }
        val failure = first.await().exceptionOrNull() as PictureControlReplacementException
        second.await()
        assertEquals(PictureControlWriteStage.ACTIVATE, failure.stage)
        assertTrue(failure.originalRestored)
        assertArrayEquals(byteArrayOf(30), camera.bytes)
        assertEquals(209L, camera.selection)
        assertArrayEquals(byteArrayOf(10), store.load(camera.cameraIdentity, 209)!!.data())
    }

    @Test fun readbackMismatchRestoresMostRecentPresetAndOriginalSelection() = runBlocking {
        val camera = Camera()
        val store = PictureControlBackupStore(temporary.newFolder())
        val writer = PictureControlReplacement(store)
        writer.apply(camera, byteArrayOf(20))
        camera.selection = 4
        camera.corruptNextWrite = true
        try {
            writer.apply(camera, byteArrayOf(30))
            fail("Expected read-back failure")
        } catch (error: PictureControlReplacementException) {
            assertEquals(PictureControlWriteStage.VERIFY, error.stage)
            assertTrue(error.originalRestored)
        }
        assertArrayEquals(byteArrayOf(20), camera.bytes)
        assertEquals(4L, camera.selection)
        assertArrayEquals(byteArrayOf(10), store.load(camera.cameraIdentity, 209)!!.data())
    }

    @Test fun emptyOriginalIsRestoredByClearingOnlyTheReservedSlot() = runBlocking {
        val camera = Camera(null).apply { rejectNextActivation = true }
        try {
            PictureControlReplacement(PictureControlBackupStore(temporary.newFolder())).apply(camera, byteArrayOf(20))
            fail("Expected activation failure")
        } catch (error: PictureControlReplacementException) {
            assertEquals(PictureControlWriteStage.ACTIVATE, error.stage)
            assertTrue(error.originalRestored)
        }
        assertNull(camera.bytes)
        assertEquals(1L, camera.selection)
        assertTrue(camera.operations.contains("clear C9"))
    }

    @Test fun corruptBackupBlocksMutationInsteadOfOverwritingTheBackup() = runBlocking {
        val folder = temporary.newFolder()
        val camera = Camera()
        val store = PictureControlBackupStore(folder)
        store.saveOriginal(PictureControlSlotSnapshot(camera.cameraIdentity, 209, byteArrayOf(10)))
        val file = folder.listFiles()!!.single()
        file.writeBytes(file.readBytes().dropLast(1).toByteArray())
        try {
            PictureControlReplacement(store).apply(camera, byteArrayOf(20))
            fail("Expected corrupt backup failure")
        } catch (_: Exception) { }
        assertArrayEquals(byteArrayOf(10), camera.bytes)
        assertFalse(camera.operations.any { it.startsWith("write") || it.startsWith("select") })
    }

    @Test fun unreadableCameraIsNeverTreatedAsAnEmptySlot() = runBlocking {
        val folder = temporary.newFolder()
        val camera = Camera().apply { connected = false }
        try {
            PictureControlReplacement(PictureControlBackupStore(folder)).apply(camera, byteArrayOf(20))
            fail("Expected disconnected camera failure")
        } catch (_: IllegalStateException) { }
        assertTrue(camera.operations.isEmpty())
        assertTrue(folder.listFiles()!!.isEmpty())
    }

    private fun unreadableWhenDamaged(camera: Camera): PictureControlSlotAccess = object : PictureControlSlotAccess by camera {
        override suspend fun readSlot(): ByteArray? {
            val bytes = camera.readSlot()
            require(bytes?.contentEquals(byteArrayOf(99)) != true) { "Malformed C9 data" }
            return bytes
        }
    }

    @Test fun malformedReadbackDoesNotPreventRestoringTheKnownPreviousDataset() = runBlocking {
        val camera = Camera().apply { corruptNextWrite = true }
        val store = PictureControlBackupStore(temporary.newFolder())
        try {
            PictureControlReplacement(store).apply(unreadableWhenDamaged(camera), byteArrayOf(20))
            fail("Expected malformed readback")
        } catch (error: PictureControlReplacementException) {
            assertEquals(PictureControlWriteStage.VERIFY, error.stage)
            assertTrue(error.originalRestored)
        }
        assertArrayEquals(byteArrayOf(10), camera.bytes)
        assertEquals(1L, camera.selection)
        assertArrayEquals(byteArrayOf(10), store.load(camera.cameraIdentity, 209)!!.data())
    }

    @Test fun manualRecoveryUsesKnownBackupWhenCurrentSlotCannotBeParsedIncludingEmptyOriginal() = runBlocking {
        for (original in listOf(null, byteArrayOf(10))) {
            val camera = Camera(original)
            val folder = temporary.newFolder()
            PictureControlReplacement(PictureControlBackupStore(folder)).apply(camera, byteArrayOf(20))
            camera.bytes = byteArrayOf(99)
            PictureControlReplacement(PictureControlBackupStore(folder)).restoreOriginal(unreadableWhenDamaged(camera))
            assertArrayEquals(original, camera.bytes)
            assertEquals(if (original == null) 1L else 209L, camera.selection)
            val stored = PictureControlBackupStore(folder).load(camera.cameraIdentity, 209)!!
            assertArrayEquals(original, stored.data())
            assertEquals(1L, stored.selection)
        }
    }

    @Test fun failedRecoveryOfUnknownCurrentStateNeverInventsAnEmptyRollback() = runBlocking {
        val camera = Camera()
        val store = PictureControlBackupStore(temporary.newFolder())
        val replacement = PictureControlReplacement(store)
        replacement.apply(camera, byteArrayOf(20))
        camera.bytes = byteArrayOf(99)
        camera.operations.clear()
        val access = object : PictureControlSlotAccess by unreadableWhenDamaged(camera) {
            override suspend fun writeSlot(data: ByteArray) { throw java.io.IOException("Write unavailable") }
        }
        try {
            replacement.restoreOriginal(access)
            fail("Expected unconfirmed restoration")
        } catch (error: PictureControlReplacementException) { assertFalse(error.originalRestored) }
        assertArrayEquals(byteArrayOf(99), camera.bytes)
        assertFalse(camera.operations.any { it.startsWith("clear") || it.startsWith("select") })
        assertArrayEquals(byteArrayOf(10), store.load(camera.cameraIdentity, 209)!!.data())
    }

    @Test fun disconnectedCameraRetainsBackupAndNeverReportsSuccessfulRecovery() = runBlocking {
        val camera = Camera()
        val store = PictureControlBackupStore(temporary.newFolder())
        val access = object : PictureControlSlotAccess by camera {
            override suspend fun writeSlot(data: ByteArray) { camera.writeSlot(data); camera.connected = false }
        }
        try {
            PictureControlReplacement(store).apply(access, byteArrayOf(20))
            fail("Expected disconnect")
        } catch (error: PictureControlReplacementException) { assertFalse(error.originalRestored) }
        assertArrayEquals(byteArrayOf(10), store.load(camera.cameraIdentity, 209)!!.data())
        assertEquals(1, camera.operations.count { it == "write C9" })
        assertFalse(camera.operations.any { it.startsWith("clear") || it.startsWith("select") })
    }

    @Test fun failedRollbackVerificationDoesNotActivateUnverifiedData() = runBlocking {
        val camera = Camera()
        val access = object : PictureControlSlotAccess by camera {
            override suspend fun writeSlot(data: ByteArray) {
                camera.corruptNextWrite = true
                camera.writeSlot(data)
            }
        }
        try {
            PictureControlReplacement(PictureControlBackupStore(temporary.newFolder())).apply(access, byteArrayOf(20))
            fail("Expected failed rollback verification")
        } catch (error: PictureControlReplacementException) { assertFalse(error.originalRestored) }
        assertEquals(2, camera.operations.count { it == "write C9" })
        assertFalse(camera.operations.any { it.startsWith("select") })
    }

    @Test fun backupIsIsolatedByBodyAndSlotAndBuffersAreDefensive() {
        val store = PictureControlBackupStore(temporary.newFolder())
        val data = byteArrayOf(10)
        val snapshot = PictureControlSlotSnapshot("body-a", 209, data)
        data.fill(0)
        store.saveOriginal(snapshot)
        store.saveOriginal(PictureControlSlotSnapshot("body-b", 209, byteArrayOf(30)))
        assertArrayEquals(byteArrayOf(10), store.load("body-a", 209)!!.data())
        assertArrayEquals(byteArrayOf(30), store.load("body-b", 209)!!.data())
        assertNull(store.load("body-a", 208))
        snapshot.data()!!.fill(0)
        assertTrue(snapshot.matches(byteArrayOf(10)))
    }

    @Test fun concurrentStoreInstancesKeepTheSameFirstBackup() {
        val folder = temporary.newFolder()
        val start = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(4)
        try {
            val results = (1..4).map { value -> pool.submit(Callable {
                start.await()
                PictureControlBackupStore(folder).saveOriginal(
                    PictureControlSlotSnapshot("body", 209, byteArrayOf(value.toByte()))
                ).data()!!
            }) }
            start.countDown()
            val saved = results.map { it.get(5, TimeUnit.SECONDS) }
            saved.forEach { assertArrayEquals(saved.first(), it) }
            assertArrayEquals(saved.first(), PictureControlBackupStore(folder).load("body", 209)!!.data())
        } finally { pool.shutdownNow() }
    }
}
