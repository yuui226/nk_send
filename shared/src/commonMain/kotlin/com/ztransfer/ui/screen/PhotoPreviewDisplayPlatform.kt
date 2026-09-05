@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.unit.Dp
import com.ztransfer.protocol.CameraFileInfo

/** These calls stay inside the original remember/effect keys, not a new image scheduler. */
@kotlin.native.HiddenFromObjC
interface PreviewPageImages {
    fun cached(handle: Int): ImageBitmap?
    suspend fun thumbnail(file: CameraFileInfo, allowRemote: Boolean): ImageBitmap?
}

/** Resolve text in the same composable positions as the original resource reads. */
@kotlin.native.HiddenFromObjC
interface PreviewPageText {
    @Composable fun videoMetadata(file: CameraFileInfo): String
    @Composable fun videoUnavailable(): String
    @Composable fun noPreview(): String
    @Composable fun navigationDescription(expand: Boolean): String
    @Composable fun transferDescription(): String
}

/** Existing grid stack/number badge adapters; the ghost always passes loadEnabled=false. */
@kotlin.native.HiddenFromObjC
interface PreviewBurstContent {
    @Composable fun accessibility(count: Int): String
    @Composable fun Photo(file: CameraFileInfo, loadEnabled: Boolean, showPlaceholderIcon: Boolean, modifier: Modifier)
    @Composable fun Badge(count: Int, iconSize: Dp, modifier: Modifier)
}
