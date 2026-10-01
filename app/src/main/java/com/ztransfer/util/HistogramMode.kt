package com.ztransfer.util

/** Shared histogram modes; each screen persists its own selection. */
enum class HistogramMode { OFF, RGB, LUMA;
    fun next() = entries[(ordinal + 1) % entries.size]
    companion object {
        fun restore(saved: String?, previouslyEnabled: Boolean = false): HistogramMode =
            entries.find { it.name == saved } ?: if (previouslyEnabled) LUMA else OFF
    }
}
