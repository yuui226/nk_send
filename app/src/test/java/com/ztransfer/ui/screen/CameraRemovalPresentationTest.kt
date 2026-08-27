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

        assertEquals(emptySet<String>(), publishedCameraRemovalDates(emptyList(), listOf(first)))
        assertEquals(emptySet<String>(), publishedCameraRemovalDates(listOf(first), listOf(first, second)))
        assertEquals(setOf("20260827"), publishedCameraRemovalDates(listOf(first), listOf(second)))
        assertEquals(setOf("20260827"), publishedCameraRemovalDates(listOf(first, second), listOf(second)))
        assertEquals(
            setOf("20260827"),
            publishedCameraRemovalDates(
                previous = listOf(first),
                current = listOf(second, file(3)),
            ),
        )
    }

    @Test
    fun removalAnimationScopeDoesNotIncludeUnchangedDateGroups() {
        val removedDay = file(1, day = "20260826")
        val unchangedDay = file(2, day = "20260827")

        assertEquals(
            setOf("20260826"),
            publishedCameraRemovalDates(
                previous = listOf(unchangedDay, removedDay),
                current = listOf(unchangedDay),
            ),
        )
    }

    @Test
    fun oneCatalogUpdateCanAffectSeveralDatesWithoutIncludingSurvivors() {
        val removedOlderDay = file(1, day = "20260825")
        val removedNewerDay = file(2, day = "20260827")
        val survivingDay = file(3, day = "20260826")

        assertEquals(
            setOf("20260825", "20260827"),
            publishedCameraRemovalDates(
                previous = listOf(removedNewerDay, survivingDay, removedOlderDay),
                current = listOf(survivingDay),
            ),
        )
    }

    @Test
    fun switchingToSurvivingBackupAliasIsNotAVisibleRemoval() {
        val primary = file(1, day = "20260826")
        val survivingAlias = primary.copy(handle = 2)

        assertEquals(
            emptySet<String>(),
            publishedCameraRemovalDates(
                previous = listOf(primary),
                current = listOf(survivingAlias),
            ),
        )
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
