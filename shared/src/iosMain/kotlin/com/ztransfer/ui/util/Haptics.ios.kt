package com.ztransfer.ui.util

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import platform.Foundation.NSThread
import platform.UIKit.UIApplication
import platform.UIKit.UIApplicationState
import platform.UIKit.UIImpactFeedbackGenerator
import platform.UIKit.UIImpactFeedbackStyle
import platform.UIKit.UINotificationFeedbackGenerator
import platform.UIKit.UINotificationFeedbackType
import platform.UIKit.UISelectionFeedbackGenerator
import kotlin.time.TimeSource

@OptIn(ExperimentalForeignApi::class)
private class IosHaptics(private val enabled: Boolean, private val scope: CoroutineScope) : Haptics {
    // Lazy: disabling feedback does not instantiate UIKit generators or start timers.
    private val selection by lazy { UISelectionFeedbackGenerator() }
    private val impact by lazy { UIImpactFeedbackGenerator(UIImpactFeedbackStyle.UIImpactFeedbackStyleMedium) }
    private val heavy by lazy { UIImpactFeedbackGenerator(UIImpactFeedbackStyle.UIImpactFeedbackStyleHeavy) }
    private val notification by lazy { UINotificationFeedbackGenerator() }
    private var hold: Job? = null
    private var disposed = false

    private fun canPlay(): Boolean = enabled && !disposed && scope.isActive && NSThread.isMainThread &&
        UIApplication.sharedApplication.applicationState == UIApplicationState.UIApplicationStateActive

    override fun tick() {
        if (canPlay()) selection.selectionChanged()
    }

    override fun longPress() {
        if (canPlay()) impact.impactOccurred()
    }

    override fun success() {
        if (canPlay()) notification.notificationOccurred(UINotificationFeedbackType.UINotificationFeedbackTypeSuccess)
    }

    override fun failure() {
        if (canPlay()) notification.notificationOccurred(UINotificationFeedbackType.UINotificationFeedbackTypeError)
    }

    override fun startProgressiveHold() {
        cancelProgressiveHold()
        if (!canPlay()) return
        impact.prepare()
        val start = TimeSource.Monotonic.markNow()
        hold = scope.launch {
            for (pulse in progressiveHoldPulses()) {
                delay((pulse.atMillis - start.elapsedNow().inWholeMilliseconds).coerceAtLeast(0))
                // A delayed UI thread/background resume must not replay a burst of stale pulses.
                if (!canPlay() || start.elapsedNow().inWholeMilliseconds - pulse.atMillis > 50) return@launch
                impact.impactOccurredWithIntensity(pulse.intensity)
            }
            // Completion is deliberately not emitted here; only the caller confirms a full hold.
        }
    }

    override fun cancelProgressiveHold() {
        hold?.cancel()
        hold = null
    }

    override fun completeProgressiveHold() {
        cancelProgressiveHold()
        if (canPlay()) heavy.impactOccurred()
    }

    fun dispose() {
        disposed = true
        cancelProgressiveHold()
    }
}

@Composable
actual fun rememberHaptics(enabled: Boolean): Haptics {
    val scope = rememberCoroutineScope()
    val haptics = remember(enabled, scope) { IosHaptics(enabled, scope) }
    DisposableEffect(haptics) { onDispose { haptics.dispose() } }
    return haptics
}
