package com.ztransfer.ui.util

const val PROGRESSIVE_HOLD_HAPTIC_DURATION_MS = 800
internal const val PROGRESSIVE_HOLD_CONFIRM_DURATION_MS = 18L
internal const val PROGRESSIVE_HOLD_CONFIRM_AMPLITUDE = 220

// Ten very short impulses accelerate from 120 ms to 45 ms apart and gradually gain strength.
// The last 63 ms stay silent so the independent completion click has a clean leading edge.
internal val PROGRESSIVE_HOLD_TIMINGS_MS = longArrayOf(
    0L,
    8L, 112L,
    8L, 102L,
    9L, 91L,
    9L, 81L,
    10L, 70L,
    10L, 60L,
    11L, 49L,
    11L, 39L,
    12L, 33L,
    12L, 63L,
)
internal val PROGRESSIVE_HOLD_AMPLITUDES = intArrayOf(
    0,
    24, 0,
    28, 0,
    34, 0,
    42, 0,
    52, 0,
    64, 0,
    78, 0,
    96, 0,
    118, 0,
    142, 0,
)
