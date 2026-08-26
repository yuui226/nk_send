package com.ztransfer.ui.screen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ThumbnailPreviewPriorityTest {
    @Test
    fun localOriginalPreviewRoutesKeepTiffOnCameraFhd() {
        assertEquals(
            LocalOriginalPreviewRoute.DIRECT_BITMAP,
            localOriginalPreviewRoute(".jpg"),
        )
        assertEquals(
            LocalOriginalPreviewRoute.RAW_EMBEDDED_JPEG,
            localOriginalPreviewRoute(".nef"),
        )
        assertEquals(
            LocalOriginalPreviewRoute.RAW_EMBEDDED_JPEG,
            localOriginalPreviewRoute(".nrw"),
        )
        assertEquals(
            LocalOriginalPreviewRoute.CAMERA_FHD,
            localOriginalPreviewRoute(".tif"),
        )
        assertEquals(
            LocalOriginalPreviewRoute.CAMERA_FHD,
            localOriginalPreviewRoute(".tiff"),
        )
    }

    @Test
    fun gridRemoteThumbnailsPauseWhilePreviewIsOpen() {
        assertTrue(allowGridRemoteThumbnails(previewOpen = false))
        assertFalse(allowGridRemoteThumbnails(previewOpen = true))
    }

    @Test
    fun previewFallbackWaitsForCurrentFhdAndExifToFinish() {
        assertFalse(
            allowPreviewRemoteThumbnailFallback(
                isCurrent = true,
                fhdUnavailable = false,
                exifFinished = true,
            )
        )
        assertFalse(
            allowPreviewRemoteThumbnailFallback(
                isCurrent = true,
                fhdUnavailable = true,
                exifFinished = false,
            )
        )
        assertFalse(
            allowPreviewRemoteThumbnailFallback(
                isCurrent = false,
                fhdUnavailable = true,
                exifFinished = true,
            )
        )
        assertTrue(
            allowPreviewRemoteThumbnailFallback(
                isCurrent = true,
                fhdUnavailable = true,
                exifFinished = true,
            )
        )
    }
}
