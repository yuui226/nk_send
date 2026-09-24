package com.ztransfer.ui.screen

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
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

    fun transform(centroid: Offset, pan: Offset, zoom: Float, aspect: Float) {
        if (!zoom.isFinite() || zoom <= 0f) return
        val nextScale = (scale * zoom).coerceIn(1f, 8f)
        val ratio = nextScale / scale
        val center = Offset(size.width / 2f, size.height / 2f)
        offset = bounded(offset * ratio + (centroid - center) * (1f - ratio) + pan, nextScale, aspect)
        scale = nextScale
    }

    private fun bounded(value: Offset, zoom: Float, aspect: Float): Offset {
        val image = fitCenterRect(size.width, size.height, aspect)
        val maxX = ((image.width * zoom - size.width) / 2f).coerceAtLeast(0f)
        val maxY = ((image.height * zoom - size.height) / 2f).coerceAtLeast(0f)
        return Offset(value.x.coerceIn(-maxX, maxX), value.y.coerceIn(-maxY, maxY))
    }

    /** Visible crop in normalized original-image coordinates, after desqueeze fitting. */
    fun visibleRegion(aspect: Float): Rect {
        val image = fitCenterRect(size.width, size.height, aspect)
        if (image.width <= 0f || image.height <= 0f) return Rect(0f, 0f, 1f, 1f)
        val center = Offset(size.width / 2f, size.height / 2f)
        fun x(value: Float) = (((value - center.x - offset.x) / scale + center.x - image.left) / image.width).coerceIn(0f, 1f)
        fun y(value: Float) = (((value - center.y - offset.y) / scale + center.y - image.top) / image.height).coerceIn(0f, 1f)
        return Rect(x(0f), y(0f), x(size.width), y(size.height))
    }
}

@Composable
internal fun ZoomableViewfinder(
    viewport: ViewfinderViewport,
    imageAspect: Float,
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit,
) {
    LaunchedEffect(imageAspect) { viewport.reset() }
    Box(modifier.clipToBounds()
        .onSizeChanged { viewport.resize(Size(it.width.toFloat(), it.height.toFloat()), imageAspect) }
        .pointerInput(viewport, imageAspect) {
            detectTransformGestures { centroid, pan, zoom, _ ->
                viewport.transform(centroid, pan, zoom, imageAspect)
            }
        }) {
        // Pointer coordinates inside this layer are inverse-transformed by Compose as well,
        // so the existing AF mapping and its reticles share exactly the same coordinate space.
        Box(Modifier.matchParentSize().graphicsLayer {
            scaleX = viewport.scale
            scaleY = viewport.scale
            translationX = viewport.offset.x
            translationY = viewport.offset.y
        }, content = content)
        if (viewport.scale > 1.01f) {
            val crop = viewport.visibleRegion(imageAspect)
            Canvas(Modifier.align(Alignment.TopEnd).padding(top = 42.dp, end = 8.dp)
                .width(64.dp).aspectRatio(imageAspect)) {
                drawRect(Color.Black.copy(alpha = 0.55f))
                drawRect(Color.White.copy(alpha = 0.65f), style = Stroke(1.dp.toPx()))
                drawRect(Color(0xFFFFD45B),
                    topLeft = Offset(crop.left * size.width, crop.top * size.height),
                    size = Size(crop.width * size.width, crop.height * size.height),
                    style = Stroke(1.8.dp.toPx()))
            }
        }
    }
}
