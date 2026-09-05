@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

/** Original preview routing. TIFF intentionally stays on the camera-FHD path, unlike NEF/NRW. */
@kotlin.native.HiddenFromObjC
fun originalLocalPreviewRoute(extension: String): LocalOriginalPreviewRoute = when (extension) {
    ".nef", ".nrw" -> LocalOriginalPreviewRoute.RAW_EMBEDDED_JPEG
    ".tif", ".tiff" -> LocalOriginalPreviewRoute.CAMERA_FHD
    else -> LocalOriginalPreviewRoute.DIRECT_BITMAP
}
