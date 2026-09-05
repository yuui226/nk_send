package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Offset
import com.ztransfer.protocol.CameraFileInfo
import kotlin.test.*

class PhotoPreviewBoundaryTest {
    private fun file(handle: Int) = CameraFileInfo(handle, 1234, "DSC_$handle.JPG", "20260905T123456")

    @Test fun expandedPagesPreserveOriginalCollectionObjectsAndIndependentGroups() {
        for (size in listOf(0,1,3,16,100)) {
            val a=PhotoPreviewItem.BurstCollection("a",(1..size).map(::file))
            val b=PhotoPreviewItem.BurstCollection("b",listOf(file(200),file(201)))
            val before=listOf(PhotoPreviewItem.Photo(file(0)),a,b,PhotoPreviewItem.Photo(file(300)))
            val expanded=expandPreviewBurst(before,1,a)
            assertEquals(4+size,expanded.size)
            assertEquals(listOf(0,"preview_burst_a","preview_burst_b",300),before.map { it.key })
            assertSame(a,expanded[1]); assertSame(b,expanded[size+2])
            for (page in 2 until size+2) assertEquals(1,previewBurstCollectionPage(expanded,page))
            assertNull(previewBurstCollectionPage(expanded,-1))
            assertNull(previewBurstCollectionPage(expanded,expanded.size))
            assertEquals(before,collapsePreviewBurst(expanded,"a"))
            assertEquals(expanded,collapsePreviewBurst(expanded,"absent"))
        }
    }

    @Test fun snapshotUsesOriginalEncounterOrderIncludingDuplicateHandlesAndNulls() {
        val one=file(1); val two=file(2)
        val items=listOf(PhotoPreviewItem.Photo(one),PhotoPreviewItem.BurstCollection("burst",listOf(two,one)))
        val calls=mutableListOf<Int>()
        val snapshot=snapshotPreviewSessionSources(items) {
            calls+=it.handle
            if (calls.size==3) null else "source-${calls.size}"
        }
        assertEquals(listOf(1,2,1),calls) // Keep original last-write-wins; do not silently deduplicate.
        assertEquals(listOf(1,2),snapshot.keys.toList())
        assertTrue(snapshot.containsKey(1)); assertNull(snapshot[1]); assertEquals("source-2",snapshot[2])
        calls.clear()
        assertEquals(2,snapshot.size)
    }

    @Test fun queueIntentHonorsExactSlopAndDirectionBoundaryWithoutStealingDiagonalPaging() {
        assertEquals(PreviewQueueDragDirection.UNDECIDED,previewQueueDragDirection(Offset(0f,-7.99f),8f))
        assertEquals(PreviewQueueDragDirection.UPWARD,previewQueueDragDirection(Offset(0f,-8f),8f))
        assertEquals(PreviewQueueDragDirection.UNDECIDED,previewQueueDragDirection(Offset(8f,-8f),8f))
        assertEquals(PreviewQueueDragDirection.UPWARD,previewQueueDragDirection(Offset(20f,-23f),8f))
        assertEquals(PreviewQueueDragDirection.UNDECIDED,previewQueueDragDirection(Offset(20f,-22.99f),8f))
        assertEquals(PreviewQueueDragDirection.REJECTED,previewQueueDragDirection(Offset(8.01f,-8f),8f))
        assertEquals(0f,previewQueueVisualOffset(99f,0f))
        assertEquals(0f,previewQueueVisualOffset(99f,-1f))
    }

    @Test fun thumbnailFallbackRequiresAllThreeConditionsAndLocalResolutionRequiresARealSource() {
        for (mask in 0..7) assertEquals(mask==7,allowPreviewRemoteThumbnailFallback(
            isCurrent=mask and 1!=0,fhdUnavailable=mask and 2!=0,exifFinished=mask and 4!=0))
        data class Source(val path: String)
        assertTrue(isLocalPreviewResolved(Source("original"),Source("original")))
        assertFalse(isLocalPreviewResolved<Source>(null,null))
        assertFalse(isLocalPreviewResolved(Source("original"),Source("changed")))
        assertFalse(isLocalPreviewResolved(Source("original"),null))
    }
}
