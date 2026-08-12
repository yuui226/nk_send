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
}
