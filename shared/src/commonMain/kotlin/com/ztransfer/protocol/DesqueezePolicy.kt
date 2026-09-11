package com.ztransfer.protocol

/** Shared display and geometry rules for the monitor desqueeze control. */
object DesqueezePolicy {
    val multipliers: List<Float> = listOf(1f, 1.33f, 1.5f, 1.8f, 2f)

    fun normalized(value: Float): Float = multipliers.minBy { kotlin.math.abs(it - value) }

    fun next(value: Float): Float {
        val index = multipliers.indexOfFirst { kotlin.math.abs(it - value) < 0.01f }
        return multipliers[if (index < 0 || index == multipliers.lastIndex) 0 else index + 1]
    }

    /** The default state is represented by the icon; all other states use a compact number. */
    fun displayLabel(value: Float): String? {
        val multiplier = normalized(value)
        if (multiplier == 1f) return null
        return if (multiplier == 1.33f) "1.3" else multiplier.toString()
    }

    fun scaledAspectRatio(baseAspectRatio: Float, value: Float): Float =
        (baseAspectRatio * normalized(value)).coerceAtLeast(0.01f)
}
