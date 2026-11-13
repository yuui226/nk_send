package com.ztransfer.ui.screen

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.shape.GenericShape
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.dp

/** Display-only transform. It never changes camera zoom or the frame delivered to the recorder. */
@Stable
internal class ViewfinderViewport {
    var scale by mutableFloatStateOf(1f)
        private set
    var offset by mutableStateOf(Offset.Zero)
        private set
    var size by mutableStateOf(Size.Zero)
        private set

    fun reset() { scale = 1f; offset = Offset.Zero }

    fun resize(newSize: Size, aspect: Float) {
        size = newSize
        offset = bounded(offset, scale, aspect)
    }

    fun transform(centroid: Offset, pan: Offset, zoom: Float, aspect: Float, mirrored: Boolean = false) {
        if (!zoom.isFinite() || zoom <= 0f) return
        val nextScale = (scale * zoom).coerceIn(1f, 8f)
        val ratio = nextScale / scale
        val center = Offset(size.width / 2f, size.height / 2f)
        // Keep the stored viewport in camera coordinates. Reflect the screen-space gesture
        // before applying it so pan and pinch stay under the fingers in either display mode.
        val imageCentroid = if (mirrored) Offset(size.width - centroid.x, centroid.y) else centroid
        val imagePan = if (mirrored) Offset(-pan.x, pan.y) else pan
        offset = bounded(offset * ratio + (imageCentroid - center) * (1f - ratio) + imagePan, nextScale, aspect)
        scale = nextScale
    }

    private fun bounded(value: Offset, zoom: Float, aspect: Float): Offset {
        val image = fitCenterRect(size.width, size.height, aspect)
        val maxX = ((image.width * (zoom - 1f)) / 2f).coerceAtLeast(0f)
        val maxY = ((image.height * (zoom - 1f)) / 2f).coerceAtLeast(0f)
        return Offset(value.x.coerceIn(-maxX, maxX), value.y.coerceIn(-maxY, maxY))
    }

    /** Visible crop in normalized original-image coordinates, after desqueeze fitting. */
    fun visibleRegion(aspect: Float): Rect {
        val image = fitCenterRect(size.width, size.height, aspect)
        if (image.width <= 0f || image.height <= 0f) return Rect(0f, 0f, 1f, 1f)
        val center = Offset(size.width / 2f, size.height / 2f)
        fun x(value: Float) = (((value - center.x - offset.x) / scale + center.x - image.left) / image.width).coerceIn(0f, 1f)
        fun y(value: Float) = (((value - center.y - offset.y) / scale + center.y - image.top) / image.height).coerceIn(0f, 1f)
        return Rect(x(image.left), y(image.top), x(image.right), y(image.bottom))
    }
}

@Composable
internal fun ZoomableViewfinder(
    viewport: ViewfinderViewport,
    imageAspect: Float,
    modifier: Modifier = Modifier,
    mirrored: Boolean = false,
    content: @Composable BoxScope.() -> Unit,
) {
    LaunchedEffect(imageAspect) { viewport.reset() }
    val imageWindow = remember(imageAspect) {
        GenericShape { size, _ -> addRect(fitCenterRect(size.width, size.height, imageAspect)) }
    }
    Box(modifier.clipToBounds()
        .onSizeChanged { viewport.resize(Size(it.width.toFloat(), it.height.toFloat()), imageAspect) }
        .pointerInput(viewport, imageAspect, mirrored) {
            detectTransformGestures { centroid, pan, zoom, _ ->
                viewport.transform(centroid, pan, zoom, imageAspect, mirrored)
            }
        }) {
        // Pointer coordinates inside this layer are inverse-transformed by Compose as well,
        // so the existing AF mapping and its reticles share exactly the same coordinate space.
        Box(Modifier.matchParentSize().clip(imageWindow)) {
        Box(Modifier.matchParentSize().graphicsLayer {
            val direction = if (mirrored) -1f else 1f
            scaleX = viewport.scale * direction
            scaleY = viewport.scale
            translationX = viewport.offset.x * direction
            translationY = viewport.offset.y
        }, content = content)
        }
        if (viewport.scale > 1.01f) {
            val originalCrop = viewport.visibleRegion(imageAspect)
            val crop = if (mirrored) Rect(1f - originalCrop.right, originalCrop.top,
                1f - originalCrop.left, originalCrop.bottom) else originalCrop
            Canvas(Modifier.align(Alignment.TopEnd).padding(top = 42.dp, end = 8.dp)
                .width(64.dp).aspectRatio(imageAspect)) {
                drawRect(MonitorOverlayBackground)
                drawRect(Color.White.copy(alpha = 0.65f), style = Stroke(1.dp.toPx()))
                drawRect(Color(0xFFFFD45B),
                    topLeft = Offset(crop.left * size.width, crop.top * size.height),
                    size = Size(crop.width * size.width, crop.height * size.height),
                    style = Stroke(1.8.dp.toPx()))
            }
        }
    }
}
