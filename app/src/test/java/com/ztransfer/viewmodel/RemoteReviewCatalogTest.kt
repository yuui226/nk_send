package com.ztransfer.viewmodel

import com.ztransfer.protocol.NikonCamera
import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class RemoteReviewCatalogTest {
    private fun file(handle: Int, name: String, second: String? = "03") = NikonCamera.FileInfo(
        handle, 100, name, second?.let { "20261015T1200$it" },
    )

    @Test fun rawJpegAndBackupAreOnePhotoButBurstMembersRemainSeparate() {
        val raw = file(1, "DSC_0002.NEF")
        val jpeg = file(2, "DSC_0002.JPG")
        val backup = jpeg.copy(handle = 3)
        val burst = file(4, "DSC_0001.JPG")
        assertEquals(listOf(jpeg, burst), reviewPhotos(listOf(raw, jpeg, backup, burst, file(5, "MOV_0001.MOV"))).map { it.file })
    }

    @Test fun missingDatesStillPairUniqueRawAndJpeg() {
        val raw = file(1, "DSC_0001.NEF", null)
        val jpeg = file(2, "dsc_0001.jpg", null)
        for (files in listOf(listOf(raw, jpeg), listOf(jpeg, raw))) {
            val photo = reviewPhotos(files).single()
            assertEquals(jpeg, photo.file)
            assertEquals(".nef", photo.pairedRawExtension)
        }
    }

    @Test fun differentCapturesAndAmbiguousNamesAreNotMerged() {
        assertEquals(2, reviewPhotos(listOf(file(1, "DSC_0001.NEF", "02"),
            file(2, "DSC_0001.JPG", "03"))).size)
        assertEquals(3, reviewPhotos(listOf(file(1, "DSC_0001.NEF", null),
            file(2, "DSC_0001.NEF", null), file(3, "DSC_0001.JPG", null))).size)
        assertEquals(2, reviewPhotos(listOf(file(1, "DSC_0001.JPG", null),
            file(2, "DSC_0001.JPG", null))).size)
    }

    @Test fun loneFormatsHaveNoPairLabel() {
        val raw = file(1, "DSC_0002.NEF")
        val jpeg = file(2, "DSC_0001.JPG")
        val photos = reviewPhotos(listOf(raw, jpeg))
        assertEquals(listOf(raw, jpeg), photos.map { it.file })
        assertTrue(photos.all { it.pairedRawExtension == null })
    }

    @Test fun timestampPrecisionDoesNotSplitTheSameCapture() {
        val raw = file(1, "DSC_0001.NEF").copy(captureDate = "20261015T120003.120")
        val jpeg = file(2, "DSC_0001.JPG")
        val photo = reviewPhotos(listOf(raw, jpeg)).single()
        assertEquals(jpeg, photo.file)
        assertEquals(".nef", photo.pairedRawExtension)
    }

    @Test fun dateOnlyRawUsesTheMorePreciseJpegDateAndStillMergesItsBackup() {
        val raw = file(1, "DSC_0001.NEF").copy(captureDate = "20261015")
        val jpeg = file(2, "DSC_0001.JPG")
        val photos = reviewPhotos(listOf(raw, jpeg, jpeg.copy(handle = 3),
            file(4, "DSC_0001.NEF", "01")))
        assertEquals(2, photos.size)
        assertEquals(jpeg, photos.first().file)
        assertEquals(jpeg.captureDate, photos.first().captureDate)
        assertEquals(".nef", photos.first().pairedRawExtension)
    }

    @Test fun dualCardPairIsCompleteBeforeFirstPageIsPublished() = runBlocking {
        val files = listOf(file(1, "DSC_0002.NEF"), file(2, "DSC_0001.NEF", "02"),
            file(3, "DSC_0002.JPG"), file(4, "DSC_0001.JPG", "02")).associateBy { it.handle }
        val catalog = RemoteReviewCatalog(listOf(listOf(1, 2), listOf(3, 4))) { files[it] }
        assertEquals(listOf(3), catalog.loadNextPage(1).map { it.file.handle })
        assertTrue(catalog.hasMore)
        assertEquals(listOf(3, 4), catalog.loadNextPage(1).map { it.file.handle })
        assertFalse(catalog.hasMore)
    }

    @Test fun pagingDoesNotScanTheEntireCardAndKeepsItsPublishedPrefix() = runBlocking {
        val files = (1..30).map { file(it, "DSC_$it.JPG", "%02d".format(31-it)) }.associateBy { it.handle }
        val reads = mutableListOf<Int>()
        val catalog = RemoteReviewCatalog(listOf((1..30).toList())) { reads += it; files[it] }
        val first = catalog.loadNextPage(3)
        assertEquals(listOf(1, 2, 3), first.map { it.file.handle })
        assertEquals(4, reads.size) // One lookahead establishes the capture group boundary.
        val next = catalog.loadNextPage(3)
        assertEquals(first, next.take(first.size))
        assertEquals(reads.distinct(), reads)
    }

    @Test fun failedMetadataReadCanBeRetriedWithoutLosingAPhoto() = runBlocking {
        var fail = true
        val catalog = RemoteReviewCatalog(listOf(listOf(1, 2))) {
            if (it == 2 && fail) { fail = false; throw IOException("busy") }
            file(it, "DSC_$it.JPG", if (it == 1) "03" else "02")
        }
        try { catalog.loadNextPage(); fail("expected failure") } catch (_: IOException) { }
        assertEquals(listOf(1, 2), catalog.loadNextPage().map { it.file.handle })
    }

    @Test fun skipsFoldersAndVideosIncludingAVideoOnlyCard() = runBlocking {
        val catalog = RemoteReviewCatalog(listOf(listOf(1, 2, 3))) { handle ->
            if (handle == 1) null else file(handle, "MOV_$handle.MP4")
        }
        assertTrue(catalog.loadNextPage().isEmpty())
        assertFalse(catalog.hasMore)
    }

    @Test fun newFilesCannotAlterTheOpenedHandleSnapshot() = runBlocking {
        val handles = listOf(1, 2)
        val files = mutableMapOf(1 to file(1, "DSC_0002.JPG"), 2 to file(2, "DSC_0001.JPG", "02"))
        val catalog = RemoteReviewCatalog(listOf(handles)) { files[it] }
        val first = catalog.loadNextPage(1)
        files[3] = file(3, "DSC_0003.JPG", "04")
        assertEquals(first, catalog.loadNextPage(1).take(1))
        assertEquals(listOf(1, 2), catalog.loadNextPage().map { it.file.handle })
    }

    @Test fun dualCardPairWithMissingDatesIsCompleteBeforePublishing() = runBlocking {
        for (jpegDate in listOf(null, "03")) {
            val files = listOf(file(1, "DSC_0002.NEF", null), file(2, "DSC_0001.NEF", null),
                file(3, "DSC_0002.JPG", jpegDate), file(4, "DSC_0001.JPG", null)).associateBy { it.handle }
            val catalog = RemoteReviewCatalog(listOf(listOf(1, 2), listOf(3, 4))) { files[it] }
            val first = catalog.loadNextPage(1).single()
            assertEquals(3, first.file.handle)
            assertEquals(".nef", first.pairedRawExtension)
            val all = catalog.loadNextPage(1)
            assertEquals(listOf(3, 4), all.map { it.file.handle })
            assertTrue(all.all { it.pairedRawExtension == ".nef" })
        }
    }

    @Test fun lateCompanionUpdatesThePageWithoutChangingItsPositionOrKey() = runBlocking {
        val raw = file(1, "DSC_0002.NEF", null)
        val other = file(2, "DSC_0001.JPG", null)
        val jpeg = file(3, "DSC_0002.JPG", null)
        val files = listOf(raw, other, jpeg).associateBy { it.handle }
        val catalog = RemoteReviewCatalog(listOf(listOf(1, 2, 3))) { files[it] }
        val first = catalog.loadNextPage(1).single()
        assertEquals(raw, first.file)
        val all = catalog.loadNextPage(3)
        assertEquals(listOf(jpeg, other), all.map { it.file })
        assertEquals(first.key, all.first().key)
        assertEquals(".nef", all.first().pairedRawExtension)
        assertFalse(catalog.hasMore)
    }

}
