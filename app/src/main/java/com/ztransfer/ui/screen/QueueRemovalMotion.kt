package com.ztransfer.ui.screen

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.layout.layout
import kotlin.math.roundToInt
import kotlinx.coroutines.delay

internal const val QUEUE_REMOVAL_DURATION_MS = 280
private const val QUEUE_REMOVAL_STAGGER_MS = 20
private const val QUEUE_REMOVAL_MAX_STAGGER_MS = 80
private const val QUEUE_REMOVAL_SETTLE_MS = 40

/** Only the visible targets get animation slots, ordered by their actual screen offsets. */
internal fun queueRemovalDelays(
    visibleItems: List<Pair<Long, Int>>,
    targetIds: Set<Long>,
    stagger: Boolean,
): Map<Long, Int> = buildMap {
    visibleItems.sortedBy { it.second }.forEach { (taskId, _) ->
        if (taskId in targetIds && taskId !in this) {
            put(taskId, if (stagger) (size * QUEUE_REMOVAL_STAGGER_MS)
                .coerceAtMost(QUEUE_REMOVAL_MAX_STAGGER_MS) else 0)
        }
    }
}

internal fun queueRemovalCleanupDelay(delays: Map<Long, Int>): Long =
    if (delays.isEmpty()) 0L else
        (QUEUE_REMOVAL_DURATION_MS + (delays.values.maxOrNull() ?: 0) + QUEUE_REMOVAL_SETTLE_MS).toLong()

internal fun queueRemovalAnimationSpec(delayMillis: Int = 0) =
    tween<Float>(QUEUE_REMOVAL_DURATION_MS, delayMillis = delayMillis, easing = LinearEasing)

/** Use the same frame clock and system duration scale as the rows, including their stagger. */
internal suspend fun awaitQueueRemovalCleanup(delays: Map<Long, Int>) {
    if (delays.isEmpty()) return
    Animatable(0f).animateTo(
        1f,
        tween((queueRemovalCleanupDelay(delays) - QUEUE_REMOVAL_SETTLE_MS).toInt(), easing = LinearEasing),
    )
    // Give row effects time to enter composition even when animation scale is below 1x.
    delay(QUEUE_REMOVAL_SETTLE_MS.toLong())
}

/** Fade and a subtle scale lead the height collapse by about 50ms. */
internal fun queueRemovalOpacity(progress: Float): Float =
    1f - FastOutSlowInEasing.transform(((1f - progress) / .64f).coerceIn(0f, 1f))

internal fun queueRemovalHeight(progress: Float): Float =
    1f - FastOutSlowInEasing.transform(((1f - progress - .18f) / .82f).coerceIn(0f, 1f))

/** Keep normal shadows; during removal, nothing may draw into the next row's layout bounds. */
internal fun Modifier.queueCardRemoval(progress: () -> Float): Modifier =
    drawWithContent {
        if (progress() < 1f) clipRect { this@drawWithContent.drawContent() } else drawContent()
    }.layout { measurable, constraints ->
        val placeable = measurable.measure(constraints)
        val height = queueRemovalHeight(progress())
        layout(placeable.width, (placeable.height * height).roundToInt()) {
            placeable.placeRelativeWithLayer(0, 0) {
                alpha = queueRemovalOpacity(progress())
                scaleX = .97f + .03f * alpha
                scaleY = scaleX
            }
        }
    }
