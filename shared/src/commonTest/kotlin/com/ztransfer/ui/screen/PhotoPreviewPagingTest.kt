package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.protocol.PtpConstants
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.test.Test

class PhotoPreviewPagingTest {
    private fun file(number: Int) = CameraFileInfo(
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

    @Test
    fun everyMemberInSmallAndLargeBurstsReturnsToTheSameCollectionPage() {
        listOf(3, 100).forEach { memberCount ->
            val collection = PhotoPreviewItem.BurstCollection(
                id = "burst-$memberCount",
                files = (1..memberCount).map(::file),
            )
            val collectionPage = 1
            val expanded = expandPreviewBurst(
                items = listOf(PhotoPreviewItem.Photo(file(500)), collection),
                collectionPage = collectionPage,
                collection = collection,
            )
            val memberPages = listOf(
                collectionPage + 1,
                collectionPage + 1 + memberCount / 2,
                collectionPage + memberCount,
            )

            memberPages.forEach { memberPage ->
                assertEquals(
                    collectionPage,
                    previewBurstCollectionPage(expanded, memberPage),
                )
            }
            assertEquals(null, previewBurstCollectionPage(expanded, collectionPage))

            val collapsed = collapsePreviewBurst(expanded, collection.id)
            assertEquals(2, collapsed.size)
            assertSame(collection, collapsed[collectionPage])
        }
    }

    @Test
    fun localOriginalSourcesStayFrozenUntilThePreviewIsReopened() {
        val collection = PhotoPreviewItem.BurstCollection(
            id = "burst-a",
            files = listOf(file(2), file(3)),
        )
        val items = listOf(
            PhotoPreviewItem.Photo(file(1)),
            collection,
            PhotoPreviewItem.Photo(file(4)),
        )
        var transferredHandles = setOf(1)

        val openSession = snapshotPreviewSessionSources(items) { candidate ->
            candidate.handle.takeIf(transferredHandles::contains)?.let { "content://photo/$it" }
        }
        transferredHandles = setOf(1, 2, 3, 4)

        assertEquals("content://photo/1", openSession[1])
        assertTrue(openSession.containsKey(2))
        assertTrue(openSession.containsKey(3))
        assertTrue(openSession.containsKey(4))
        assertNull(openSession[2])
        assertNull(openSession[3])
        assertNull(openSession[4])

        val reopenedSession = snapshotPreviewSessionSources(items) { candidate ->
            candidate.handle.takeIf(transferredHandles::contains)?.let { "content://photo/$it" }
        }
        assertEquals("content://photo/2", reopenedSession[2])
        assertEquals("content://photo/3", reopenedSession[3])
        assertEquals("content://photo/4", reopenedSession[4])
    }
}
