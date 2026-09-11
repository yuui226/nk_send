package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraFileInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BurstGroupingTest {
    private fun file(
        number: Int,
        second: Int,
        extension: String = "JPG",
        day: String = "20260724"
    ) = CameraFileInfo(
        handle = number * 10 + extension.hashCode(),
        size = 1_000L,
        fileName = "DSC_${number.toString().padStart(4, '0')}.$extension",
        captureDate = "${day}T1200${second.toString().padStart(2, '0')}"
    )

    @Test
    fun deletingOneOfThreeFramesDissolvesTheCollectionIntoOrdinaryPhotos() {
        val original = (500..502).mapIndexed { index, number -> file(number, index) }
        val remaining = original.dropLast(1)

        assertEquals(3, computeBurstGroups(original).single().files.size)
        val remainingGroups = computeBurstGroups(remaining)
        assertTrue(remainingGroups.isEmpty())

        val remainingBurstIds = remainingGroups.flatMap { group ->
            group.files.map { member -> member.handle to group.id }
        }.toMap()
        val gridItems = buildThumbnailGridItems(
            files = remaining,
            burstIdByHandle = remainingBurstIds,
            collapseBurstPhotos = true,
            expandedBurstIds = emptySet(),
        )
        assertEquals(remaining.map { it.handle }, gridItems.map { item ->
            (item as ThumbnailGridItem.Photo).file.handle
        })
    }

    @Test
    fun expandedCollectionStaysExpandedWhenDeletingItsFirstFrame() {
        val original = (600..603).mapIndexed { index, number -> file(number, index) }
        val previousGroup = computeBurstGroups(original).single()
        val currentGroup = computeBurstGroups(original.drop(1)).single()

        assertEquals(
            setOf(currentGroup.id),
            reconciledExpandedBurstIds(
                previousGroups = listOf(previousGroup),
                currentGroups = listOf(currentGroup),
                expandedIds = setOf(previousGroup.id),
            ),
        )

        val currentBurstIds = currentGroup.files.associate { it.handle to currentGroup.id }
        val gridItems = buildThumbnailGridItems(
            files = currentGroup.files,
            burstIdByHandle = currentBurstIds,
            collapseBurstPhotos = true,
            expandedBurstIds = setOf(currentGroup.id),
        )
        assertEquals(1 + currentGroup.files.size, gridItems.size)
    }

    @Test
    fun bothSuccessorsStayExpandedWhenDeletionSplitsACollection() {
        val original = (700..706).mapIndexed { index, number -> file(number, index) }
        val previousGroup = computeBurstGroups(original).single()
        val currentGroups = computeBurstGroups(original.filterNot {
            it.fileName == "DSC_0703.JPG"
        })

        assertEquals(2, currentGroups.size)
        assertEquals(
            currentGroups.mapTo(HashSet()) { it.id },
            reconciledExpandedBurstIds(
                previousGroups = listOf(previousGroup),
                currentGroups = currentGroups,
                expandedIds = setOf(previousGroup.id),
            ),
        )
    }
}
