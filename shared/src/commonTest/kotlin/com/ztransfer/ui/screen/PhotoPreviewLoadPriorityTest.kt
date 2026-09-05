package com.ztransfer.ui.screen

import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.Test

class PhotoPreviewLoadPriorityTest {
    @Test
    fun missingLocalOriginalNeverSuppressesCurrentCameraFhd() {
        assertFalse(isLocalPreviewResolved<String>(null, null))
        assertFalse(isLocalPreviewResolved(localSource = "content://photo", cachedLocalSource = null))
        assertFalse(
            isLocalPreviewResolved(
                localSource = "content://photo-new",
                cachedLocalSource = "content://photo-old",
            ),
        )
        assertTrue(
            isLocalPreviewResolved(
                localSource = "content://photo",
                cachedLocalSource = "content://photo",
            ),
        )
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
