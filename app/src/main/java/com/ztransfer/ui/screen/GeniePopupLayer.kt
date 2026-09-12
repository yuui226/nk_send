package com.ztransfer.ui.screen

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Paint
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
): Modifier = this
    .drawWithCache {
        val tile = Path()
        val composite = Paint()
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
            layer.compositingStrategy = CompositingStrategy.Offscreen
            layer.blendMode = BlendMode.SrcOver
            layer.alpha = 1f
            // Fade the assembled panel, not each triangle (or individual nested shadows).
            composite.alpha = panelAlpha
            // Settings content is static while the popup is opening or closing. Re-recording
            // the complete tree for every frame was the dominant source of iOS jank.
            if (!layerRecorded()) {
                layer.record { this@onDrawWithContent.drawContent() }
                setLayerRecorded(true)
            }
            if (!validGenieAnchor(origin, bounds)) {
                layer.alpha = p
                drawLayer(layer)
                return@onDrawWithContent
            }
            // Only the settled tail can use one draw safely. At the opening edge a full
            // layer draw would reveal the entire panel before the genie has formed.
            val renderBands = when {
                p > 0.94f -> 1
                p > 0.82f -> 6
                else -> GENIE_RENDER_BANDS
            }
            if (renderBands == 1) {
                layer.blendMode = BlendMode.SrcOver
                layer.alpha = panelAlpha
                drawLayer(layer)
                return@onDrawWithContent
            }
            val source = requireNotNull(origin)
            val mouthWidth = GENIE_Z_MARK_WIDTH_DP.dp.toPx()
            val rows = Array(renderBands + 1) {
                genieRow(p, it.toFloat() / renderBands, source, bounds, mouthWidth)
            }
            // Include the mouth above the panel's layout bounds; never clip it to y=0.
            val outputBounds = Rect(rows.minOf { it.left }, rows.minOf { minOf(it.leftY, it.rightY) },
                rows.maxOf { it.right }, rows.maxOf { maxOf(it.leftY, it.rightY) }).inflate(1f)
            val canvas = drawContext.canvas
            canvas.saveLayer(outputBounds, composite)
            try {
                layer.blendMode = BlendMode.Plus
                for (index in 0 until renderBands) {
                    val sourceTop = size.height * index / renderBands
                    val sourceBottom = size.height * (index + 1) / renderBands
                    val top = rows[index]
                    val bottom = rows[index + 1]
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
                        val matrix = genieBandMatrix(size.width, sourceTop, sourceBottom, top, bottom,
                            upper = triangle == 0)
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
