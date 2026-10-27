package com.ztransfer.ui.screen

import com.ztransfer.protocol.NikonCamera
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BurstGridItemsTest {
    private fun file(handle: Int) = NikonCamera.FileInfo(
        handle = handle,
        size = 1_000L,
        fileName = "DSC_${handle.toString().padStart(4, '0')}.JPG",
        captureDate = "20260724T120000"
    )

    private val files = listOf(file(1), file(2), file(3))
    private val burstIds = files.associate { it.handle to "burst-a" }

    @Test
    fun disabledSettingKeepsOriginalPhotoSequence() {
        val items = buildThumbnailGridItems(
            files = files,
            burstIdByHandle = burstIds,
            collapseBurstPhotos = false,
            expandedBurstIds = emptySet()
        )

        assertEquals(files.map { it.handle }, items.map {
            (it as ThumbnailGridItem.Photo).file.handle
        })
    }

    @Test
    fun collapsedAndExpandedModelsKeepOnePersistentCollection() {
        val collapsed = buildThumbnailGridItems(
            files = files,
            burstIdByHandle = burstIds,
            collapseBurstPhotos = true,
            expandedBurstIds = emptySet()
        )
        assertEquals(1, collapsed.size)
        assertTrue(collapsed.single() is ThumbnailGridItem.BurstCollection)

        val expanded = buildThumbnailGridItems(
            files = files,
            burstIdByHandle = burstIds,
            collapseBurstPhotos = true,
            expandedBurstIds = setOf("burst-a")
        )
        assertTrue(expanded.first() is ThumbnailGridItem.BurstCollection)
        assertEquals(files.map { it.handle }, expanded.drop(1).map {
            (it as ThumbnailGridItem.Photo).file.handle
        })
    }

    @Test
    fun aSingleVisibleMemberFallsBackToAnOrdinaryPhoto() {
        val items = buildThumbnailGridItems(
            files = files.take(1),
            burstIdByHandle = burstIds,
            collapseBurstPhotos = true,
            expandedBurstIds = emptySet()
        )

        assertEquals(1, items.size)
        assertTrue(items.single() is ThumbnailGridItem.Photo)
    }

    @Test
    fun expandedModelContainsEveryMemberWithoutAnimationWindowTruncation() {
        val manyFiles = (1..120).map(::file)
        val manyBurstIds = manyFiles.associate { it.handle to "burst-large" }
        val items = buildThumbnailGridItems(
            files = manyFiles,
            burstIdByHandle = manyBurstIds,
            collapseBurstPhotos = true,
            expandedBurstIds = setOf("burst-large")
        )

        assertTrue(items.first() is ThumbnailGridItem.BurstCollection)
        assertEquals(manyFiles.map { it.handle }, items.drop(1).map {
            (it as ThumbnailGridItem.Photo).file.handle
        })
    }

    @Test
    fun deletingTheFirstBurstFrameKeepsItsSuccessorExpandedInTheFirstGridModel() {
        val previousFiles = (4 downTo 1).map(::file)
        val currentFiles = previousFiles.filterNot { it.handle == 1 }
        val previousGroups = computeBurstGroups(previousFiles)
        val currentGroups = computeBurstGroups(currentFiles)
        val previousId = previousGroups.single().id
        val currentId = currentGroups.single().id
        assertTrue(previousId != currentId)

        // Build directly from the synchronously reconciled IDs, without first publishing a
        // collapsed model while the owner's mutable expansion map still contains the old ID.
        val effectiveExpandedIds = reconciledExpandedBurstIds(
            previousGroups = previousGroups,
            currentGroups = currentGroups,
            expandedIds = setOf(previousId),
        )
        val items = buildThumbnailGridItems(
            files = currentFiles,
            burstIdByHandle = currentFiles.associate { it.handle to currentId },
            collapseBurstPhotos = true,
            expandedBurstIds = effectiveExpandedIds,
        )

        assertEquals(setOf(currentId), effectiveExpandedIds)
        assertEquals(currentId, (items.first() as ThumbnailGridItem.BurstCollection).id)
        assertEquals(currentFiles.map { it.handle }, items.drop(1).map {
            (it as ThumbnailGridItem.Photo).file.handle
        })
        assertEquals(currentFiles.size + 1, items.size)
    }
}
