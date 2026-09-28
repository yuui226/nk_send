package com.ztransfer.ui.screen

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ScrollState
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp

/** Fade content rather than painting a dark veil; stays correct on every material theme. */
@Composable
internal fun Modifier.verticalScrollEdgeFade(scroll: ScrollState): Modifier {
    val hasAbove by remember(scroll) { derivedStateOf { scroll.canScrollBackward } }
    val hasBelow by remember(scroll) { derivedStateOf { scroll.canScrollForward } }
    val topAlpha = animateFloatAsState(if (hasAbove) 1f else 0f, tween(150), label = "scrollTopFade")
    val bottomAlpha = animateFloatAsState(if (hasBelow) 1f else 0f, tween(150), label = "scrollBottomFade")
    return graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
        .drawWithCache {
            val depth = minOf(16.dp.toPx(), size.height / 4f)
            val top = Brush.verticalGradient(listOf(Color.Black, Color.Transparent), 0f, depth)
            val bottom = Brush.verticalGradient(listOf(Color.Transparent, Color.Black), size.height - depth, size.height)
            onDrawWithContent {
                drawContent()
                if (depth > 0f) {
                    if (topAlpha.value > 0f) drawRect(top, size = Size(size.width, depth),
                        alpha = topAlpha.value, blendMode = BlendMode.DstOut)
                    if (bottomAlpha.value > 0f) drawRect(bottom,
                        topLeft = Offset(0f, size.height - depth), size = Size(size.width, depth),
                        alpha = bottomAlpha.value, blendMode = BlendMode.DstOut)
                }
            }
        }
}
