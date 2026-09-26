package com.ztransfer.crop

import kotlin.math.floor
import kotlin.math.roundToInt

/** Source-pixel coordinates, before EXIF orientation. Right/bottom are exclusive. */
data class CropRect(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val width get() = right - left
    val height get() = bottom - top
}

data class CropPoint(val x: Double, val y: Double)
data class CropBounds(val left: Double, val top: Double, val right: Double, val bottom: Double)

data class JpegCropSource(
    val width: Int,
    val height: Int,
    val mcuWidth: Int,
    val mcuHeight: Int,
    val orientation: Int,
) {
    init {
        require(width > 0 && height > 0 && mcuWidth > 0 && mcuHeight > 0 && orientation in 1..8)
    }
    val swapsAxes get() = orientation >= 5
    val displayWidth get() = if (swapsAxes) height else width
    val displayHeight get() = if (swapsAxes) width else height

    fun toDisplay(x: Double, y: Double): CropPoint = when (orientation) {
        2 -> CropPoint(1 - x, y)
        3 -> CropPoint(1 - x, 1 - y)
        4 -> CropPoint(x, 1 - y)
        5 -> CropPoint(y, x)
        6 -> CropPoint(1 - y, x)
        7 -> CropPoint(1 - y, 1 - x)
        8 -> CropPoint(y, 1 - x)
        else -> CropPoint(x, y)
    }
    fun toSource(x: Double, y: Double): CropPoint = when (orientation) {
        6 -> CropPoint(y, 1 - x)
        8 -> CropPoint(1 - y, x)
        else -> toDisplay(x, y)
    }

    fun displayBounds(rect: CropRect): CropBounds {
        val a = toDisplay(rect.left.toDouble() / width, rect.top.toDouble() / height)
        val b = toDisplay(rect.right.toDouble() / width, rect.bottom.toDouble() / height)
        return CropBounds(minOf(a.x, b.x), minOf(a.y, b.y), maxOf(a.x, b.x), maxOf(a.y, b.y))
    }

    /** Snap once before confirmation. Export validates this exact rectangle and never adjusts it. */
    fun align(bounds: CropBounds, ratioWidth: Int = 0, ratioHeight: Int = 0): CropRect {
        require(listOf(bounds.left, bounds.top, bounds.right, bounds.bottom).all { it.isFinite() && it in 0.0..1.0 })
        require(bounds.right > bounds.left && bounds.bottom > bounds.top)
        require((ratioWidth == 0 && ratioHeight == 0) || (ratioWidth > 0 && ratioHeight > 0))
        val a = toSource(bounds.left, bounds.top)
        val b = toSource(bounds.right, bounds.bottom)
        val left = minOf(a.x, b.x) * width
        val top = minOf(a.y, b.y) * height
        val requestedWidth = (kotlin.math.abs(a.x - b.x) * width).coerceAtLeast(1.0)
        val requestedHeight = (kotlin.math.abs(a.y - b.y) * height).coerceAtLeast(1.0)
        var w = requestedWidth.roundToInt().coerceIn(1, width)
        var h = requestedHeight.roundToInt().coerceIn(1, height)
        if (ratioWidth > 0) {
            val rw = if (swapsAxes) ratioHeight else ratioWidth
            val rh = if (swapsAxes) ratioWidth else ratioHeight
            val divisor = gcd(rw, rh)
            val unitW = rw / divisor
            val unitH = rh / divisor
            if (unitW > 64 || unitH > 64) {
                // Original dimensions can be relatively prime. Preserve their visual ratio within
                // one pixel instead of allowing only huge (or full-image-only) crop increments.
                val scale = minOf(requestedWidth / rw, requestedHeight / rh)
                w = (rw * scale).roundToInt().coerceIn(1, width)
                h = (rh * scale).roundToInt().coerceIn(1, height)
            } else {
                val count = floor(minOf(requestedWidth / unitW, requestedHeight / unitH) + 1e-4).toInt()
                require(count > 0) { "Crop $requestedWidth x $requestedHeight is smaller than aspect unit $unitW x $unitH" }
                w = unitW * count
                h = unitH * count
            }
        }
        val x = (((left + (requestedWidth - w) / 2) / mcuWidth).roundToInt() * mcuWidth)
            .coerceIn(0, ((width - w) / mcuWidth) * mcuWidth)
        val y = (((top + (requestedHeight - h) / 2) / mcuHeight).roundToInt() * mcuHeight)
            .coerceIn(0, ((height - h) / mcuHeight) * mcuHeight)
        return CropRect(x, y, x + w, y + h)
    }
    fun validate(rect: CropRect) {
        require(rect.left >= 0 && rect.top >= 0 && rect.right <= width && rect.bottom <= height)
        require(rect.width > 0 && rect.height > 0)
        require(rect.left % mcuWidth == 0 && rect.top % mcuHeight == 0)
    }
}

/** Immutable queue recipe. Carries the source geometry so a changed/mismatched source fails safely. */
data class JpegCropRecipe(val source: JpegCropSource, val rect: CropRect) {
    init { source.validate(rect) }
}

private tailrec fun gcd(a: Int, b: Int): Int = if (b == 0) a else gcd(b, a % b)

/** A display-oriented FHD selection, independent of original resolution and JPEG sampling. */
data class JpegCropSelection(
    val bounds: CropBounds,
    val orientation: Int,
    val ratioWidth: Int = 0,
    val ratioHeight: Int = 0,
) {
    init {
        require(orientation in 1..8)
        require(listOf(bounds.left,bounds.top,bounds.right,bounds.bottom).all { it.isFinite() && it in 0.0..1.0 })
        require(bounds.left < bounds.right && bounds.top < bounds.bottom)
        require((ratioWidth == 0 && ratioHeight == 0) || (ratioWidth > 0 && ratioHeight > 0))
    }
    fun resolve(source: JpegCropSource): JpegCropRecipe {
        require(source.orientation == orientation) { "Photo orientation changed since crop selection" }
        return JpegCropRecipe(source, source.align(bounds, ratioWidth, ratioHeight))
    }
}

internal fun transformCropBounds(bounds: CropBounds, orientation: Int, inverse: Boolean = false): CropBounds {
    val space=JpegCropSource(1,1,1,1,orientation)
    val a=if(inverse) space.toSource(bounds.left,bounds.top) else space.toDisplay(bounds.left,bounds.top)
    val b=if(inverse) space.toSource(bounds.right,bounds.bottom) else space.toDisplay(bounds.right,bounds.bottom)
    return CropBounds(minOf(a.x,b.x),minOf(a.y,b.y),maxOf(a.x,b.x),maxOf(a.y,b.y))
}
