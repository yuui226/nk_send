package com.ztransfer.catalog

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class CameraBrowsePolicyTest {
    @Test
    fun newestFirstOrderIsStableAndLeavesMissingDatesLast() {
        val raw = file(1, "RAW.NEF", "20260806T120000")
        val jpeg = file(2, "JPEG.JPG", "20260806T120000")
        val newer = file(3, "NEW.JPG", "20260807T010000")
        val missing = file(4, "NONE.JPG", null)

        val ordered = newestFirstCameraFiles(listOf(raw, missing, jpeg, newer))

        assertEquals(listOf(3, 1, 2, 4), ordered.map(File::handle))
        assertSame(raw, ordered[1])
        assertSame(jpeg, ordered[2])
    }

    @Test
    fun groupsKeepLooseDateKeysAndExistingDescendingOrder() {
        val sameTimeRaw = file(1, "A.NEF", "20260806T120000")
        val sameTimeJpeg = file(2, "A.JPG", "20260806T120000")
        val later = file(3, "B.JPG", "20260806T130000")
        val olderDay = file(4, "C.JPG", "20260805T235959")
        val malformed = file(5, "D.JPG", "bad")
        val missing = file(6, "E.JPG", null)

        val groups = groupCameraFilesByDate(
            listOf(sameTimeRaw, olderDay, missing, sameTimeJpeg, later, malformed),
        )

        assertEquals(
            listOf(UNKNOWN_CAPTURE_DATE_GROUP_KEY, "bad", "20260806", "20260805"),
            groups.map { it.date },
        )
        assertEquals(listOf(3, 1, 2), groups[2].files.map(File::handle))
        assertSame(sameTimeRaw, groups[2].files[1])
        assertSame(sameTimeJpeg, groups[2].files[2])
    }

    @Test
    fun everyFilterCombinesWithAndSemanticsAndPreservesOrder() {
        val files = listOf(
            file(1, "A.JPG", "20260805T120000", protected = true, storageIds = setOf(11)),
            file(2, "B.JPG", "20260806T120000", protected = true, storageIds = setOf(11, 22)),
            file(3, "C.NEF", "20260806T120001", protected = true, storageIds = setOf(22)),
            file(4, "D.JPG", "20260806T120002", protected = false, storageIds = setOf(22)),
            file(5, "E.JPG", null, protected = true, storageIds = setOf(22)),
        )
        val criteria = CameraFileFilter(
            extensions = setOf(".jpg"),
            protectedOnly = true,
            burstOnly = true,
            untransferredOnly = true,
            selectedStorageIds = setOf(22),
            dateRange = CaptureDayRange.between(20260806, 20260806),
        )

        assertEquals(
            listOf(2),
            filterCameraFiles(
                files = files,
                criteria = criteria,
                burstHandles = setOf(2, 3, 4),
                transferredHandles = setOf(3),
            ).map(File::handle),
        )
    }

    @Test
    fun nullAndEmptyFilterValuesRetainTheirDifferentMeanings() {
        val first = file(1, "A.JPG", "20260806T120000", storageIds = setOf(11, 22))
        val second = file(2, "B.NEF", "20260806T120001", storageIds = setOf(22))
        val files = listOf(first, second)

        assertEquals(files, filterCameraFiles(files, CameraFileFilter()))
        assertEquals(emptyList(), filterCameraFiles(files, CameraFileFilter(extensions = emptySet())))
        assertEquals(
            emptyList(),
            filterCameraFiles(files, CameraFileFilter(selectedStorageIds = emptySet())),
        )
        assertEquals(
            listOf(first),
            filterCameraFiles(files, CameraFileFilter(selectedStorageIds = setOf(11))),
        )
    }

    @Test
    fun storageSlotSelectionRulesRemainStable() {
        val slots = listOf(1, 2)
        assertTrue(isStorageSlotSelected(null, 1))
        assertFalse(isStorageSlotSelected(2, 1))
        assertTrue(storageFilterSlots(emptyList()).isEmpty())
        assertTrue(storageFilterSlots(listOf(2)).isEmpty())
        assertEquals(listOf(1, 2), storageFilterSlots(listOf(2, 1, 2)))
        assertEquals(2, toggleStorageSlotSelection(null, 1, slots))
        assertEquals(2, toggleStorageSlotSelection(2, 2, slots))
        assertNull(toggleStorageSlotSelection(2, 1, slots))
        assertEquals(2, toggleStorageSlotSelection(2, 9, slots))
        assertEquals(
            2,
            normalizeStorageSlotFilter(2, emptyList(), hasCompletedFileScan = false),
        )
        assertNull(normalizeStorageSlotFilter(2, emptyList(), hasCompletedFileScan = true))
        assertEquals(2, normalizeStorageSlotFilter(2, slots, hasCompletedFileScan = true))
    }

    private data class File(
        override val handle: Int,
        override val fileName: String,
        override val captureDate: String?,
        override val isProtected: Boolean = false,
        override val storageIds: Set<Int> = emptySet(),
    ) : CameraCatalogFile {
        override val extension: String = cameraFileExtension(fileName)
    }

    private fun file(
        handle: Int,
        fileName: String,
        captureDate: String?,
        protected: Boolean = false,
        storageIds: Set<Int> = emptySet(),
    ) = File(
        handle = handle,
        fileName = fileName,
        captureDate = captureDate,
        isProtected = protected,
        storageIds = storageIds,
    )
}
