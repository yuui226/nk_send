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
