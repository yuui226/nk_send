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


}
