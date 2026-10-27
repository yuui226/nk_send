package com.ztransfer.ui.screen

import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.photoRatingSources
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoRatingRangeTest {
    private val sparseFiles = listOf(
        file(1, "20261102T120000"),
        file(2, "20261029T120000"),
        file(3, "20261001T120000"),
        file(4, "20260921T120000"),
        file(5, "20260808T120000"),
        file(6, "20260101T120000"),
    )

    @Test
    fun `one three five and all use actual shooting days across calendar gaps`() {
        for (days in listOf(1, 3, 5, 0)) {
            val plan = plan(sparseFiles, ratingDays = days)

            assertTrue("Completed catalog must be ready for $days", plan.ready)
            assertEquals(days, plan.effectiveDays)
            assertEquals(
                sparseFiles.take(if (days == 0) sparseFiles.size else days),
                plan.files,
            )
        }
    }

    @Test
    fun `unsorted handles choose newest dates but retain camera order within the selection`() {
        val secondOnLatestDay = file(7, "20261102T080000")
        val files = listOf(sparseFiles[4], sparseFiles[2], secondOnLatestDay,
            sparseFiles[5], sparseFiles[0], sparseFiles[1], sparseFiles[3])

        assertEquals(
            listOf(sparseFiles[2], secondOnLatestDay, sparseFiles[0], sparseFiles[1]),
            plan(files, ratingDays = 3).files,
        )
    }

    @Test
    fun `photo loading range and rating range use the narrower nonzero value`() {
        for ((ratingDays, photoDays, expectedDays) in listOf(
            Triple(0, 3, 3),
            Triple(5, 3, 3),
            Triple(3, 5, 3),
            Triple(3, 0, 3),
            Triple(0, 0, 0),
        )) {
            val plan = plan(sparseFiles, ratingDays, photoDays)

            assertEquals(expectedDays, plan.effectiveDays)
            assertEquals(
                sparseFiles.take(if (expectedDays == 0) sparseFiles.size else expectedDays),
                plan.files,
            )
        }
    }

    @Test
    fun `changed photo loading range waits for application even if the previous catalog was complete`() {
        for ((previousPhotoDays, requestedPhotoDays) in listOf(1 to 5, 5 to 1, 1 to 0)) {
            val plan = plan(
                sparseFiles.take(1), ratingDays = 5,
                photoDays = requestedPhotoDays, appliedPhotoDays = previousPhotoDays,
                complete = true, loading = false, readyDays = 100,
            )

            assertFalse(plan.ready)
            assertTrue("Old catalog must not supply a misleading new-range count", plan.files.isEmpty())
        }
    }

    @Test
    fun `applied wider range still waits for its resumed scan before fixing the request list`() {
        val resuming = plan(
            sparseFiles.take(1), ratingDays = 5, photoDays = 5, appliedPhotoDays = 5,
            complete = false, loading = true, readyDays = 0,
        )
        assertFalse(resuming.ready)

        val completed = plan(
            sparseFiles.take(5), ratingDays = 5, photoDays = 5, appliedPhotoDays = 5,
        )
        assertTrue(completed.ready)
        assertEquals(sparseFiles.take(5), completed.files)
    }

    @Test
    fun `partial first batch waits even when enough distinct dates have appeared`() {
        val plan = plan(
            sparseFiles.take(3), ratingDays = 3,
            complete = false, loading = true, readyDays = 0,
        )

        assertEquals(sparseFiles.take(3), plan.files)
        assertFalse(plan.ready)
    }

    @Test
    fun `empty in progress catalog never locks in an empty rating snapshot`() {
        for (days in listOf(0, 1, 3, 5)) {
            for (loading in listOf(false, true)) {
                val plan = plan(
                    emptyList(), ratingDays = days,
                    complete = false, loading = loading, readyDays = 5,
                )

                assertTrue(plan.files.isEmpty())
                assertFalse("An incomplete empty catalog must wait", plan.ready)
            }
        }
    }

    @Test
    fun `temporarily paused file scan is not a completed catalog`() {
        val plan = plan(
            sparseFiles.take(2), ratingDays = 3,
            complete = false, loading = false, readyDays = 0,
        )

        assertFalse(plan.ready)
    }

    @Test
    fun `finite range can start after its date boundary is confirmed before the full scan ends`() {
        val files = sparseFiles.take(4)

        assertFalse(plan(files, 3, complete = false, loading = true, readyDays = 2).ready)
        val ready = plan(files, 3, complete = false, loading = true, readyDays = 3)
        assertTrue(ready.ready)
        assertEquals(sparseFiles.take(3), ready.files)
    }

    @Test
    fun `readiness count alone cannot make a partial short catalog ready`() {
        val plan = plan(
            sparseFiles.take(2), ratingDays = 3,
            complete = false, loading = true, readyDays = 5,
        )

        assertFalse(plan.ready)
    }

    @Test
    fun `completed catalog with fewer shooting days is ready without thumbnail readiness`() {
        val shortCatalog = plan(sparseFiles.take(2), ratingDays = 5, readyDays = 0)

        assertTrue(shortCatalog.ready)
        assertEquals(sparseFiles.take(2), shortCatalog.files)
        assertTrue(plan(emptyList(), ratingDays = 5).ready)
    }

    @Test
    fun `all dates wait for explicit completion and retain undated supported files`() {
        val undated = file(7, null)
        val malformed = file(8, "bad")
        val files = sparseFiles + undated + malformed

        assertFalse(plan(files, 0, complete = false, loading = true, readyDays = 100).ready)
        assertFalse(plan(files, 0, complete = false, loading = false, readyDays = 100).ready)
        assertFalse(plan(files, 0, complete = true, loading = true, readyDays = 100).ready)
        val completed = plan(files, 0)
        assertTrue(completed.ready)
        assertEquals(files, completed.files)
    }

    @Test
    fun `finite ranges exclude missing and invalid calendar dates`() {
        val valid = file(1, "20260301T120000")
        val files = listOf(valid, file(2, null), file(3, "bad"),
            file(4, "20260229T120000"), file(5, "20261301T120000"),
            file(6, "20261232T120000"), file(7, "00000101T120000"))

        assertEquals(listOf(valid), plan(files, 5).files)
        assertFalse(plan(files.drop(1), 1, complete = false, loading = true, readyDays = 5).ready)
        assertTrue(plan(files.drop(1), 1).files.isEmpty())
    }

    @Test
    fun `supported photo raw and video extensions are case insensitive`() {
        val names = listOf("A.JPG", "B.jpeg", "C.NEF", "D.nRw", "E.MOV", "F.mp4",
            "G.TIFF", "H.PNG", "I.BIN", "no_extension")
        val files = names.mapIndexed { index, name -> file(index, "20261102T120000", name) }

        assertEquals(files.take(6), plan(files, 1).files)
        assertEquals(files.take(6), plan(files, 0).files)
    }

    @Test
    fun `unsupported format dates share the catalog readiness boundary`() {
        val latestTiff = file(1, "20261102T120000", "ONLY.TIFF")
        val nextDayPhoto = file(2, "20261029T120000")
        val files = listOf(latestTiff, nextDayPhoto)

        // The first fully enumerated day contains no rateable files. It must not silently
        // move a one-day request into the next, potentially unfinished, shooting day.
        val latestDay = plan(files, 1, complete = false, loading = true, readyDays = 1)
        assertTrue(latestDay.ready)
        assertTrue(latestDay.files.isEmpty())

        val twoDays = plan(files, 2, complete = false, loading = true, readyDays = 1)
        assertEquals(listOf(nextDayPhoto), twoDays.files)
        assertFalse(twoDays.ready)
        assertTrue(plan(files, 2, complete = false, loading = true, readyDays = 2).ready)
    }

    @Test
    fun `jpeg raw pair uses one camera source while retaining two progress entries`() {
        val raw = file(1, "20261102T120000", "DSC_0001.NEF")
        val jpeg = file(2, "20261102T120000", "DSC_0001.JPG")
        val old = file(3, "20261029T120000", "OLD.JPG")
        val plan = plan(listOf(raw, old, jpeg), ratingDays = 1)
        val sources = photoRatingSources(plan.files)

        assertEquals(listOf(raw, jpeg), plan.files)
        assertEquals(setOf(raw.handle, jpeg.handle), sources.keys)
        assertEquals(listOf(jpeg), sources.values.distinctBy { it.handle })
        assertEquals(2, sources.size)
        assertEquals(2, plan.files.size)
    }

    @Test
    fun `same filename on another card or shooting day does not collapse independent sources`() {
        val raw = file(1, "20261102T120000", "DSC_0001.NEF", card = 1)
        val otherCardJpeg = file(2, "20261102T120000", "DSC_0001.JPG", card = 2)
        val oldJpeg = file(3, "20261029T120000", "DSC_0001.JPG", card = 1)
        val plan = plan(listOf(raw, otherCardJpeg, oldJpeg), ratingDays = 3)
        val sources = photoRatingSources(plan.files)

        assertEquals(raw, sources[raw.handle])
        assertEquals(3, sources.values.distinctBy { it.handle }.size)
        assertEquals(3, plan.files.size)
    }

    private fun plan(
        files: List<NikonCamera.FileInfo>,
        ratingDays: Int = 5,
        photoDays: Int = 0,
        complete: Boolean = true,
        loading: Boolean = false,
        readyDays: Int = 0,
        appliedPhotoDays: Int = photoDays,
    ) = planPhotoRatings(
        files = files,
        ratingDays = ratingDays,
        photoLoadingDays = photoDays,
        appliedPhotoLoadingDays = appliedPhotoDays,
        hasCompletedFileScan = complete,
        isLoadingFiles = loading,
        recentThumbnailReadyDays = readyDays,
    )

    private fun file(
        handle: Int,
        date: String?,
        name: String = "DSC_$handle.JPG",
        card: Int = 1,
    ) = NikonCamera.FileInfo(
        handle = handle,
        size = 100L,
        fileName = name,
        captureDate = date,
        storageIds = setOf(card),
    )
}
