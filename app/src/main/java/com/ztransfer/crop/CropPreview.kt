package com.ztransfer.crop

import android.graphics.Bitmap
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap

internal class CropPreparationException(val reason: Reason, val detail: String = "") :
    java.io.IOException("Crop ${reason.name}: $detail") {
    enum class Reason { ORIENTATION, PREVIEW_READ, CONNECTION }
}

/** Borrows the original FHD texture; orientation is a coordinate transform, never a new bitmap. */
internal data class CropPreview(
    val source: JpegCropSource,
    val image: ImageBitmap,
    val originalOrientation: Int = 1,
    val content: CropRect = CropRect(0,0,image.width,image.height),
    val displayOrientation: Int = 1,
    val canonicalOrientation: Int = 1,
) {
    fun canonicalSelection(displayed: JpegCropSelection): JpegCropSelection {
        val raw=transformCropBounds(displayed.bounds,displayOrientation,inverse=true)
        val canonical=transformCropBounds(raw,canonicalOrientation)
        val swap=(displayOrientation>=5)!=(canonicalOrientation>=5)
        return JpegCropSelection(canonical,originalOrientation,
            if(swap) displayed.ratioHeight else displayed.ratioWidth,
            if(swap) displayed.ratioWidth else displayed.ratioHeight)
    }
    fun rawSelection(displayed: JpegCropSelection): CropRect {
        val raw=transformCropBounds(displayed.bounds,displayOrientation,inverse=true)
        val left=(content.left+raw.left*content.width).toInt().coerceIn(content.left,content.right-1)
        val top=(content.top+raw.top*content.height).toInt().coerceIn(content.top,content.bottom-1)
        return CropRect(left,top,(content.left+raw.right*content.width).toInt().coerceIn(left+1,content.right),
            (content.top+raw.bottom*content.height).toInt().coerceIn(top+1,content.bottom))
    }
}

internal fun prepareCropPreview(raw: Bitmap, orientation: Int, embeddedOrientation: Int?, rotation: Float): CropPreview {
    val bounds=cropPreviewBounds(raw.width,raw.height,raw::getPixel)
    val canonical=cropPreviewOrientation(orientation,embeddedOrientation,bounds.width,bounds.height)
    val display=when(Math.floorMod(kotlin.math.round(rotation/90f).toInt(),4)) {1->6;2->3;3->8;else->1}
    val swaps=display>=5
    return CropPreview(JpegCropSource(if(swaps) bounds.height else bounds.width,
        if(swaps) bounds.width else bounds.height,1,1,1),raw.asImageBitmap(),orientation,bounds,display,canonical)
}
