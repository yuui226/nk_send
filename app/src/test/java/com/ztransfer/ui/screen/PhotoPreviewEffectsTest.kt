package com.ztransfer.ui.screen

import com.ztransfer.protocol.NikonCamera
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoPreviewEffectsTest {
    private fun photo(extension: String) = NikonCamera.FileInfo(
        handle = 1,
        size = 1_000L,
        fileName = "DSC_0001.$extension",
        captureDate = "20261016T120000",
    )

    @Test
    fun onlyJpegPhotosWithTheMasterSwitchOnExposeTheEditor() {
        listOf("JPG", "JPEG", "jpg", "jpeg").forEach { extension ->
            assertTrue(showPreviewPhotoEffects(true, false, photo(extension)))
            assertFalse(showPreviewPhotoEffects(false, false, photo(extension)))
        }
        listOf("NEF", "MOV", "MP4", "PNG").forEach { extension ->
            assertFalse(showPreviewPhotoEffects(true, false, photo(extension)))
        }
    }

    @Test
    fun monitorReviewAndCollectionPagesDoNotExposeTheEditor() {
        assertFalse(showPreviewPhotoEffects(true, true, photo("JPG")))
        assertFalse(showPreviewPhotoEffects(true, false, null))
    }
}
