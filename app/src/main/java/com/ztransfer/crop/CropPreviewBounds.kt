package com.ztransfer.crop

import kotlin.math.abs

/** Detect only paired, near-black, symmetric padding. An entirely dark photo is never trimmed. */
internal fun cropPreviewBounds(width: Int, height: Int, pixel: (Int, Int) -> Int): CropRect {
    fun blackLine(index: Int, horizontal: Boolean): Boolean {
        val length = if (horizontal) width else height
        var dark = 0
        var total = 0
        for (i in 0 until length step maxOf(1, length / 96)) {
            val p = if (horizontal) pixel(i,index) else pixel(index,i)
            if (((p ushr 16) and 255) <= 12 && ((p ushr 8) and 255) <= 12 && (p and 255) <= 12) dark++
            total++
        }
        return dark * 100 >= total * 98
    }
    fun padding(length: Int, horizontal: Boolean): Int {
        val limit = (length * .4).toInt()
        var a = 0
        var b = 0
        while (a < limit && blackLine(a,horizontal)) a++
        while (b < limit && blackLine(length-1-b,horizontal)) b++
        return if (a >= 2 && b >= 2 && a < limit && b < limit && abs(a-b) <= 2) minOf(a,b) else 0
    }
    val x = padding(width,false)
    val y = padding(height,true)
    return CropRect(x,y,width-x,height-y)
}

/** A portrait bitmap for a quarter-turned source has already been oriented by the camera. */
internal fun cropPreviewOrientation(source: Int, embedded: Int?, width: Int, height: Int): Int =
    when {
        embedded != null && embedded in 2..8 -> embedded
        source in 5..8 && height > width -> 1
        else -> source
    }

/** Rotation that stands an unrotated camera bitmap up. Mirrored EXIF has no single angle. */
internal fun previewDegreesForExifOrientation(orientation: Int): Float? = when (orientation) {
    1 -> 0f
    3 -> 180f
    6 -> 90f
    8 -> -90f
    else -> null
}

/** Equivalent angle within half a turn, so a return to the shared rotation does not spin a full circle. */
internal fun nearestRotationDegrees(from: Float, to: Float): Float {
    val delta = ((to - from + 540f) % 360f + 360f) % 360f - 180f
    return from + delta
}

/**
 * Preview JPEG orientation 1 is ambiguous: the tag may be missing and the parser reports
 * normal. A later file-header EXIF can still turn that bitmap. Tags 2..8 are explicit.
 */
internal fun reviewOrientationSettled(embeddedOrientation: Int?, exifFinished: Boolean): Boolean =
    (embeddedOrientation != null && embeddedOrientation in 2..8) || exifFinished

/** Same orientation decision the crop editor uses, expressed as a preview rotation. */
internal fun reviewDisplayRotationDegrees(
    sourceOrientation: Int?,
    embeddedOrientation: Int?,
    width: Int,
    height: Int,
): Float? {
    if (width <= 0 || height <= 0) return null
    val source = sourceOrientation ?: embeddedOrientation ?: return null
    return previewDegreesForExifOrientation(
        cropPreviewOrientation(source, embeddedOrientation, width, height),
    )
}
