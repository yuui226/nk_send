package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.protocol.PtpConstants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoPreviewItemsTest {
    private fun file(number: Int) = CameraFileInfo(
        handle = number,
        size = 1_000L,
        fileName = "DSC_${number.toString().padStart(4, '0')}.JPG",
        captureDate = "20260724T1200${number.toString().takeLast(2)}"
    )

    @Test
    fun videoMetadataUsesObjectInfoSizeAndCaptureTime() {
        assertEquals(
            "1.5 MB  ·  2026-07-24 12:34:56",
            videoPreviewMetadata(
                fileSize = 1572864L,
                captureDate = "20260724T123456",
                overFourGbLabel = "Over 4 GB",
            ),
        )
    }

    @Test
    fun unknownObjectInfoSizeIsShownAsOverFourGbWithoutAnotherQuery() {
        assertEquals(
            "Over 4 GB  ·  2026-07-24",
            videoPreviewMetadata(
                fileSize = PtpConstants.SIZE_UNKNOWN,
                captureDate = "20260724",
                overFourGbLabel = "Over 4 GB",
            ),
        )
        assertEquals(
            "Over 4 GB",
            videoPreviewMetadata(
                fileSize = 5L * 1024L * 1024L * 1024L,
                captureDate = null,
                overFourGbLabel = "Over 4 GB",
            ),
        )
    }

    @Test
    fun malformedCaptureTimeFallsBackToTheValidDate() {
        assertEquals("2026-07-24", formatPreviewCaptureDate("20260724T996099"))
        assertEquals(null, formatPreviewCaptureDate("20261340T120000"))
    }
}
