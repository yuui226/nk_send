package com.ztransfer.ui.util

import androidx.compose.runtime.Composable

/** UI-thread semantic feedback; platform adapters own device-specific vibration APIs. */
interface Haptics {
    fun tick()
    fun longPress()
    fun success()
    fun failure()
    fun startProgressiveHold()
    fun cancelProgressiveHold()
    fun completeProgressiveHold()
}

@Composable
expect fun rememberHaptics(enabled: Boolean): Haptics

internal data class ProgressiveHoldPulse(val atMillis: Long, val intensity: Double)

/** Interpret the same original Android waveform for platforms exposing discrete impacts. */
internal fun progressiveHoldPulses(): List<ProgressiveHoldPulse> = buildList {
    var elapsed = 0L
    PROGRESSIVE_HOLD_TIMINGS_MS.forEachIndexed { index, duration ->
        val amplitude = PROGRESSIVE_HOLD_AMPLITUDES[index]
        if (amplitude > 0) add(ProgressiveHoldPulse(elapsed, amplitude / 255.0))
        elapsed += duration
    }
}
