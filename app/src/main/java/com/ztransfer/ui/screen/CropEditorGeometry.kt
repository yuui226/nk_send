package com.ztransfer.ui.screen

import androidx.compose.runtime.*
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import com.ztransfer.crop.*
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

internal enum class CropRatio(val width: Int, val height: Int, val title: String) {
    FREE(0,0,""), ORIGINAL(0,0,""), SQUARE(1,1,"1:1"), THREE_TWO(3,2,"3:2"),
    FOUR_THREE(4,3,"4:3"), FIVE_FOUR(5,4,"5:4"), SIXTEEN_NINE(16,9,"16:9"), TWO_ONE(2,1,"2:1"),
    TWO_THREE(2,3,"2:3"), THREE_FOUR(3,4,"3:4"), FOUR_FIVE(4,5,"4:5"), NINE_SIXTEEN(9,16,"9:16"), ONE_TWO(1,2,"1:2")
}

@Stable
internal class CropEditorGeometry(val source: JpegCropSource) {
    var size by mutableStateOf(Size.Zero); private set
    var frame by mutableStateOf(Rect.Zero); private set
    var image by mutableStateOf(Rect.Zero); private set
    var ratio by mutableStateOf(CropRatio.ORIGINAL); private set
    var swapped by mutableStateOf(false); private set
    private fun ratioPair(): Pair<Int,Int> {
        if (ratio == CropRatio.FREE) return 0 to 0
        val pair = if (ratio == CropRatio.ORIGINAL) source.displayWidth to source.displayHeight else ratio.width to ratio.height
        return if (swapped) pair.second to pair.first else pair
    }
    fun resize(value: Size) {
        if (value == size || value.width <= 0 || value.height <= 0) return
        val previous = if (image.width > 0) recipe() else null
        size = value
        resetImage()
        if (previous != null) {
            val crop = source.displayBounds(previous.rect)
            frame = fitCenterRect(value.width,value.height,
                ((crop.right - crop.left) * source.displayWidth / ((crop.bottom - crop.top) * source.displayHeight)).toFloat())
            val w = frame.width / (crop.right - crop.left).toFloat()
            val h = frame.height / (crop.bottom - crop.top).toFloat()
            image = Rect(frame.left - crop.left.toFloat() * w,frame.top - crop.top.toFloat() * h,
                frame.left + (1 - crop.left).toFloat() * w,frame.top + (1 - crop.top).toFloat() * h)
        }
        ratioReference=frame
    }
    private var initialImage: Rect? = null
    // Ratio changes share a stable reference; never fit the next ratio inside the last result.
    // Only a manual corner adjustment (or reset/resize) establishes a new reference.
    private var ratioReference: Rect? = null
    fun initialize(viewport: Size, placement: Rect) {
        if(size.width>0) return
        size=viewport; initialImage=placement; image=placement
        frame=placement.intersect(Rect(Offset.Zero,viewport))
        ratioReference=frame
    }
    private fun resetImage() {
        initialImage?.let { image=it;frame=it.intersect(Rect(Offset.Zero,size));return }
        image = fitCenterRect(size.width,size.height,source.displayWidth.toFloat()/source.displayHeight)
        frame = image
    }
    fun reset() { ratio = CropRatio.ORIGINAL; swapped = false; resetImage(); ratioReference=frame }
    fun select(value: CropRatio, flip: Boolean = false) {
        val opposite = if(flip && value.width>0) CropRatio.entries.firstOrNull {
            it.width==value.height && it.height==value.width
        } else null
        ratio = opposite ?: value
        swapped = if(opposite!=null || !flip) false else !swapped
        val (w,h) = ratioPair()
        if (w != 0 && frame.width > 0) {
            val available=image.intersect(Rect(Offset.Zero,size))
            val reference=ratioReference ?: frame.also { ratioReference=it }
            val fitted=fitCenterRect(reference.width,reference.height,w.toFloat()/h)
            val shrink=minOf(1f,available.width/fitted.width,available.height/fitted.height)
            val width=fitted.width*shrink
            val height=fitted.height*shrink
            val left=(reference.center.x-width/2f).coerceIn(available.left,maxOf(available.left,available.right-width))
            val top=(reference.center.y-height/2f).coerceIn(available.top,maxOf(available.top,available.bottom-height))
            frame=Rect(left,top,left+width,top+height)
        }
        // A ratio switch changes the frame only, never the photo placement or zoom.
    }
    fun transform(centroid: Offset, pan: Offset, zoom: Float) {
        if (image.width <= 0 || !zoom.isFinite() || zoom <= 0 ||
            !centroid.x.isFinite() || !centroid.y.isFinite() || !pan.x.isFinite() || !pan.y.isFinite()) return
        val minimum = max(frame.width / image.width,frame.height / image.height)
        val base = fitCenterRect(size.width,size.height,source.displayWidth.toFloat()/source.displayHeight)
        val (rw,rh)=ratioPair()
        val fixed=ratio!=CropRatio.FREE && ratio!=CropRatio.ORIGINAL
        // Do not zoom a tiny frame below one complete integer aspect-ratio unit.
        // This also keeps pixel conversion valid after repeated manual corner edits.
        val minPixelsW=if(fixed) rw.toFloat()+.01f else 1f
        val minPixelsH=if(fixed) rh.toFloat()+.01f else 1f
        val pixelLimit=minOf(frame.width/image.width*source.displayWidth/minPixelsW,
            frame.height/image.height*source.displayHeight/minPixelsH)
        val maximum=minOf(base.width*32/image.width,pixelLimit).coerceAtLeast(minimum)
        val factor = zoom.coerceIn(minimum,maximum)
        val origin = centroid + (image.topLeft - centroid) * factor + pan
        image = Rect(origin, Size(image.width * factor,image.height * factor))
        containImage()
        keepAlignedFrameVisible()
    }
    private fun keepAlignedFrameVisible() {
        val snapped = alignedFrame()
        val dx = when { snapped.left < 0 -> -snapped.left; snapped.right > size.width -> size.width-snapped.right; else -> 0f }
        val dy = when { snapped.top < 0 -> -snapped.top; snapped.bottom > size.height -> size.height-snapped.bottom; else -> 0f }
        if (dx != 0f || dy != 0f) {
            val shift = Offset(dx,dy)
            frame = snapped.translate(shift)
            image = image.translate(shift)
        }
    }
    private fun containImage() {
        if (image.width <= 0) return
        val dx = when { image.left > frame.left -> frame.left - image.left; image.right < frame.right -> frame.right - image.right; else -> 0f }
        val dy = when { image.top > frame.top -> frame.top - image.top; image.bottom < frame.bottom -> frame.bottom - image.bottom; else -> 0f }
        image = image.translate(Offset(dx,dy))
    }
    fun cornerAt(point: Offset, radius: Float): Int? = listOf(frame.topLeft, Offset(frame.right,frame.top),frame.bottomRight,Offset(frame.left,frame.bottom))
        .indexOfFirst { (it - point).getDistance() <= radius }.takeIf { it >= 0 }

    fun dragCorner(corner: Int, pan: Offset, minimum: Float) {
        val leftSide = corner == 0 || corner == 3
        val topSide = corner == 0 || corner == 1
        val anchor = Offset(if (leftSide) frame.right else frame.left,if (topSide) frame.bottom else frame.top)
        val old = Offset(if (leftSide) frame.left else frame.right,if (topSide) frame.top else frame.bottom)
        val proposed = old + pan
        val maxW = if (leftSide) anchor.x else size.width - anchor.x
        val maxH = if (topSide) anchor.y else size.height - anchor.y
        var w = ((proposed.x - anchor.x) * if (leftSide) -1 else 1).coerceIn(min(minimum,maxW),maxW)
        var h = ((proposed.y - anchor.y) * if (topSide) -1 else 1).coerceIn(min(minimum,maxH),maxH)
        val (rw,rh) = ratioPair()
        if (rw > 0) {
            val aspect = rw.toFloat()/rh
            if (abs(pan.x) > abs(pan.y)) h = w/aspect else w = h*aspect
            val shrink = min(1f,min(maxW/w,maxH/h))
            w *= shrink; h *= shrink
        }
        if (w < 1 || h < 1) return
        frame = Rect(if (leftSide) anchor.x-w else anchor.x,if (topSide) anchor.y-h else anchor.y,
            if (leftSide) anchor.x else anchor.x+w,if (topSide) anchor.y else anchor.y+h)
        transform(frame.center,Offset.Zero,1f)
        ratioReference=frame
    }
    // Compare the visible selection to the image, not the selected ratio or gesture history.
    // A tiny relative tolerance ignores floating-point noise when returning to the full image.
    val hasCrop: Boolean
        get() {
            if (image.width <= 0f || image.height <= 0f || frame.width <= 0f || frame.height <= 0f) return false
            val toleranceX = image.width * 0.00001f
            val toleranceY = image.height * 0.00001f
            return frame.left - image.left > toleranceX || image.right - frame.right > toleranceX ||
                frame.top - image.top > toleranceY || image.bottom - frame.bottom > toleranceY
        }

    fun selection(orientation: Int): JpegCropSelection {
        val (w,h) = ratioPair()
        val bounds = CropBounds(((frame.left-image.left)/image.width).toDouble().coerceIn(0.0,1.0),
            ((frame.top-image.top)/image.height).toDouble().coerceIn(0.0,1.0),
            ((frame.right-image.left)/image.width).toDouble().coerceIn(0.0,1.0),
            ((frame.bottom-image.top)/image.height).toDouble().coerceIn(0.0,1.0))
        // Original means the actual downloaded image ratio, not rounded FHD dimensions.
        return JpegCropSelection(bounds,orientation,if (ratio==CropRatio.ORIGINAL) 0 else w,
            if (ratio==CropRatio.ORIGINAL) 0 else h)
    }
    fun recipe(): JpegCropRecipe {
        val (w,h) = ratioPair()
        val bounds = CropBounds(((frame.left-image.left)/image.width).toDouble().coerceIn(0.0,1.0),
            ((frame.top-image.top)/image.height).toDouble().coerceIn(0.0,1.0),
            ((frame.right-image.left)/image.width).toDouble().coerceIn(0.0,1.0),
            ((frame.bottom-image.top)/image.height).toDouble().coerceIn(0.0,1.0))
        return JpegCropRecipe(source, source.align(bounds,w,h))
    }
    fun alignedFrame(): Rect {
        if (image.width <= 0) return frame
        val bounds = source.displayBounds(recipe().rect)
        return Rect(image.left + bounds.left.toFloat()*image.width,image.top + bounds.top.toFloat()*image.height,
            image.left + bounds.right.toFloat()*image.width,image.top + bounds.bottom.toFloat()*image.height)
    }
}
