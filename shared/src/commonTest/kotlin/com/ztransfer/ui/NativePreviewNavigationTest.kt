package com.ztransfer.ui

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.screen.*
import kotlin.test.*

class NativePreviewNavigationTest {
    private val files = (1..5).map { CameraFileInfo(it, 10, "$it.JPG", "20260905T120000") }
    private val groups = listOf(FileGroup("new", files.take(3)), FileGroup("old", files.drop(3)))
    private val bursts = mapOf(1 to "b", 2 to "b")

    @Test fun collapsedPreviewUsesGridOrderAndOpeningSourcesStillIncludeAllMembers() {
        val items = nativePreviewItems(groups, bursts, true, emptySet())
        assertEquals(4, items.size)
        assertEquals(listOf(1, 2), (items.first() as PhotoPreviewItem.BurstCollection).files.map { it.handle })
        assertEquals(listOf(3, 4, 5), items.filterIsInstance<PhotoPreviewItem.Photo>().map { it.file.handle })
        assertEquals(files, snapshotPreviewSessionSources(items) { it }.values.toList())
    }
    @Test fun longPressExpansionAffectsOnlySnapshotAndNeverReordersSurroundingPhotos() {
        val expanded = mutableSetOf<String>()
        val items = nativePreviewItems(groups, bursts, true, expanded + "b")
        assertTrue(expanded.isEmpty())
        assertEquals(6, items.size)
        assertEquals(files, items.filterIsInstance<PhotoPreviewItem.Photo>().map { it.file })
        assertEquals(files, nativePreviewItems(groups, bursts, false, emptySet()).filterIsInstance<PhotoPreviewItem.Photo>().map { it.file })
    }
    @Test fun dismissIndexCountsHeadersCollectionsAndCollapsedDates() {
        assertNull(nativePreviewGridIndex(1, groups, bursts, true, emptySet(), emptySet()))
        assertEquals(2, nativePreviewGridIndex(1, groups, bursts, true, setOf("b"), emptySet()))
        assertEquals(4, nativePreviewGridIndex(3, groups, bursts, true, setOf("b"), emptySet()))
        assertEquals(6, nativePreviewGridIndex(4, groups, bursts, true, setOf("b"), emptySet()))
        assertEquals(2, nativePreviewGridIndex(4, groups, bursts, true, setOf("b"), setOf("new")))
        assertNull(nativePreviewGridIndex(1, groups, bursts, true, setOf("b"), setOf("new")))
        assertNull(nativePreviewGridIndex(99, groups, bursts, true, setOf("b"), emptySet()))
    }
    @Test fun filteredSingleBurstMemberIsAnOrdinaryPhotoAndEmptyCatalogHasNoReturnTarget() {
        val filtered = listOf(FileGroup("new", listOf(files.first(), files[2])))
        assertEquals(listOf(1, 3), nativePreviewItems(filtered, bursts, true, emptySet())
            .filterIsInstance<PhotoPreviewItem.Photo>().map { it.file.handle })
        assertEquals(1, nativePreviewGridIndex(1, filtered, bursts, true, emptySet(), emptySet()))
        assertNull(nativePreviewGridIndex(1, emptyList(), bursts, true, setOf("b"), emptySet()))
    }
    @Test fun scrollRunwayKeepsExactThresholdAndBothDirections() {
        for (columns in -1..6) {
            val runway = columns.coerceIn(1, 4) * 3
            assertNull(nativePreviewScrollApproach(100 + runway * 2, 100, columns))
            assertNull(nativePreviewScrollApproach(100 - runway * 2, 100, columns))
            assertEquals(100 + runway + 1, nativePreviewScrollApproach(101 + runway * 2, 100, columns))
            assertEquals(99 - runway, nativePreviewScrollApproach(99 - runway * 2, 100, columns))
        }
    }
}
