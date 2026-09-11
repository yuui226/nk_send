@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.screen.PreviewSessionSource

/** Native-only lifetime boundary around the original shared overlay's platform source. */
@kotlin.native.HiddenFromObjC
internal interface NativePreviewPageSource : PreviewSessionSource<String> {
    fun localSource(file: CameraFileInfo): String?
    fun close()
}
