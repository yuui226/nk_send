package com.ztransfer.ui.screen

import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.PtpConstants
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
    fun videoMetadataUsesObjectInfoSizeAndCaptureTime() {
        assertEquals(
            "1.5 MB  ·  2026-07-24 12:34:56",
            videoPreviewMetadata(
                fileSize = 1572864L,
                captureDate = "20260724T123456",
                overFourGbLabel = "Over 4 GB",
            ),
        )
    }

    @Test
    fun unknownObjectInfoSizeIsShownAsOverFourGbWithoutAnotherQuery() {
        assertEquals(
            "Over 4 GB  ·  2026-07-24",
            videoPreviewMetadata(
                fileSize = PtpConstants.SIZE_UNKNOWN,
                captureDate = "20260724",
                overFourGbLabel = "Over 4 GB",
            ),
        )
        assertEquals(
            "Over 4 GB",
            videoPreviewMetadata(
                fileSize = 5L * 1024L * 1024L * 1024L,
                captureDate = null,
                overFourGbLabel = "Over 4 GB",
            ),
        )
    }

    @Test
    fun malformedCaptureTimeFallsBackToTheValidDate() {
        assertEquals("2026-07-24", formatPreviewCaptureDate("20260724T996099"))
        assertEquals(null, formatPreviewCaptureDate("20261340T120000"))
    }
}
