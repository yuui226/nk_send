package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraFileInfo
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SharedThumbnailGridModelTest {
    private fun file(id: Int) = CameraFileInfo(id, 1000L, "DSC_${id}.JPG", "20260905T120000",
        storageIds = setOf(0x10001))

    @Test fun interleavedCollectionRetainsOriginalInsertionPositionAndEveryStableKey() {
        val files = (1..5).map(::file)
        val membership = mapOf(2 to "b", 4 to "b")
        val closed = buildThumbnailGridItems(files, membership, true, emptySet())
        assertEquals(listOf(1, "burst_collection_b", 3, 5), closed.map { it.key })
        val opened = buildThumbnailGridItems(files, membership, true, setOf("b"))
        assertEquals(listOf(1, "burst_collection_b", 2, 4, 3, 5), opened.map { it.key })
        assertEquals(opened.size, opened.map { it.key }.toSet().size)
        assertEquals(listOf(files[1], files[3]), (opened[1] as ThumbnailGridItem.BurstCollection).files)
        assertEquals(listOf("photo", "burst_collection", "photo", "photo", "photo", "photo"), opened.map { it.reuseContentType })
    }

    @Test fun backupAliasHandleSwitchPreservesExpandedLogicalCollection() {
        val files = (1..3).map(::file)
        val old = BurstPhotoGroup("first-card", files)
        val aliases = files.map { it.copy(handle = it.handle + 100, storageIds = setOf(0x20001)) }
        val current = BurstPhotoGroup("second-card", aliases)
        assertEquals(setOf(current.id), reconciledExpandedBurstIds(listOf(old), listOf(current), setOf(old.id)))
        val changed = BurstPhotoGroup("reused-handles", aliases.map { it.copy(size = 2000) })
        assertTrue(reconciledExpandedBurstIds(listOf(old), listOf(changed), setOf(old.id)).isEmpty())
    }

    @Test fun unchangedGroupsStillDiscardStaleExpandedIdentifiers() {
        val groups = listOf(BurstPhotoGroup("visible", (1..3).map(::file)))
        assertEquals(setOf("visible"), reconciledExpandedBurstIds(groups, groups, setOf("visible", "deleted")))
        assertTrue(reconciledExpandedBurstIds(groups, emptyList(), setOf("visible")).isEmpty())
        assertTrue(reconciledExpandedBurstIds(groups, groups, emptySet()).isEmpty())
    }

    @Test fun filteringToOneMemberKeepsItsOriginalMetadataAndNeverInventsACollection() {
        val original = file(7).copy(isProtected = true, storageIds = setOf(0x10001, 0x20001))
        val result = buildThumbnailGridItems(listOf(original), mapOf(7 to "b", 8 to "b"), true, setOf("b"))
        val cell = result.single() as ThumbnailGridItem.Photo
        assertEquals(original, cell.file)
        assertEquals(7, cell.key)
        assertEquals("b", cell.burstId)
    }
}
