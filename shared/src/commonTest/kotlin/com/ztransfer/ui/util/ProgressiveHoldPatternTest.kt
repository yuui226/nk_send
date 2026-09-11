package com.ztransfer.ui.util

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ProgressiveHoldPatternTest {
    @Test fun originalWaveformKeepsDurationAndSilentTail() {
        assertEquals(800, PROGRESSIVE_HOLD_HAPTIC_DURATION_MS)
        assertEquals(800L, PROGRESSIVE_HOLD_TIMINGS_MS.sum())
        assertEquals(PROGRESSIVE_HOLD_TIMINGS_MS.size, PROGRESSIVE_HOLD_AMPLITUDES.size)
        assertEquals(63L, PROGRESSIVE_HOLD_TIMINGS_MS.last())
        assertEquals(0, PROGRESSIVE_HOLD_AMPLITUDES.last())
        assertEquals(18L, PROGRESSIVE_HOLD_CONFIRM_DURATION_MS)
        assertEquals(220, PROGRESSIVE_HOLD_CONFIRM_AMPLITUDE)
    }

    @Test fun iosPulsesUseOriginalAndroidStartsAndIncreasingAmplitudes() {
        val pulses = progressiveHoldPulses()
        assertEquals(listOf(0L, 120L, 230L, 330L, 420L, 500L, 570L, 630L, 680L, 725L), pulses.map { it.atMillis })
        assertEquals(listOf(24, 28, 34, 42, 52, 64, 78, 96, 118, 142).map { it / 255.0 }, pulses.map { it.intensity })
        assertTrue(pulses.zipWithNext().all { (a, b) -> a.intensity < b.intensity })
        assertTrue(pulses.all { it.intensity in 0.0..1.0 && it.atMillis < PROGRESSIVE_HOLD_HAPTIC_DURATION_MS })
    }
}
