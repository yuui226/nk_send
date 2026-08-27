package com.ztransfer.ui.screen

import com.ztransfer.protocol.NikonCamera
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BurstGroupingTest {
    private fun file(
        number: Int,
        second: Int,
        extension: String = "JPG",
        day: String = "20260724"
    ) = NikonCamera.FileInfo(
        handle = number * 10 + extension.hashCode(),
        size = 1_000L,
        fileName = "DSC_${number.toString().padStart(4, '0')}.$extension",
        captureDate = "${day}T1200${second.toString().padStart(2, '0')}"
    )

    @Test
    fun detectsOnlyRunsWithAtLeastThreeConsecutiveFrames() {
        val files = listOf(
            file(100, 0),
            file(101, 1),
            file(102, 2),
            file(110, 3),
            file(111, 4)
        )

        val groups = computeBurstGroups(files)

        assertEquals(1, groups.size)
        assertEquals(listOf(100, 101, 102), groups.single().files.map {
            it.fileName.substringAfter("DSC_").substringBefore('.').toInt()
        })
    }

    @Test
    fun separatesRawAndJpegTracks() {
        val files = buildList {
            (200..202).forEachIndexed { index, number ->
                add(file(number, index, "JPG"))
                add(file(number, index, "NEF"))
            }
        }

        val groups = computeBurstGroups(files)

        assertEquals(2, groups.size)
        assertEquals(setOf(".jpg", ".nef"), groups.map { it.files.first().extension }.toSet())
        assertTrue(groups.all { it.files.size == 3 })
    }

    @Test
    fun keepsCollectionIdWhenNewerFrameExtendsRun() {
        val initial = (300..302).mapIndexed { index, number -> file(number, index) }
        val extended = initial + file(303, 3)

        val initialGroup = computeBurstGroups(initial).single()
        val extendedGroup = computeBurstGroups(extended).single()

        assertEquals(initialGroup.id, extendedGroup.id)
        assertEquals(4, extendedGroup.files.size)
    }

    @Test
    fun rejectsNumberSequenceWhenCaptureTimeMovesBackwards() {
        val files = listOf(
            file(400, 5),
            file(401, 4),
            file(402, 5)
        )

        assertTrue(computeBurstGroups(files).isEmpty())
    }

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
