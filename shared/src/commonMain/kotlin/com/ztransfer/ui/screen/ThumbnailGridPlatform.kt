@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.ImageBitmap
import com.ztransfer.protocol.CameraFileInfo

/** Only the image I/O boundary. Each method is invoked inside the original keyed cell. */
@kotlin.native.HiddenFromObjC
interface ThumbnailGridImageSource {
    @Composable fun photo(file: CameraFileInfo, transfersBusy: Boolean, allowRemoteThumbnail: Boolean): ImageBitmap?
    @Composable fun stack(file: CameraFileInfo, transfersBusy: Boolean, loadEnabled: Boolean, allowRemoteThumbnail: Boolean): ImageBitmap?
}

/** Read text where the original composable read it, including animated old/new counts. */
@kotlin.native.HiddenFromObjC
interface ThumbnailGridText {
    @Composable fun date(value: String): String
    @Composable fun expand(collapsed: Boolean): String
    @Composable fun transferGroup(): String
    @Composable fun burstAccessibility(count: Int): String
    @Composable fun burstCount(count: Int): String
    @Composable fun protectedPhoto(): String
    @Composable fun loading(): String
}
