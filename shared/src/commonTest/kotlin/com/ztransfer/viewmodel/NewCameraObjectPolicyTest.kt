package com.ztransfer.viewmodel

import com.ztransfer.protocol.CameraFileInfo
import kotlin.test.*

class NewCameraObjectPolicyTest {
    private fun file(handle: Int = 7, name: String = "DSC_0007.JPG", size: Long = 3,
                     date: String? = "20260906T120000", stores: Set<Int> = setOf(0x10001)) =
        CameraFileInfo(handle, size, name, date, false, stores)

    @Test fun admissionPreservesInvalidHandlesBaselineAndVisibleRowRules() {
        for (known in listOf(null, emptySet(), setOf(7))) {
            assertFalse(NewCameraObjectPolicy.shouldResolve(0, known, emptyList()))
            assertFalse(NewCameraObjectPolicy.shouldResolve(-1, known, emptyList()))
            assertFalse(NewCameraObjectPolicy.shouldResolve(7, known, listOf(file())))
        }
        assertTrue(NewCameraObjectPolicy.shouldResolve(Int.MIN_VALUE, null, emptyList()))
        assertTrue(NewCameraObjectPolicy.shouldResolve(7, null, emptyList()))
        assertTrue(NewCameraObjectPolicy.shouldResolve(7, emptySet(), emptyList()))
        assertFalse(NewCameraObjectPolicy.shouldResolve(7, setOf(7), emptyList()))
        // A different alias handle still needs metadata before logical deduplication is possible.
        assertTrue(NewCameraObjectPolicy.shouldResolve(8, setOf(7), listOf(file())))
    }

    @Test fun newRowsPrependWithoutChangingPriorOrderOrObjects() {
        val previous = listOf(file(7), file(8, name = "OLD.NEF"))
        val incoming = file(9, name = "NEW.MOV")
        assertTrue(NewCameraObjectPolicy.isNew(previous, incoming.handle, incoming))
        val result = NewCameraObjectPolicy.publish(previous, incoming.handle, incoming)
        assertSame(incoming, result[0]); assertSame(previous[0], result[1]); assertSame(previous[1], result[2])
        assertEquals(2, previous.size)
    }

    @Test fun backupAliasExpandsStoresButKeepsPrimaryMetadataAndIsNotNew() {
        val primary = file(); val other = file(11, "OTHER.JPG")
        val previous = listOf(primary, other)
        val alias = file(8, stores = setOf(0x20001))
        assertFalse(NewCameraObjectPolicy.isNew(previous, alias.handle, alias))
        val result = NewCameraObjectPolicy.publish(previous, alias.handle, alias)
        assertEquals(primary.copy(storageIds = setOf(0x10001, 0x20001)), result[0])
        assertSame(other, result[1]); assertNotSame(previous, result)
        assertEquals(setOf(0x10001), primary.storageIds)
        assertSame(result, NewCameraObjectPolicy.publish(result, alias.handle, alias))
    }

    @Test fun sameHandleDoesNotReplaceExistingNameSizeOrCaptureDate() {
        val primary = file(); val previous = listOf(primary)
        val incoming = file(name = "REUSED.JPG", size = 99, date = null)
        assertFalse(NewCameraObjectPolicy.isNew(previous, incoming.handle, incoming))
        assertSame(previous, NewCameraObjectPolicy.publish(previous, incoming.handle, incoming))
        assertSame(primary, previous[0])
    }

    @Test fun duplicateSearchKeepsFirstMatchEvenIfLaterRowHasTheExactHandle() {
        val first = file(1); val later = file(2, "OTHER.JPG")
        val incoming = file(2, stores = setOf(0x20001))
        val previous = listOf(first, later)
        val result = NewCameraObjectPolicy.publish(previous, 2, incoming)
        assertEquals(setOf(0x10001, 0x20001), result[0].storageIds)
        assertSame(later, result[1])
    }

    @Test fun scheduleKeepsOriginalCoalescingBatchSizeAttemptsAndBackoff() {
        assertEquals(90L, NewCameraObjectPolicy.COALESCE_MS)
        assertEquals(16, NewCameraObjectPolicy.RESOLVE_BATCH_SIZE)
        assertEquals(5, NewCameraObjectPolicy.RESOLVE_MAX_ATTEMPTS)
        assertEquals(listOf(180L, 360L, 720L, 1_400L), (1..4).map(NewCameraObjectPolicy::retryDelayMs))
        assertFailsWith<IndexOutOfBoundsException> { NewCameraObjectPolicy.retryDelayMs(0) }
        assertFailsWith<IndexOutOfBoundsException> { NewCameraObjectPolicy.retryDelayMs(5) }
    }

    @Test fun combinationsMatchFrozenPreExtractionAndroidPublicationAndAdmission() {
        val choices = listOf(file(), file(8), file(7, "OTHER.JPG"), file(9, date = null),
            file(10, size = 4), file(11, stores = setOf(0x20001)), file(Int.MIN_VALUE, "MOVIE.MOV"))
        val histories = listOf(emptyList<CameraFileInfo>()) + choices.map { listOf(it) } + choices.flatMap { a -> choices.map { b -> listOf(a, b) } }
        for (previous in histories) for (incoming in choices) {
            val expected = originalPublish(previous, incoming.handle, incoming)
            val actual = NewCameraObjectPolicy.publish(previous, incoming.handle, incoming)
            assertEquals(expected, actual)
            assertEquals(expected === previous, actual === previous)
            assertEquals(previous.none { it.handle == incoming.handle || it.logicalIdentity() == incoming.logicalIdentity() },
                NewCameraObjectPolicy.isNew(previous, incoming.handle, incoming))
            for (known in listOf(null, emptySet(), setOf(7, 9))) {
                val handle = incoming.handle
                val accepted = handle != 0 && handle != -1 && (known == null || handle !in known) && previous.none { it.handle == handle }
                assertEquals(accepted, NewCameraObjectPolicy.shouldResolve(handle, known, previous))
            }
        }
    }

    // Frozen from CameraViewModel at 8484b35. Never call the extracted decision to make the oracle.
    private fun originalPublish(files: List<CameraFileInfo>, handle: Int, info: CameraFileInfo): List<CameraFileInfo> {
        val duplicateIndex = files.indexOfFirst { it.handle == handle || it.logicalIdentity() == info.logicalIdentity() }
        if (duplicateIndex < 0) return listOf(info) + files
        val existing = files[duplicateIndex]
        val merged = mergeStorageMembership(existing, info)
        return if (merged === existing) files else files.toMutableList().apply { this[duplicateIndex] = merged }
    }
}
