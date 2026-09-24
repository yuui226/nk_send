package com.ztransfer.ui.screen

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ThumbnailPreviewPriorityTest {
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
