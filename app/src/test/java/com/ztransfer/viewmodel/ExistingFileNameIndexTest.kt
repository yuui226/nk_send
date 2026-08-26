package com.ztransfer.viewmodel

import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.PtpConstants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ExistingFileNameIndexTest {
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
    fun exportedOriginalIndexResolvesTheMatchingLocalUriWithoutCrossingDestinations() {
        val original = file("DSC_0001.JPG", 100L)
        val index = ExportedOriginalIndex()

        assertTrue(
            index.add(
                fileName = "DSC_0001 (2).JPG",
                size = 100L,
                destinationFolderName = "ZT2026-08-26",
            )
        )
        assertNull(index.localUriString(original, "ZT2026-08-26"))
        assertTrue(
            index.add(
                fileName = "DSC_0001 (2).JPG",
                size = 100L,
                destinationFolderName = "ZT2026-08-26",
                uriString = "content://exports/DSC_0001_2.JPG",
            )
        )
        assertFalse(
            index.add(
                fileName = "DSC_0001 (2).JPG",
                size = 100L,
                destinationFolderName = "ZT2026-08-26",
                uriString = "content://exports/DSC_0001_2.JPG",
            )
        )

        assertEquals(
            "content://exports/DSC_0001_2.JPG",
            index.localUriString(original, "ZT2026-08-26"),
        )
        assertNull(index.localUriString(original))
        assertNull(index.localUriString(original.copy(size = 99L), "ZT2026-08-26"))
    }

    @Test
    fun datedLookupOnlyMatchesTheCaptureDateDestination() {
        val original = file("DSC_0001.JPG", 100L).copy(captureDate = "20260817T120000")
        val index = ExportedOriginalIndex().apply {
            add(original.fileName, original.size, "ZT2026-08-18")
        }

        assertFalse(isTransferredOriginal(original, index, organizeTransfersByDate = true))
    }
}
