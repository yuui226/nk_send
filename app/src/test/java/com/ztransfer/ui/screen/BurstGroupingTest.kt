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
}
