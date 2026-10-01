package com.ztransfer.ui.screen

import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.abs

/** Horizontal intent must pass touch slop and cover a third of the card; no fling shortcut. */
internal fun Modifier.queueCardSwipe(
    enabled: Boolean,
    removing: Boolean,
    removeLabel: String,
    onRemove: () -> Unit,
): Modifier = composed {
    var offset by remember { mutableFloatStateOf(0f) }
    var settling by remember { mutableStateOf<Job?>(null) }
    val scope = rememberCoroutineScope()
    val latestRemove by rememberUpdatedState(onRemove)
    val latestEnabled by rememberUpdatedState(enabled)
    val exitMargin = with(LocalDensity.current) { 48.dp.toPx() }
    var flying by remember { mutableStateOf(false) }
    fun restore() {
        settling?.cancel()
        if (offset == 0f) return
        settling = scope.launch { animate(offset, 0f, animationSpec = tween(180)) { value, _ -> offset = value } }
    }
    LaunchedEffect(enabled, removing) {
        if (!removing) {
            flying = false
            restore()
        }
    }
    this
        .graphicsLayer { translationX = offset }
        .semantics {
            if (enabled) customActions = listOf(CustomAccessibilityAction(removeLabel) {
                latestRemove(); true
            })
        }
        .pointerInput(enabled) {
            if (!enabled) return@pointerInput
            detectHorizontalDragGestures(
                onDragStart = { if (!flying) settling?.cancel() },
                onHorizontalDrag = { change, amount ->
                    change.consume()
                    if (flying) return@detectHorizontalDragGestures
                    offset = (offset + amount).coerceIn(-size.width.toFloat(), size.width.toFloat())
                },
                onDragCancel = { if (!flying) restore() },
                onDragEnd = {
                    if (!flying && abs(offset) >= size.width * 0.33f) {
                        flying = true
                        val target = (size.width + exitMargin) * if (offset < 0f) -1f else 1f
                        settling = scope.launch {
                            animate(offset, target, animationSpec = tween(180)) { value, _ -> offset = value }
                            if (latestEnabled) latestRemove()
                            else { flying = false; restore() }
                        }
                    } else if (!flying) restore()
                },
            )
        }
}
