package com.ztransfer.protocol

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** An adapter is bound to one body, shooting bank and explicit custom slot for its lifetime. */
internal interface PictureControlSlotAccess {
    val cameraIdentity: String
    val slot: Int
    suspend fun checkSession()
    suspend fun readSlot(): ByteArray?
    fun matchesSlot(expected: ByteArray?, actual: ByteArray?): Boolean =
        if (expected == null) actual == null else actual?.contentEquals(expected) == true
    suspend fun writeSlot(data: ByteArray)
    suspend fun clearSlot()
    suspend fun readSelection(): Long
    suspend fun select(value: Long)
}

internal enum class PictureControlWriteStage { BACKUP, WRITE, VERIFY, ACTIVATE }
internal class PictureControlReplacementException(
    val stage: PictureControlWriteStage,
    val originalRestored: Boolean,
    cause: Exception,
) : Exception("Picture Control operation failed at $stage (restored=$originalRestored)", cause)

/**
 * Preserve registered defaults AND current adjustments. Back up before mutation; verify both
 * data and selection. Cancellation cannot interrupt an already-started mutation or its rollback.
 * The global lock also serializes activation/clearing across slots and recreated panels.
 */
internal class PictureControlReplacement(private val backup: PictureControlBackupStore) {
    private companion object { val mutex = Mutex() }

    private suspend fun snapshot(access: PictureControlSlotAccess): PictureControlSlotSnapshot {
        require(access.slot in NIKON_PICTURE_CONTROL_SLOTS) { "Only C1–C9 may be changed" }
        access.checkSession()
        val data = access.readSlot()
        val selection = access.readSelection()
        check(data != null || selection != access.slot.toLong()) { "An empty custom slot is selected" }
        return PictureControlSlotSnapshot(access.cameraIdentity, access.slot, data, selection)
    }

    suspend fun apply(access: PictureControlSlotAccess, dataset: ByteArray) = mutex.withLock {
        require(dataset.size in 1..NikonPictureControlFile.MAX_BYTES)
        val prepared = dataset.copyOf()
        val previous = snapshot(access)
        backup.saveOriginal(previous)
        currentCoroutineContext().ensureActive()
        access.checkSession()
        withContext(NonCancellable) {
            var stage = PictureControlWriteStage.WRITE
            try {
                if (!access.matchesSlot(prepared, previous.data())) access.writeSlot(prepared)
                stage = PictureControlWriteStage.VERIFY
                check(access.matchesSlot(prepared, access.readSlot())) { "Picture Control read-back mismatch" }
                stage = PictureControlWriteStage.ACTIVATE
                selectVerified(access, access.slot.toLong())
            } catch (error: Exception) {
                throw PictureControlReplacementException(stage,
                    restoreSnapshot(access, previous, requireNotNull(previous.selection)), error)
            }
        }
    }

    /** Selecting a registered slot never rewrites its contents or creates an original backup. */
    suspend fun activate(access: PictureControlSlotAccess) = mutex.withLock {
        val previous = snapshot(access)
        check(previous.data() != null) { "An empty custom slot cannot be activated" }
        if (previous.selection == access.slot.toLong()) return@withLock
        currentCoroutineContext().ensureActive()
        access.checkSession()
        withContext(NonCancellable) {
            try { selectVerified(access, access.slot.toLong()) }
            catch (error: Exception) {
                val restored = try { selectVerified(access, requireNotNull(previous.selection)); true }
                    catch (_: Exception) { false }
                throw PictureControlReplacementException(PictureControlWriteStage.ACTIVATE, restored, error)
            }
        }
    }

    suspend fun clear(access: PictureControlSlotAccess) = mutex.withLock {
        val previous = snapshot(access)
        if (previous.data() == null) return@withLock
        backup.saveOriginal(previous)
        currentCoroutineContext().ensureActive()
        access.checkSession()
        withContext(NonCancellable) {
            try {
                // Never leave an unregistered slot selected, even between protocol commands.
                val selection = selectionAfterRestore(access.slot, null, requireNotNull(previous.selection))
                if (previous.selection != selection) selectVerified(access, selection)
                access.clearSlot()
                check(access.matchesSlot(null, access.readSlot())) { "Custom slot was not cleared" }
                check(access.readSelection() == selection) { "Clearing changed the active Picture Control" }
            } catch (error: Exception) {
                throw PictureControlReplacementException(PictureControlWriteStage.VERIFY,
                    restoreSnapshot(access, previous, requireNotNull(previous.selection)), error)
            }
        }
    }

    suspend fun restoreOriginal(access: PictureControlSlotAccess) = mutex.withLock {
        require(access.slot in NIKON_PICTURE_CONTROL_SLOTS) { "Only C1–C9 may be restored" }
        access.checkSession()
        val original = requireNotNull(backup.load(access.cameraIdentity, access.slot)) { "No original slot backup" }
        val currentSelection = access.readSelection()
        // A damaged current dataset must not prevent recovery from the durable original.
        // Unknown is distinct from a confirmed empty slot and cannot be used for rollback.
        val previous = try {
            PictureControlSlotSnapshot(access.cameraIdentity, access.slot, access.readSlot(), currentSelection)
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            currentCoroutineContext().ensureActive()
            access.checkSession()
            null
        }
        currentCoroutineContext().ensureActive()
        access.checkSession()
        withContext(NonCancellable) {
            // Restore only this slot's contents. An old backup's active selection may refer to
            // another slot the user has since cleared; do not revive that stale selection.
            val selection = selectionAfterRestore(access.slot, original.data(), currentSelection)
            if (!restoreSnapshot(access, original, selection)) {
                val restored = previous != null && restoreSnapshot(access, previous, currentSelection)
                throw PictureControlReplacementException(PictureControlWriteStage.VERIFY, restored,
                    IllegalStateException("Original slot restoration was not confirmed"))
            }
        }
    }

    private fun selectionAfterRestore(slot: Int, data: ByteArray?, current: Long): Long =
        if (data == null && current == slot.toLong()) NIKON_PICTURE_CONTROL_STANDARD.toLong() else current

    private suspend fun selectVerified(access: PictureControlSlotAccess, selection: Long) {
        access.checkSession()
        access.select(selection)
        check(access.readSelection() == selection) { "Picture Control activation was not confirmed" }
    }

    private suspend fun restoreSnapshot(access: PictureControlSlotAccess,
        snapshot: PictureControlSlotSnapshot, selection: Long): Boolean = try {
        access.checkSession()
        val original = snapshot.data()
        check(original != null || selection != access.slot.toLong()) { "Cannot activate an empty restored slot" }
        val alreadyRestored = try { access.matchesSlot(original, access.readSlot()) } catch (_: Exception) { false }
        if (!alreadyRestored) {
            access.checkSession()
            if (original == null) {
                // Failed activation may already have selected the now-to-be-cleared slot.
                if (access.readSelection() == access.slot.toLong()) selectVerified(access, selection)
                access.clearSlot()
            } else access.writeSlot(original)
        }
        check(access.matchesSlot(original, access.readSlot())) { "Slot rollback read-back mismatch" }
        selectVerified(access, selection)
        true
    } catch (_: Exception) { false } // Retain the durable backup after a disconnect or failed rollback.
}
