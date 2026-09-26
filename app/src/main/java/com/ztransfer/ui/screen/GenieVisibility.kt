package com.ztransfer.ui.screen

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned

/** Keeps outgoing content mounted until the shared genie animation has actually finished. */
internal class GenieVisibilityState(val progress: Animatable<Float, androidx.compose.animation.core.AnimationVector1D>, val mounted: State<Boolean>)

@Composable
internal fun rememberGenieVisibility(expanded: Boolean): GenieVisibilityState {
    val progress=remember { Animatable(0f) }
    val target=rememberUpdatedState(expanded)
    val mounted=remember { derivedStateOf { target.value || progress.value>0f } }
    LaunchedEffect(expanded) {
        if(expanded) withFrameNanos { }
        val duration=if(expanded) GENIE_EXPAND_DURATION_MS else GENIE_COLLAPSE_DURATION_MS
        val distance=if(expanded) 1f-progress.value else progress.value
        progress.animateTo(if(expanded) 1f else 0f,
            tween((duration*distance).toInt().coerceAtLeast(1),easing=if(expanded) GenieExpandEasing else GenieCollapseEasing))
    }
    return remember { GenieVisibilityState(progress,mounted) }
}

private class GenieInlineGeometry {
    var bounds: Rect? = null
    var recorded=false
}

@Composable
internal fun GenieInlinePanel(state: GenieVisibilityState, anchor: () -> Rect?,
    modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    if(!state.mounted.value) return
    val geometry=remember { GenieInlineGeometry() }
    val layer=rememberGraphicsLayer()
    Box(modifier.onGloballyPositioned {
        val bounds=it.boundsInRoot()
        if(geometry.bounds?.size!=bounds.size) geometry.recorded=false
        geometry.bounds=bounds
    }.geniePopupLayer(layer,{state.progress.value},anchor,{geometry.bounds},
        {geometry.recorded},{geometry.recorded=it},allowAboveAnchor=true)) { content() }
}
