package com.ztransfer.ui.screen

import com.ztransfer.protocol.NikonCamera
import org.junit.Assert.assertEquals
import org.junit.Test

class CameraRemovalPresentationTest {
    private fun file(handle: Int, day: String = "20260827") = NikonCamera.FileInfo(
        handle = handle,
        size = 1_000L,
        fileName = "DSC_${handle.toString().padStart(4, '0')}.JPG",
        captureDate = "${day}T120000",
    )

    @Test
    fun removalDetectionReturnsOnlyDatesThatLostPublishedHandles() {
        val first = file(1)
        val second = file(2)

        assertEquals(emptySet<String>(), publishedCameraChanges(emptyList(), listOf(first)).removedDates)
        assertEquals(emptySet<String>(), publishedCameraChanges(listOf(first), listOf(first, second)).removedDates)
        assertEquals(setOf("20260827"), publishedCameraChanges(listOf(first), listOf(second)).removedDates)
        assertEquals(setOf("20260827"), publishedCameraChanges(listOf(first, second), listOf(second)).removedDates)
        assertEquals(
            setOf("20260827"),
            publishedCameraChanges(
                previous = listOf(first),
                current = listOf(second, file(3)),
            ).removedDates,
        )
    }

    @Test
    fun removalAnimationScopeDoesNotIncludeUnchangedDateGroups() {
        val removedDay = file(1, day = "20260826")
        val unchangedDay = file(2, day = "20260827")

        assertEquals(
            setOf("20260826"),
            publishedCameraChanges(
                previous = listOf(unchangedDay, removedDay),
                current = listOf(unchangedDay),
            ).removedDates,
        )
    }

    @Test
    fun oneCatalogUpdateCanAffectSeveralDatesWithoutIncludingSurvivors() {
        val removedOlderDay = file(1, day = "20260825")
        val removedNewerDay = file(2, day = "20260827")
        val survivingDay = file(3, day = "20260826")

        assertEquals(
            setOf("20260825", "20260827"),
            publishedCameraChanges(
                previous = listOf(removedNewerDay, survivingDay, removedOlderDay),
                current = listOf(survivingDay),
            ).removedDates,
        )
    }

    @Test
    fun switchingToSurvivingBackupAliasIsNotAVisibleRemoval() {
        val primary = file(1, day = "20260826")
        val survivingAlias = primary.copy(handle = 2)

        assertEquals(
            PhotoCatalogChanges(emptySet(), emptySet()),
            publishedCameraChanges(
                previous = listOf(primary),
                current = listOf(survivingAlias),
            ),
        )
    }

    @Test
    fun firstCaptureOnAnEmptyCameraIsAnAddition() {
        val changes = publishedCameraChanges(emptyList(), listOf(file(1)))

        assertEquals(setOf("20260827"), changes.addedDates)
        assertEquals(emptySet<String>(), changes.removedDates)
        assertEquals(changes.addedDates, changes.affectedDates)
    }

    @Test
    fun addedDatesDoNotIncludeExistingPhotosOrDuplicateDays() {
        val existing = file(1, day = "20260825")
        val first = file(2, day = "20260826")
        val second = file(3, day = "20260826")
        val third = file(4, day = "20260827")
        val changes = publishedCameraChanges(
            previous = listOf(existing),
            current = listOf(third, first, second, existing),
        )

        assertEquals(setOf("20260826", "20260827"), changes.addedDates)
        assertEquals(emptySet<String>(), changes.removedDates)
    }

    @Test
    fun refreshingMetadataAndReorderingHandlesDoesNotAnimatePhotos() {
        val first = file(1)
        val second = file(2)
        val changes = publishedCameraChanges(
            previous = listOf(first, second),
            current = listOf(
                second.copy(isProtected = true, storageIds = setOf(1, 2)),
                first.copy(size = 2_000L, captureDate = "20260826T120000"),
            ),
        )

        assertEquals(PhotoCatalogChanges(emptySet(), emptySet()), changes)
        assertEquals(emptySet<String>(), changes.affectedDates)
    }

    @Test
    fun addingOrRemovingABackupAliasLeavesTheLogicalPhotoUnchanged() {
        val primary = file(1)
        val alias = primary.copy(handle = 2)
        val noChanges = PhotoCatalogChanges(emptySet(), emptySet())

        assertEquals(noChanges, publishedCameraChanges(listOf(primary), listOf(primary, alias)))
        assertEquals(noChanges, publishedCameraChanges(listOf(primary, alias), listOf(primary)))
    }

    @Test
    fun mixedUpdateIncludesBothChangedDaysButExcludesAliasAndMetadataUpdates() {
        val primary = file(1, day = "20260824")
        val alias = primary.copy(handle = 2)
        val removed = file(3, day = "20260825")
        val unchanged = file(4, day = "20260826")
        val added = file(5, day = "20260827")
        val changes = publishedCameraChanges(
            previous = listOf(primary, removed, unchanged),
            current = listOf(added, unchanged.copy(isProtected = true), alias),
        )

        assertEquals(setOf("20260827"), changes.addedDates)
        assertEquals(setOf("20260825"), changes.removedDates)
        assertEquals(setOf("20260825", "20260827"), changes.affectedDates)
    }

    @Test
    fun replacementOnTheSameDayAppearsOnceInAffectedDates() {
        val changes = publishedCameraChanges(listOf(file(1)), listOf(file(2)))

        assertEquals(setOf("20260827"), changes.addedDates)
        assertEquals(setOf("20260827"), changes.removedDates)
        assertEquals(setOf("20260827"), changes.affectedDates)
    }

    @Test
    fun deletingEveryPhotoAndUnknownDatesUseTheSameGroupingKey() {
        val unknown = file(1).copy(captureDate = null)
        val known = file(2)
        val changes = publishedCameraChanges(listOf(unknown, known), emptyList())

        assertEquals(emptySet<String>(), changes.addedDates)
        assertEquals(setOf(UNKNOWN_DATE_KEY, "20260827"), changes.removedDates)
        assertEquals(
            setOf(UNKNOWN_DATE_KEY),
            publishedCameraChanges(emptyList(), listOf(unknown)).addedDates,
        )
        assertEquals(PhotoCatalogChanges(emptySet(), emptySet()), publishedCameraChanges(emptyList(), emptyList()))
    }

    @Test
    fun deletingTheOnlyPhotoRemovesItsWholeDateGroup() {
        val removedDay = file(1, day = "20260826")
        val survivingDay = file(2, day = "20260827")

        assertEquals(2, groupFilesByDate(listOf(survivingDay, removedDay)).size)
        val remainingGroups = groupFilesByDate(listOf(survivingDay))

        assertEquals(listOf("20260827"), remainingGroups.map { it.date })
        assertEquals(listOf(survivingDay), remainingGroups.single().files)
    }
}
