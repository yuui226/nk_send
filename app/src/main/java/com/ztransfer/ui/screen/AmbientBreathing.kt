package com.ztransfer.ui.screen

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.rememberUpdatedState

/** Shared ambient-fill motion; callers read its value while drawing, not while laying out text. */
@Composable
internal fun rememberAmbientBreathingAlpha(
    breathing: Boolean,
    restingAlpha: Float,
    minAlpha: Float,
    maxAlpha: Float,
    durationMillis: Int,
    label: String,
): State<Float> = if (breathing) {
    rememberInfiniteTransition(label = label).animateFloat(
        initialValue = minAlpha,
        targetValue = maxAlpha,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "${label}FillAlpha",
    )
} else {
    rememberUpdatedState(restingAlpha)
}
