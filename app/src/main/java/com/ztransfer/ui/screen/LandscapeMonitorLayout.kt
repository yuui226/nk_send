package com.ztransfer.ui.screen

/** All dimensions are dp in the already inset-safe landscape viewport. */
internal data class MonitorBounds(val x: Float, val y: Float, val width: Float, val height: Float) {
    val right get() = x + width
    val bottom get() = y + height
}

internal data class LandscapeMonitorLayout(
    val image: MonitorBounds,
    val controls: MonitorBounds,
    val columns: Int,
    val shutterSize: Float,
    val bottomControls: Boolean = false,
) {
    val footerHeight: Float get() = maxOf(36f, shutterSize) + 40f
    // Use spare height on wide rails to bring capture closer to the parameter controls.
    val captureLift: Float get() = if (!bottomControls && columns == 2)
        ((controls.height - 36f - 8f - footerHeight - 98f) / 3f).coerceIn(0f, 48f) else 0f
    val parameterHeight: Float get() = when {
        bottomControls -> 46f
        columns == 1 -> ((controls.height - 36f - 8f - footerHeight - 6f) / 4f).coerceIn(42f, 46f)
        else -> 46f
    }
    val interactionBounds: MonitorBounds get() = controls
}

/** Fit the largest image first. Use natural side/bottom space before reducing its size.
 * Only when neither fits, compare both arrangements and keep the larger image.
 */
internal fun landscapeMonitorLayout(
    width: Float,
    height: Float,
    imageAspect: Float,
): LandscapeMonitorLayout {
    require(width.isFinite() && height.isFinite() && width >= 0f && height >= 0f)
    require(imageAspect.isFinite() && imageAspect > 0f)
    val shutter = (height * .18f).coerceIn(48f, 64f)
    val fullWidth = minOf((width - 8f).coerceAtLeast(0f),
        (height - 8f).coerceAtLeast(0f) * imageAspect)
    // Never reserve a two-column rail just because the viewport is short.
    val minimumRail = 116f
    val sideWidth = minOf(fullWidth, (width - minimumRail - 16f).coerceAtLeast(0f))
    // Header + two compact parameter rows. Recorder and shutter sit beside those rows.
    val bottomHeight = 164f
    val bottomWidth = if (width >= 360f && height >= bottomHeight + 16f)
        minOf(fullWidth, (height - bottomHeight - 16f) * imageAspect) else -1f
    val useBottom = bottomWidth > sideWidth + .01f
    val imageWidth = if (useBottom) bottomWidth else sideWidth
    val imageHeight = imageWidth / imageAspect
    val imageY = if (useBottom) minOf((height - imageHeight) / 2f,
        height - bottomHeight - 12f - imageHeight).coerceAtLeast(4f)
        else (height - imageHeight) / 2f
    val image = MonitorBounds(minOf(4f, width), imageY, imageWidth, imageHeight)
    val controls = if (useBottom) {
        MonitorBounds(4f, image.bottom + 8f, (width - 8f).coerceAtLeast(0f),
            (height - image.bottom - 12f).coerceAtLeast(0f))
    } else {
        val rightX = (image.right + 8f).coerceAtMost(width)
        MonitorBounds(rightX, minOf(8f, height), (width - rightX - 4f).coerceAtLeast(0f),
            (height - 12f).coerceAtLeast(0f))
    }
    val columns = if (useBottom) 2 else if (controls.width >= 176f) 2 else 1
    // Enlarge within existing free width only; keep the left DISP/rotation column clear.
    val captureSize = if (useBottom) shutter else (controls.width - 56f).coerceIn(48f, 74f)
    return LandscapeMonitorLayout(image, controls, columns, captureSize, useBottom)
}
