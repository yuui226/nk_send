package com.ztransfer.ui.util

import androidx.compose.foundation.gestures.PressGestureScope
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.PressInteraction
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalViewConfiguration

/** One source for controls that do not otherwise need access to transfer settings. */
val LocalHapticsEnabled = staticCompositionLocalOf { true }

/** Feedback only: the existing gesture detector still decides when the action is triggered. */
internal class LongPressFeedback(private val haptics: Haptics, private val durationMs: Long) {
    val interactions = MutableInteractionSource()
    private var holding = false

    fun start() {
        holding = true
        haptics.startProgressiveHold(durationMs)
    }

    fun cancel() {
        if (holding) haptics.cancelProgressiveHold()
        holding = false
    }

    fun trigger(action: () -> Unit) {
        holding = false
        haptics.completeLongPress(action)
    }

    suspend fun trackPress(scope: PressGestureScope) {
        start()
        try { scope.tryAwaitRelease() } finally { cancel() }
    }
}

@Composable
internal fun rememberLongPressFeedback(durationMs: Long? = null): LongPressFeedback {
    val haptics = rememberHaptics(LocalHapticsEnabled.current)
    val duration = durationMs ?: LocalViewConfiguration.current.longPressTimeoutMillis
    val feedback = remember(haptics, duration) { LongPressFeedback(haptics, duration) }
    LaunchedEffect(feedback) {
        feedback.interactions.interactions.collect { interaction ->
            when (interaction) {
                is PressInteraction.Press -> feedback.start()
                is PressInteraction.Release, is PressInteraction.Cancel -> feedback.cancel()
            }
        }
    }
    DisposableEffect(feedback) { onDispose { feedback.cancel() } }
    return feedback
}
