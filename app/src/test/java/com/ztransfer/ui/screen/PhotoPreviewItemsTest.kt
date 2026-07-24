package com.ztransfer.ui.screen

import com.ztransfer.protocol.NikonCamera
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoPreviewItemsTest {
    private fun file(number: Int) = NikonCamera.FileInfo(
        handle = number,
        size = 1_000L,
        fileName = "DSC_${number.toString().padStart(4, '0')}.JPG",
        captureDate = "20260724T1200${number.toString().takeLast(2)}"
    )

    @Test
    fun expansionInsertsMembersImmediatelyAfterPersistentCollectionPage() {
        val collection = PhotoPreviewItem.BurstCollection(
            id = "burst-a",
            files = listOf(file(2), file(3), file(4))
        )
        val initial = listOf(
            PhotoPreviewItem.Photo(file(1)),
            collection,
            PhotoPreviewItem.Photo(file(5))
        )

        val expanded = expandPreviewBurst(initial, 1, collection)

        assertEquals(6, expanded.size)
        assertSame(collection, expanded[1])
        assertEquals(listOf(2, 3, 4), expanded.subList(2, 5).map {
            (it as PhotoPreviewItem.Photo).file.handle
        })
        assertTrue(isPreviewBurstExpanded(expanded, 1, collection.id))
    }

    @Test
    fun expansionIsIdempotentAndCollapseOnlyRemovesTargetMembers() {
        val first = PhotoPreviewItem.BurstCollection("burst-a", listOf(file(2), file(3), file(4)))
        val second = PhotoPreviewItem.BurstCollection("burst-b", listOf(file(7), file(8), file(9)))
        val base = listOf(
            PhotoPreviewItem.Photo(file(1)),
            first,
            second,
            PhotoPreviewItem.Photo(file(10))
        )
        val firstExpanded = expandPreviewBurst(base, 1, first)
        val secondPage = firstExpanded.indexOf(second)
        val bothExpanded = expandPreviewBurst(firstExpanded, secondPage, second)

        assertSame(firstExpanded, expandPreviewBurst(firstExpanded, 1, first))

        val collapsed = collapsePreviewBurst(bothExpanded, first.id)
        assertTrue(collapsed.none {
            it is PhotoPreviewItem.Photo && it.burstId == first.id
        })
        assertEquals(3, collapsed.count {
            it is PhotoPreviewItem.Photo && it.burstId == second.id
        })
    }
}
