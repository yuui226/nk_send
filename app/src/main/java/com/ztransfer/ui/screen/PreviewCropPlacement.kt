package com.ztransfer.ui.screen

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.ImageBitmap
import com.ztransfer.crop.*

internal class PreviewViewportState {
    val scale=mutableFloatStateOf(1f)
    val offset=mutableStateOf(Offset.Zero)
}

internal data class PreviewImagePlacement(val image: Rect,val viewport: Size,val rotation: Float,
    val baseCenter: Offset = Offset(viewport.width/2f, viewport.height/2f),
    val layoutProgress: Float = 0f) {
    fun content(preview: CropPreview): Rect {
        val c=preview.content
        val bounds=transformCropBounds(CropBounds(c.left.toDouble()/preview.image.width,c.top.toDouble()/preview.image.height,
            c.right.toDouble()/preview.image.width,c.bottom.toDouble()/preview.image.height),preview.displayOrientation)
        return Rect(image.left+bounds.left.toFloat()*image.width,image.top+bounds.top.toFloat()*image.height,
            image.left+bounds.right.toFloat()*image.width,image.top+bounds.bottom.toFloat()*image.height)
    }
}

internal data class CropQueueVisual(val bitmap: ImageBitmap,val source: CropRect,val start: Rect,val rotation: Float)

/** One clipped draw of the shared FHD texture. No bitmap allocation or original-photo decode. */
@androidx.compose.runtime.Composable
internal fun CropQueueFlightGhost(visual: CropQueueVisual, progress: Float, target: Rect?, root: Rect?) {
    androidx.compose.foundation.Canvas(androidx.compose.ui.Modifier.fillMaxSize()) {
        val p=progress.coerceIn(0f,1f)
        if(p<=0f || target==null || root==null) return@Canvas
        val end=Offset(target.right-root.left-28.dp.toPx(),target.center.y-root.top)
        val center=queueFlightBezierPoint(p,visual.start.center,end,36.dp.toPx(),90.dp.toPx(),12.dp.toPx(),52.dp.toPx(),160.dp.toPx())
        val scale=1f+(18.dp.toPx()/maxOf(visual.start.width,visual.start.height)-1f)*p
        val source=visual.source
        val rotation=visual.rotation
        val swapped=Math.floorMod(kotlin.math.round(rotation/90f).toInt(),2)!=0
        val rawWidth=if(swapped) visual.start.height else visual.start.width
        val rawHeight=if(swapped) visual.start.width else visual.start.height
        val alpha=(p/.12f).coerceAtMost(1f)*(if(p>.94f) (1f-p)/.06f else 1f)
        withTransform({
            translate(center.x,center.y)
            rotate(rotation,Offset.Zero)
            scale(scale,scale,Offset.Zero)
            translate(-rawWidth/2f,-rawHeight/2f)
        }) {
            drawImage(visual.bitmap,srcOffset=androidx.compose.ui.unit.IntOffset(source.left,source.top),
                srcSize=androidx.compose.ui.unit.IntSize(source.width,source.height),
                dstSize=androidx.compose.ui.unit.IntSize(rawWidth.toInt().coerceAtLeast(1),rawHeight.toInt().coerceAtLeast(1)),alpha=alpha)
        }
    }
}
