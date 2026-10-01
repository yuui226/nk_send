package com.ztransfer.viewmodel

import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.PtpConstants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ExistingFileNameIndexTest {
    @org.junit.Test
    fun concurrentWritersReserveDifferentNamesAndIncompleteFilesAreNotReadable() {
        val index = ExistingFileNameIndex<Int>()
        val pool = java.util.concurrent.Executors.newFixedThreadPool(4)
        val suffix: (String, Int) -> String = { name, n -> "$name ($n)" }
        try {
            val names = (0 until 64).map {
                pool.submit<String> { index.reserveDisplayName("photo.jpg", suffix) }
            }.map { it.get(5, java.util.concurrent.TimeUnit.SECONDS) }
            org.junit.Assert.assertEquals(64, names.toSet().size)
            org.junit.Assert.assertNull(index.find("photo.jpg", 100))
            org.junit.Assert.assertTrue(index.containsDisplayName("PHOTO.JPG"))
            val original = names.first { it == "photo.jpg" }
            index.add(original, 100, 7)
            names.forEach(index::releaseDisplayName)
            org.junit.Assert.assertEquals(7, index.find(original, 100)?.value)
            org.junit.Assert.assertEquals("PHOTO.JPG (1)", index.reserveDisplayName("PHOTO.JPG", suffix))
        } finally { pool.shutdownNow() }
    }

    private fun file(name: String, size: Long) = NikonCamera.FileInfo(
        handle = 1,
        size = size,
        fileName = name,
        captureDate = null,
    )

    @Test
    fun exactNameWinsAndNormalizedCopyLookupDoesNotScanHistory() {
        val index = ExistingFileNameIndex<String>()
        repeat(10_000) { number ->
            index.add("OTHER_$number.JPG", number.toLong(), "other-$number")
        }
        index.add("DSC_0001 (2).JPG", 100L, "copy")
        index.add("DSC_0001.JPG", 100L, "exact")

        assertEquals("exact", index.find("DSC_0001.JPG", 100L)?.value)
        assertEquals("copy", index.find("dsc_0001.jpg", 100L)?.value)
    }

    @Test
    fun normalizedLookupStillRequiresTheCorrectKnownSize() {
        val index = ExistingFileNameIndex<String>()
        index.add("DSC_0001 (2).JPG", 100L, "copy")

        assertNull(index.find("DSC_0001.JPG", 99L))
        assertEquals(
            "copy",
            index.find("DSC_0001.JPG", PtpConstants.SIZE_UNKNOWN)?.value,
        )
    }

    @Test
    fun replacingAnEntryRemovesItsStaleSizeFromTheNormalizedBucket() {
        val index = ExistingFileNameIndex<String>()
        index.add("DSC_0001 (2).JPG", 100L, "old")
        index.add("DSC_0001 (2).JPG", 120L, "new")

        assertNull(index.find("DSC_0001.JPG", 100L))
        assertEquals("new", index.find("DSC_0001.JPG", 120L)?.value)
    }

    @Test
    fun exportedOriginalIndexUpdatesInPlaceAndDeduplicatesSizes() {
        val index = ExportedOriginalIndex()
        val original = file("DSC_0001.JPG", 100L)

        assertTrue(index.add("dsc_0001 (2).jpg", 100L))
        assertFalse(index.add("DSC_0001.JPG", 100L))
        assertTrue(index.contains(original))
        assertFalse(index.contains(original.copy(size = 99L)))
    }

    @Test
    fun exportedOriginalIndexKeepsRootAndDatedFoldersIndependent() {
        val original = file("DSC_0001.JPG", 100L).copy(captureDate = "20260817T120000")
        val rootIndex = ExportedOriginalIndex().apply {
            add(original.fileName, original.size)
        }
        val datedIndex = ExportedOriginalIndex().apply {
            add(original.fileName, original.size, "ZT2026-08-17")
        }

        assertTrue(isTransferredOriginal(original, rootIndex, organizeTransfersByDate = false))
        assertFalse(isTransferredOriginal(original, rootIndex, organizeTransfersByDate = true))
        assertFalse(isTransferredOriginal(original, datedIndex, organizeTransfersByDate = false))
        assertTrue(isTransferredOriginal(original, datedIndex, organizeTransfersByDate = true))
    }

    @Test
    fun datedLookupOnlyMatchesTheCaptureDateDestination() {
        val original = file("DSC_0001.JPG", 100L).copy(captureDate = "20260817T120000")
        val index = ExportedOriginalIndex().apply {
            add(original.fileName, original.size, "ZT2026-08-18")
        }

        assertFalse(isTransferredOriginal(original, index, organizeTransfersByDate = true))
    }
    @Test
    fun differentPrefixesShareOriginalLookupButKeepTypeSizeAndDirectory() {
        val names = ExistingFileNameIndex<String>().apply {
            add("DSC_9049 (2).JPG", 123L, "original")
        }
        assertEquals("original", names.find("Z30_9049.jpg", 123L)?.value)
        assertNull(names.find("Z30_9049.NEF", 123L))
        assertNull(names.find("Z30_9049.JPG", 124L))
        assertNull(names.find("Z30_9050.JPG", 123L))
        assertFalse(names.containsDisplayName("Z30_9049.JPG"))

        val exported = ExportedOriginalIndex().apply {
            add("DSC_9049.JPG", 123L, "ZT2026-09-29")
        }
        val apFile = file("Z30_9049.JPG", 123L)
        assertTrue(exported.contains(apFile, "ZT2026-09-29"))
        assertFalse(exported.contains(apFile))
        assertFalse(exported.contains(apFile.copy(size = 124L), "ZT2026-09-29"))
        assertFalse(exported.contains(apFile.copy(fileName = "Z30_9049.NEF"), "ZT2026-09-29"))
    }

    @Test
    fun videosShareSuffixButCropsAndNamesWithoutNumbersRemainSeparate() {
        val index = ExistingFileNameIndex<String>().apply {
            add("DSC_9053.MP4", 456L, "video")
            add("DSC_9049_crop.JPG", 123L, "crop")
            add("holiday.JPG", 123L, "photo")
        }
        assertEquals("video", index.find("Z30_9053.mp4", 456L)?.value)
        assertNull(index.find("Z30_9053.MOV", 456L))
        assertNull(index.find("Z30_9049.JPG", 123L))
        assertNull(index.find("trip.JPG", 123L))
        assertEquals("photo", index.find("HOLIDAY.jpg", 123L)?.value)
    }
}
