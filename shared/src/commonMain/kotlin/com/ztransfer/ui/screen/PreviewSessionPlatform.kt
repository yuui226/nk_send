@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.ImageBitmap
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.viewmodel.PhotoExif

/** IO only. The original shared overlay owns snapshots, page jobs, priority order and eviction. */
@kotlin.native.HiddenFromObjC
interface PreviewSessionSource<Source : Any> : PreviewPageImages {
    @Composable fun connected(): Boolean
    fun setFhdActive(active: Boolean)
    fun localRoute(extension: String): LocalOriginalPreviewRoute
    suspend fun decodeLocal(source: Source, route: LocalOriginalPreviewRoute): ImageBitmap?
    suspend fun loadFhdPreview(file: CameraFileInfo): ImageBitmap?
    suspend fun loadLocalExif(file: CameraFileInfo, source: Source): PhotoExif?
    suspend fun loadExif(file: CameraFileInfo): PhotoExif?
    suspend fun <T> withInteractivePreviewPriority(block: suspend () -> T): T
    fun histogram(bitmap: ImageBitmap): LuminanceHistogram
    fun uptimeMillis(): Long
}

@kotlin.native.HiddenFromObjC
interface PreviewSessionText : PreviewPageText {
    @Composable fun burstLabel(): String
    @Composable fun protectedLabel(): String
    @Composable fun histogramDescription(): String
    @Composable fun rotationDescription(): String
}
