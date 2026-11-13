package com.ztransfer.viewmodel

import com.ztransfer.protocol.NikonCamera
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoLoadingRangeTest {
    @Test
    fun oldVisibleDaysDoNotStopTheFirstOrLaterBatchOfNewPhotos() {
        val oldFiles = listOf(file(1, "20261103"), file(2, "20261102"), file(3, "20261101"))
        val firstBatch = listOf(file(4, "20261108"))
        val laterBatch = (5..24).map { file(it, "20261108") }
        val range = newestCaptureDaysRange(oldFiles + firstBatch, 3)

        assertEquals(LocalDate.of(2026, 11, 2), range?.start)
        assertEquals(LocalDate.of(2026, 11, 8), range?.endInclusive)
        assertFalse(crossedPhotoLoadingRange(range, firstBatch))
        assertFalse(crossedPhotoLoadingRange(range, laterBatch))
        assertFalse(crossedPhotoLoadingRange(range, listOf(file(25, "20261102"))))
        assertTrue(crossedPhotoLoadingRange(range, listOf(file(26, "20261101"))))
    }

    @Test
    fun gapsAndMultiplePhotosStillCountAsActualShootingDays() {
        val newest = listOf(file(1, "20261108"), file(2, "20261108"), file(3, "20261104"))
        val thirdDay = listOf(file(4, "20261029"), file(5, "20261029"))
        val olderDay = listOf(file(6, "20261020"))
        val range = newestCaptureDaysRange(newest + thirdDay + olderDay, 3)

        assertEquals(LocalDate.of(2026, 10, 29), range?.start)
        assertEquals(LocalDate.of(2026, 11, 8), range?.endInclusive)
        assertFalse(crossedPhotoLoadingRange(range, thirdDay))
        assertTrue(crossedPhotoLoadingRange(range, thirdDay + olderDay))
    }

    @Test
    fun eachLimitedRangeNeedsAnObservedOlderDay() {
        val days = (15 downTo 1).map { file(it, "202611${it.toString().padStart(2, '0')}") }
        for (limit in listOf(1, 3, 5, 10)) {
            val range = newestCaptureDaysRange(days, limit)
            assertEquals(LocalDate.of(2026, 11, 16 - limit), range?.start)
            assertFalse(crossedPhotoLoadingRange(range, days.take(limit)))
            assertTrue(crossedPhotoLoadingRange(range, listOf(days[limit])))
        }
    }

    @Test
    fun wideningTheRangeCanResumeItsOlderTail() {
        val loaded = listOf(file(1, "20261108"), file(2, "20261106"), file(3, "20261104"))
        val tail = listOf(file(4, "20261102"), file(5, "20261030"))
        val range = newestCaptureDaysRange(loaded + tail, 5)

        assertFalse(crossedPhotoLoadingRange(range, tail))
        assertTrue(crossedPhotoLoadingRange(range, listOf(file(6, "20261028"))))
    }

    @Test
    fun allDaysAndUnknownDatesCannotEndAScanEarly() {
        val files = listOf(file(1, "20261108"), file(2, "20261001"))
        assertNull(newestCaptureDaysRange(files, 0))
        assertFalse(crossedPhotoLoadingRange(null, files))
        val range = newestCaptureDaysRange(files, 1)
        val unknown = listOf(file(3, null), file(4, "bad"), file(5, "20260230"))
        assertFalse(crossedPhotoLoadingRange(range, unknown))
        assertEquals(range, newestCaptureDaysRange(files + unknown, 1))
        assertFalse(crossedPhotoLoadingRange(range, emptyList()))
    }

    private fun file(handle: Int, day: String?) = NikonCamera.FileInfo(
        handle = handle,
        size = 1L,
        fileName = "DSC_$handle.JPG",
        captureDate = day?.let { "${it}T120000" },
    )
}
