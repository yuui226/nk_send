package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StaJpegThumbnailTest {
    @Test
    fun gridChoosesSmallestIndependentPreviewInsteadOfFhdPriority() {
        val fhd = JpegMpfPreviewReference(100_000, 240_000, 0x010002)
        val vga = JpegMpfPreviewReference(400_000, 40_000, 0x010001)
        assertEquals(vga, selectStaJpegThumbnailPreview(listOf(fhd, vga)))
    }

    @Test
    fun rejectsOriginalUnsupportedTypesAndOversizedPreviews() {
        assertNull(selectStaJpegThumbnailPreview(listOf(
            JpegMpfPreviewReference(0, 4_000, 0x010001),
            JpegMpfPreviewReference(100, 4_000, 0x030000),
            JpegMpfPreviewReference(100, STA_JPEG_THUMBNAIL_MAX_BYTES + 1, 0x010002),
            JpegMpfPreviewReference(100, 3, 0x010001),
        )))
        assertNull(selectStaJpegThumbnailPreview(emptyList()))
    }

    @Test
    fun permitsAnFhdPreviewOnlyWhenItFitsTheSameSmallReadBudget() {
        val smallFhd = JpegMpfPreviewReference(100_000, STA_JPEG_THUMBNAIL_MAX_BYTES, 0x010002)
        assertEquals(smallFhd, selectStaJpegThumbnailPreview(listOf(smallFhd)))
    }
}
