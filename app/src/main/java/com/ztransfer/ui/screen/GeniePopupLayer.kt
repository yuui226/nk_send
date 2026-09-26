package com.ztransfer.ui.screen

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.Matrix
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.layer.CompositingStrategy
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp

/**
 * Records the entire panel (including text, shadows and border) into one GPU layer.
 * No bitmap readback, screenshot files, per-frame composition or Android-version-specific shaders.
 * Tiles accumulate coverage on a transparent canvas before ONE source-over composite.
 * Drawing antialiased tiles directly over the backdrop creates visible seams even when all
 * vertices match: two half-covered pixels source-over to 75%, not 100% coverage.
 * The settled panel is drawn normally; tiling exists only during the short transition.
 */
internal fun Modifier.geniePopupLayer(
    layer: GraphicsLayer,
    progress: () -> Float,
    anchor: () -> Rect?,
    panel: () -> Rect?,
    layerRecorded: () -> Boolean,
    setLayerRecorded: (Boolean) -> Unit,
    allowAboveAnchor: Boolean = false,
): Modifier = this
    .drawWithCache {
        val tile = Path()
        val composite = Paint()
        val matrix = Matrix()
        val rows = arrayOfNulls<GenieRow>(GENIE_RENDER_BANDS + 1)
        // A new cache can mean a resized panel/different density: never reuse its old recording.
        setLayerRecorded(false)
        onDrawWithContent {
            val p = genieProgress(progress())
            if (p == 1f) {
                // The next close transition must capture any settings changes made while open.
                setLayerRecorded(false)
                drawContent()
                return@onDrawWithContent
            }
            val panelAlpha = geniePanelAlpha(p)
            if (panelAlpha <= 0f || size.width <= 0f || size.height <= 0f) return@onDrawWithContent
            val bounds = panel() ?: Rect(0f, 0f, size.width, size.height)
            val origin = anchor()
            val above = allowAboveAnchor && origin != null && bounds.bottom <= origin.top
            fun mirrorY(rect: Rect) = Rect(rect.left,-rect.bottom,rect.right,-rect.top)
            val geometryBounds=if(above) mirrorY(bounds) else bounds
            val geometryOrigin=if(above) origin?.let(::mirrorY) else origin
            layer.compositingStrategy = CompositingStrategy.Offscreen
            layer.alpha = 1f
            // Fade the assembled panel, not each triangle (or individual nested shadows).
            composite.alpha = panelAlpha
            // Settings content is static while the popup is opening or closing. Re-recording
            // the complete tree for every frame was the dominant source of iOS jank.
            if (!layerRecorded()) {
                layer.record { this@onDrawWithContent.drawContent() }
                setLayerRecorded(true)
            }
            if (!validGenieAnchor(geometryOrigin, geometryBounds)) {
                layer.alpha = p
                layer.blendMode = BlendMode.SrcOver
                drawLayer(layer)
                return@onDrawWithContent
            }
            // Keep the final stretch on the same mesh path. Switching from six bands to a
            // full-layer draw at p=0.94 creates a visible snap and a short GPU spike on Android.
            // Six bands are sufficient once the funnel is nearly open; p==1 above still settles
            // to the normal live draw.
            val renderBands = if (p > 0.82f) 6 else GENIE_RENDER_BANDS
            val source = requireNotNull(geometryOrigin)
            val mouthWidth = GENIE_Z_MARK_WIDTH_DP.dp.toPx()
            var minX=Float.POSITIVE_INFINITY
            var minY=Float.POSITIVE_INFINITY
            var maxX=Float.NEGATIVE_INFINITY
            var maxY=Float.NEGATIVE_INFINITY
            for(index in 0..renderBands) {
                val fraction=index.toFloat()/renderBands
                // Reflect coordinates once per frame, not separately for every band.
                val base=genieRow(p,if(above) 1f-fraction else fraction,source,geometryBounds,mouthWidth)
                val row=if(above) GenieRow(base.left,base.right,size.height-base.y,-base.tilt) else base
                rows[index]=row
                minX=minOf(minX,row.left)
                maxX=maxOf(maxX,row.right)
                minY=minOf(minY,row.leftY,row.rightY)
                maxY=maxOf(maxY,row.leftY,row.rightY)
            }
            // Include the inlet outside the panel bounds without allocating a full-screen layer.
            val outputBounds=Rect(minX-1f,minY-1f,maxX+1f,maxY+1f)
            val canvas = drawContext.canvas
            canvas.saveLayer(outputBounds, composite)
            try {
                layer.blendMode = BlendMode.Plus
                for (index in 0 until renderBands) {
                    val sourceTop = size.height * index / renderBands
                    val sourceBottom = size.height * (index + 1) / renderBands
                    val top = requireNotNull(rows[index])
                    val bottom = requireNotNull(rows[index + 1])
                    for (triangle in 0..1) {
                        tile.rewind()
                        if (triangle == 0) {
                            tile.moveTo(top.left, top.leftY)
                            tile.lineTo(top.right, top.rightY)
                            tile.lineTo(bottom.left, bottom.leftY)
                        } else {
                            tile.moveTo(top.right, top.rightY)
                            tile.lineTo(bottom.right, bottom.rightY)
                            tile.lineTo(bottom.left, bottom.leftY)
                        }
                        tile.close()
                        genieBandMatrix(size.width, sourceTop, sourceBottom, top, bottom,
                            upper = triangle == 0, destination = matrix)
                        withTransform({
                            // Clip in destination space using exactly the same shared endpoints.
                            // Do not round or expand tiles: overlap would brighten glass with Plus.
                            clipPath(tile)
                            transform(matrix)
                        }) { drawLayer(layer) }
                    }
                }
            } finally {
                canvas.restore()
            }
        }
    }
    .pointerInput(Unit) {
        // Visual geometry differs from layout while bent: do not activate an invisible switch.
        // Outside-panel taps and system back still reach the popup's original dismissal handlers.
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
            if (genieProgress(progress()) < 1f) {
                down.consume()
                do {
                    val event = awaitPointerEvent(PointerEventPass.Initial)
                    event.changes.forEach { it.consume() }
                } while (event.changes.any { it.pressed })
            }
        }
    }
