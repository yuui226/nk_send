package com.ztransfer.ui.screen

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.ui.geometry.Rect
import kotlin.math.PI
import kotlin.math.sin

/** Geometry only: drawing and layer transforms consume this without recomposing settings content. */
internal data class SettingsPopupFrame(
    val bounds: Rect,
    val cornerRadius: Float,
    val shellAlpha: Float,
    val contentAlpha: Float,
)

internal fun settingsPopupFrame(
    progress: Float,
    anchor: Rect?,
    panel: Rect,
    cornerRadius: Float,
): SettingsPopupFrame {
    val p = if (progress.isFinite()) progress.coerceIn(0f, 1f) else 0f
    val origin = anchor?.takeIf {
        it.left.isFinite() && it.top.isFinite() && it.right.isFinite() && it.bottom.isFinite() &&
            it.width > 0f && it.height > 0f && panel.top >= it.bottom
    }
    if (origin == null || panel.width <= 0f || panel.height <= 0f) {
        return SettingsPopupFrame(panel, cornerRadius, p, p)
    }
    if (p == 1f) return SettingsPopupFrame(panel, cornerRadius, 1f, 1f)
    // Grow immediately from the lower edge, not from a travelling ball over the button.
    // A restrained final swell settles at exactly the measured size. Reversing this same
    // curve is continuous even when dismissal interrupts the opening animation.
    val base = 1f - (1f - p) * (1f - p) * (1f - p)
    val settle = if (p > 0.5f) sin(PI.toFloat() * (p - 0.5f) / 0.5f) * 0.018f else 0f
    val grow = base + settle
    val seedWidth = minOf(origin.width * 0.8f, panel.width)
    val width = mix(seedWidth, panel.width, grow)
    val centerX = mix(origin.center.x, panel.center.x, grow.coerceAtMost(1f))
    val top = mix(origin.bottom, panel.top, grow.coerceAtMost(1f))
    val height = panel.height * grow
    val bounds = Rect(centerX - width / 2f, top, centerX + width / 2f, top + height)
    return SettingsPopupFrame(
        bounds = bounds,
        cornerRadius = minOf(cornerRadius, width / 2f, height / 2f),
        // Disappear at the seam before a little remnant could look like a projectile.
        shellAlpha = smooth((p - 0.045f) / 0.12f),
        contentAlpha = smooth((base - 0.42f) / 0.58f),
    )
}

private fun smooth(fraction: Float): Float =
    FastOutSlowInEasing.transform(fraction.coerceIn(0f, 1f))

private fun mix(start: Float, end: Float, fraction: Float): Float =
    start + (end - start) * fraction
