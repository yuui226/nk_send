package com.ztransfer.ui.screen

import androidx.compose.animation.ContentTransform
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith

/** Shared label transition used by the STA connection and local batch action buttons. */
fun buttonStateTextTransition(forward: Boolean): ContentTransform {
    val direction = if (forward) 1 else -1
    return (slideInVertically(
        animationSpec = tween(220, easing = FastOutSlowInEasing),
        initialOffsetY = { it * direction },
    ) + fadeIn(tween(150, delayMillis = 35))).togetherWith(
        slideOutVertically(
            animationSpec = tween(190, easing = FastOutSlowInEasing),
            targetOffsetY = { -it * direction },
        ) + fadeOut(tween(120)),
    )
}
