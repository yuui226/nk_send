package com.ztransfer.ui.screen

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Matrix
import kotlin.math.PI
import kotlin.math.pow
import kotlin.math.sin

internal const val GENIE_BANDS = 48
internal const val GENIE_EXPAND_DURATION_MS = 320
internal const val GENIE_COLLAPSE_DURATION_MS = 350
// Runtime rendering uses a small number of affine bands; the geometry regression grid
// remains 48. Twelve bands keep the inlet shape legible while avoiding dozens of expensive
// full-layer draws on iOS for every animation frame.
internal const val GENIE_RENDER_BANDS = 12
// Settings ZMark: 20dp tall, aspect = ZW (0.62) + SHEAR (0.30) + DX (0.44).
internal const val GENIE_Z_MARK_WIDTH_DP = 20f * (0.62f + 0.30f + 0.44f)
internal val GenieExpandEasing = CubicBezierEasing(0.16f, 0.40f, 0.22f, 1f)
internal val GenieCollapseEasing = CubicBezierEasing(0.30f, 0.18f, 0.60f, 1f)

/** A cross-section of the bent panel; positive tilt lifts its right endpoint. */
internal data class GenieRow(val left: Float, val right: Float, val y: Float, val tilt: Float = 0f) {
    val leftY: Float get() = y + tilt / 2f
    val rightY: Float get() = y - tilt / 2f
}

internal fun genieProgress(value: Float): Float =
    if (value.isFinite()) value.coerceIn(0f, 1f) else 0f

/** Retain the panel's length while its inlet narrows, then let the tail follow continuously. */
internal fun genieLength(progress: Float): Float {
    val p = genieProgress(progress)
    return p * (2f - p)
}

/** Only soften the last 3% of travel; do not fade a still-recognisable miniature panel. */
internal fun geniePanelAlpha(progress: Float): Float =
    genieSmooth((genieLength(progress) - 0.002f) / 0.028f)

internal fun validGenieAnchor(anchor: Rect?, panel: Rect): Boolean =
    anchor != null && listOf(anchor.left, anchor.top, anchor.right, anchor.bottom,
        panel.left, panel.top, panel.right, panel.bottom).all { it.isFinite() } &&
        anchor.width > 0f && anchor.height > 0f && panel.width > 0f && panel.height > 0f &&
        anchor.bottom <= panel.top

internal fun genieRow(
    progress: Float, fraction: Float, anchor: Rect, panel: Rect,
    mouthWidth: Float = anchor.height * GENIE_Z_MARK_WIDTH_DP / 36f,
): GenieRow {
    val p = genieProgress(progress)
    val v = genieProgress(fraction)
    if (p == 1f) return GenieRow(0f, panel.width, panel.height * v)
    // A right-hand filter button uses the mirrored funnel. Keeping a left-hand tilt there
    // would oppose its leftward travel and can fold tiny triangles on a short panel.
    if (anchor.center.x > panel.center.x) {
        val mirrored = Rect(panel.left + panel.right - anchor.right, anchor.top,
            panel.left + panel.right - anchor.left, anchor.bottom)
        val row = genieRow(p, v, mirrored, panel, mouthWidth)
        return GenieRow(panel.width - row.right, panel.width - row.left, row.y, -row.tilt)
    }
    val dockX = anchor.center.x - panel.left
    val dockY = anchor.bottom - panel.top
    val length = genieLength(p)
    // Width and travel deliberately have different clocks derived from the SAME progress.
    // The inlet responds first, the broad tail follows; no delayed phase or reversal jump.
    // Avoid smoothing p again here: stacked easing used to hide most motion in a short burst.
    val spread = p.pow(0.85f + 2.1f * (1f - v) * (1f - v))
    // Logo-sized opening, not button-sized and not a needle. All rows still fan continuously.
    val seedWidth = minOf(anchor.width, panel.width,
        if (mouthWidth.isFinite() && mouthWidth > 0f) mouthWidth else anchor.width * 0.5f)
    val width = mix(seedWidth, panel.width, spread)
    val envelope = 16f * p * p * (1f - p) * (1f - p)
    val drift = seedWidth * 0.22f * envelope * (1f - spread) * (0.35f + 0.65f * v)
    val center = mix(dockX, panel.width / 2f, spread) + drift
    // Bow the left edge inward as well; stay within the panel rather than off-screen.
    val bowPhase = sin(PI.toFloat() * v).coerceAtLeast(0f)
    val bow = minOf(
        minOf(panel.width * 0.075f, anchor.width * 0.5f, width * 0.2f) * envelope * bowPhase * bowPhase,
        (width - seedWidth) * 0.3f,
    )
    val left = center - width / 2f + bow
    val right = center + width / 2f - bow * 0.15f
    val bentV = v + 0.4f * (1f - p) * (v * v - v)
    // A short diagonal inlet: right endpoint meets the button's lower edge, never covers it.
    val mouthTilt = minOf(seedWidth * 0.14f, panel.width * 0.045f) * (1f - length)
    val y = dockY * (1f - length) + panel.height * length * bentV + mouthTilt / 2f
    val bodyTilt = minOf((right - left) * 0.07f, panel.width * 0.035f,
        panel.height * length * 0.12f) * envelope * v * v
    val tilt = minOf(mouthTilt + bodyTilt, (right - left) * 0.14f, panel.width * 0.045f)
    return GenieRow(left, right, y, tilt)
}

/**
 * Two affine triangles per band support a tilted bottom without texture slips at shared edges.
 * Both triangles interpolate their shared diagonal identically; adjacent bands do likewise.
 */
internal fun genieBandMatrix(
    sourceWidth: Float, sourceTop: Float, sourceBottom: Float,
    top: GenieRow, bottom: GenieRow, upper: Boolean,
): Matrix {
    val height = sourceBottom - sourceTop
    require(sourceWidth > 0f && height > 0f && top.right > top.left && bottom.right > bottom.left)
    val xAcross = if (upper) (top.right - top.left) / sourceWidth else (bottom.right - bottom.left) / sourceWidth
    val yAcross = if (upper) (top.rightY - top.leftY) / sourceWidth else (bottom.rightY - bottom.leftY) / sourceWidth
    val xDown = if (upper) (bottom.left - top.left) / height else (bottom.right - top.right) / height
    val yDown = if (upper) (bottom.leftY - top.leftY) / height else (bottom.rightY - top.rightY) / height
    val originX = if (upper) top.left - xDown * sourceTop else bottom.left - xDown * sourceBottom
    val originY = if (upper) top.leftY - yDown * sourceTop else bottom.leftY - yDown * sourceBottom
    return Matrix().apply {
        this[0, 0] = xAcross
        this[0, 1] = yAcross
        this[1, 0] = xDown
        this[1, 1] = yDown
        this[3, 0] = originX
        this[3, 1] = originY
    }
}

private fun genieSmooth(value: Float): Float {
    val t = value.coerceIn(0f, 1f)
    return t * t * (3f - 2f * t)
}

private fun mix(start: Float, end: Float, fraction: Float): Float =
    start + (end - start) * fraction
