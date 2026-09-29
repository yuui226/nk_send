package com.ztransfer.ui.screen

import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/** Measure the controls first: a wide portrait window must never let the image consume them. */
@Composable
internal fun PortraitMonitorLayout(
    aspectRatio: Float,
    modifier: Modifier = Modifier,
    header: @Composable () -> Unit,
    viewfinder: @Composable () -> Unit,
    tools: @Composable () -> Unit,
    parameters: @Composable () -> Unit,
    shutter: @Composable () -> Unit,
) {
    Layout(
        modifier = modifier,
        content = {
            Box { header() }
            Box { viewfinder() }
            Box { tools() }
            Box { parameters() }
            Box { shutter() }
        },
    ) { children, constraints ->
        val width = constraints.maxWidth
        val height = constraints.maxHeight
        val controlConstraints = Constraints(minWidth = width, maxWidth = width)
        val headerPlaceable = children[0].measure(controlConstraints)
        val toolsPlaceable = children[2].measure(controlConstraints)
        val parametersPlaceable = children[3].measure(controlConstraints)
        val shutterPlaceable = children[4].measure(controlConstraints)
        val headerGap = 12.dp.roundToPx()
        val toolGap = 8.dp.roundToPx()
        val parameterGap = 12.dp.roundToPx()
        val controlsHeight = headerPlaceable.height + toolsPlaceable.height +
            parametersPlaceable.height + shutterPlaceable.height + headerGap + toolGap + parameterGap
        val imageSize = portraitMonitorImageSize(width, (height - controlsHeight).coerceAtLeast(0), aspectRatio)
        val image = children[1].measure(Constraints.fixed(imageSize.first, imageSize.second))
        val spare = (height - controlsHeight - image.height).coerceAtLeast(0)
        layout(width, height) {
            var y = 0
            headerPlaceable.placeRelative(0, y)
            y += headerPlaceable.height + headerGap
            image.placeRelative((width - image.width) / 2, y)
            y += image.height + toolGap
            toolsPlaceable.placeRelative(0, y)
            y += toolsPlaceable.height + parameterGap
            parametersPlaceable.placeRelative(0, y)
            y += parametersPlaceable.height + spare / 2
            shutterPlaceable.placeRelative(0, y)
        }
    }
}

/** Pixel bounds only; retain the camera/desqueeze aspect, including near-square foldable windows. */
internal fun portraitMonitorImageSize(width: Int, availableHeight: Int, aspectRatio: Float): Pair<Int, Int> {
    val aspect = aspectRatio.takeIf { it.isFinite() && it > 0f } ?: (3f / 2f)
    val w = width.coerceAtLeast(0)
    val h = availableHeight.coerceAtLeast(0)
    val imageHeight = minOf(h, (w / aspect).roundToInt().coerceAtLeast(0))
    return minOf(w, (imageHeight * aspect).roundToInt().coerceAtLeast(0)) to imageHeight
}
