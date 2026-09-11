package com.ztransfer.viewmodel

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.protocol.PtpConstants
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ExistingFileNameIndexTest {
    private fun file(name: String, size: Long) = CameraFileInfo(
        handle = 1,
        size = size,
        fileName = name,
        captureDate = null,
    )

    @Test
    fun sharedNameNormalizationMatchesTheRemovedJvmImplementation() {
        val legacyCopySuffix = Regex(""" \(\d+\)(?=\.[^.]*$|$)""")
        val names = listOf(
            "DSC_0001 (2).JPG",
            "README (3)",
            "archive.tar (2).gz",
            "archive (2).tar.gz",
            "a (1).jpg (2)",
            "DSC (２).JPG",
            "a (1)\n",
            "a (1)\r\n",
            "Iİıẞ (12).JPG",
        )

        names.forEach { name ->
            val legacyBaseName = name.replace(legacyCopySuffix, "")
            assertEquals(legacyBaseName, exportedOriginalBaseName(name))
            assertEquals(
                legacyBaseName.lowercase(Locale.ROOT),
                transferDirectoryLookupKey(name),
            )
        }
    }

    @Test
    fun androidIndexAdapterKeepsTheSharedLookupRules() {
        val index = ExistingFileNameIndex<String>()
        index.add("DSC_0001 (2).JPG", 90L, "stale")
        index.add("DSC_0001 (2).JPG", 100L, "copy")

        assertEquals("copy", index.find("dsc_0001.jpg", 100L)?.value)
        assertEquals("copy", index.find("dsc_0001.jpg", PtpConstants.SIZE_UNKNOWN)?.value)
        assertNull(index.find("dsc_0001.jpg", 90L))
        assertTrue(index.containsDisplayName("DSC_0001 (2).JPG"))
        assertFalse(index.containsDisplayName("dsc_0001 (2).jpg"))
        assertEquals(listOf("copy"), index.entries().map { it.value })
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
