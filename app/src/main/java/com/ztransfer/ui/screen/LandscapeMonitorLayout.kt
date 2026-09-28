package com.ztransfer.ui.screen

/** All dimensions are dp in the already inset-safe landscape viewport. */
internal data class MonitorBounds(val x: Float, val y: Float, val width: Float, val height: Float) {
    val right get() = x + width
    val bottom get() = y + height
}

internal enum class MonitorControlPlacement { RIGHT, BOTTOM, OVERLAY }

internal data class LandscapeMonitorLayout(
    val image: MonitorBounds,
    val controls: MonitorBounds,
    val placement: MonitorControlPlacement,
    val columns: Int,
    val shutterSize: Float,
) {
    /** Include the navigation row in actual hit-test bounds, not just its drawing overflow. */
    val interactionBounds: MonitorBounds
        get() {
            val width = maxOf(128f, controls.width)
            return MonitorBounds((controls.right - width).coerceAtLeast(0f), controls.y,
                minOf(width, controls.right), controls.height)
        }
}

/**
 * Preserves the immersive image fit first, then uses the remaining space for controls.
 * Tool visibility, Dock state and recording state deliberately are not inputs.
 * The audio slot is reserved by camera mode so toggling meters cannot resize the image.
 */
internal fun landscapeMonitorLayout(
    width: Float,
    height: Float,
    imageAspect: Float,
    movie: Boolean,
): LandscapeMonitorLayout {
    require(width.isFinite() && height.isFinite() && width >= 0f && height >= 0f)
    require(imageAspect.isFinite() && imageAspect > 0f)
    val shutter = (height * .18f).coerceIn(48f, 64f)
    val audio = if (movie) 36f else 0f
    val availableWidth = (width - shutter - audio - 24f).coerceAtLeast(0f)
    val availableHeight = (height - 8f).coerceAtLeast(0f)
    val imageWidth = minOf(availableWidth, availableHeight * imageAspect)
    val imageHeight = imageWidth / imageAspect
    val image = MonitorBounds(minOf(4f, width), (height - imageHeight) / 2f, imageWidth, imageHeight)
    val rightX = (image.right + audio + 8f).coerceAtMost(width)
    val rightWidth = (width - rightX - 4f).coerceAtLeast(0f)
    val bottomY = (image.bottom + 8f).coerceAtMost(height)
    val bottomHeight = (height - bottomY - 4f).coerceAtLeast(0f)
    val safeHeight = (height - 16f).coerceAtLeast(0f)
    val placement = when {
        rightWidth >= 176f && safeHeight >= 292f -> MonitorControlPlacement.RIGHT
        rightWidth >= 88f && safeHeight >= 460f -> MonitorControlPlacement.RIGHT
        bottomHeight >= 156f && width >= 360f -> MonitorControlPlacement.BOTTOM
        else -> MonitorControlPlacement.OVERLAY
    }
    val controls = when (placement) {
        MonitorControlPlacement.RIGHT -> MonitorBounds(rightX, minOf(8f, height), rightWidth, safeHeight)
        MonitorControlPlacement.BOTTOM -> MonitorBounds(minOf(8f, width), bottomY, (width - 16f).coerceAtLeast(0f), bottomHeight)
        MonitorControlPlacement.OVERLAY -> {
            val panelWidth = minOf(192f, (width - 16f).coerceAtLeast(0f))
            MonitorBounds((width - panelWidth - 8f).coerceAtLeast(0f), minOf(8f, height), panelWidth, safeHeight)
        }
    }
    return LandscapeMonitorLayout(image, controls, placement, if (controls.width >= 176f) 2 else 1, shutter)
}
