package com.ztransfer.viewmodel

import com.ztransfer.protocol.NikonCamera
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

class PhotoDateRangeTest {
    @Test
    fun `range normalizes endpoints and includes both boundary days`() {
        val range = PhotoDateRange.between(
            LocalDate.of(2026, 8, 6),
            LocalDate.of(2026, 8, 2),
        )

        assertEquals(LocalDate.of(2026, 8, 2), range.start)
        assertEquals(LocalDate.of(2026, 8, 6), range.endInclusive)
        assertTrue(range.containsCaptureDate("20260802T000000"))
        assertTrue(range.containsCaptureDate("20260806T235959"))
        assertFalse(range.containsCaptureDate("20260801T235959"))
        assertFalse(range.containsCaptureDate(null))
        assertFalse(range.containsCaptureDate("20261340T000000"))
        assertFalse(range.containsCaptureDate("20260229T120000"))
        assertTrue(
            PhotoDateRange.between(
                LocalDate.of(2024, 2, 29),
                LocalDate.of(2024, 2, 29),
            ).containsCaptureDate("20240229T120000")
        )
    }

    @Test
    fun `invalid persisted range is ignored`() {
        assertNull(PhotoDateRange.restore("bad", "2026-08-06"))
        assertNull(PhotoDateRange.restore("2026-08-01", null))
    }

    @Test
    fun `priority puts range first then resumes global newest first`() {
        val files = listOf(
            file(1, "20260806T120000"),
            file(2, "20260805T120000"),
            file(3, "20260804T120000"),
            file(4, null),
        )
        val range = PhotoDateRange.between(
            LocalDate.of(2026, 8, 4),
            LocalDate.of(2026, 8, 5),
        )

        assertEquals(
            listOf(2, 3, 1, 4),
            prioritizedThumbnailFiles(files, range).map { it.handle },
        )
        assertEquals(
            listOf(1, 2, 3, 4),
            prioritizedThumbnailFiles(files, null).map { it.handle },
        )
    }

    @Test
    fun `latest capture date ignores malformed values`() {
        assertEquals(
            LocalDate.of(2026, 8, 6),
            latestCaptureLocalDate(
                sequenceOf(null, "bad", "20260229T120000", "20260805T120000", "20260806T010000")
            ),
        )
        assertNull(latestCaptureLocalDate(sequenceOf(null, "bad")))
    }

    @Test
    fun `compact label stays short across years`() {
        assertEquals(
            "26/12/31–27/01/02",
            compactDateRangeLabel(
                PhotoDateRange.between(
                    LocalDate.of(2026, 12, 31),
                    LocalDate.of(2027, 1, 2),
                )
            ),
        )
        assertEquals(
            "26/08/02–26/08/06",
            compactDateRangeLabel(
                PhotoDateRange.between(
                    LocalDate.of(2026, 8, 2),
                    LocalDate.of(2026, 8, 6),
                )
            ),
        )
    }

    private fun file(handle: Int, captureDate: String?) = NikonCamera.FileInfo(
        handle = handle,
        size = 1L,
        fileName = "$handle.JPG",
        captureDate = captureDate,
    )
}
