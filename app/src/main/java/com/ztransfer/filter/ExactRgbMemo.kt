package com.ztransfer.filter

import java.util.concurrent.atomic.AtomicLongArray

/**
 * Bounded exact-color memoization. Collisions recompute; they never approximate a color.
 * Store the RGB key and result atomically so concurrent exports cannot observe a mixed pair.
 */
internal class ExactRgbMemo(bits: Int = 20) {
    init { require(bits in 1..20) }
    private val entries = AtomicLongArray(1 shl bits)
    private val mask = entries.length() - 1
    val bytes: Int get() = entries.length() * 8

    private fun index(rgb: Int): Int {
        val mixed = rgb * -1640531527
        return (mixed xor (mixed ushr 16)) and mask
    }

    fun get(rgb: Int): Int {
        val entry = entries.get(index(rgb))
        return if ((entry ushr 32).toInt() == rgb + 1) (entry and 0xffffff).toInt() else -1
    }

    fun put(rgb: Int, mappedRgb: Int) {
        entries.set(index(rgb), ((rgb + 1).toLong() shl 32) or (mappedRgb.toLong() and 0xffffff))
    }
}
