package com.ztransfer.ui.screen

import kotlin.test.*

class SharedPreviewLocalRouteTest {
    @Test fun rawAndTiffKeepDifferentOriginalPaths() {
        for (extension in listOf(".nef", ".nrw")) assertEquals(LocalOriginalPreviewRoute.RAW_EMBEDDED_JPEG, originalLocalPreviewRoute(extension))
        for (extension in listOf(".tif", ".tiff")) assertEquals(LocalOriginalPreviewRoute.CAMERA_FHD, originalLocalPreviewRoute(extension))
    }

    @Test fun routeDoesNotNormalizeOrInventNewRawSupport() {
        for (extension in listOf("", ".jpg", ".jpeg", ".png", ".mov", ".mp4", ".dng", ".NEF", "nef", ".tiff ")) {
            assertEquals(LocalOriginalPreviewRoute.DIRECT_BITMAP, originalLocalPreviewRoute(extension), extension)
        }
    }
}
