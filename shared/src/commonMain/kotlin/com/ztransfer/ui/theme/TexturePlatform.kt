package com.ztransfer.ui.theme

import androidx.compose.ui.graphics.ImageBitmap

/** Only the platform bitmap and a short synchronous cache lock differ between targets. */
internal expect fun createTextureImageBitmap(pixels: IntArray, width: Int, height: Int): ImageBitmap

internal expect class TextureCacheLock() {
    fun <T> withLock(action: () -> T): T
}

/** Math.floorMod parity for positive texture variant/grid sizes, including negative seeds. */
internal fun textureFloorMod(value: Int, divisor: Int): Int {
    require(divisor > 0)
    return value.mod(divisor)
}

/** CPU textures are straight-alpha ARGB ints; spell out RGBA bytes independent of native endian. */
internal fun textureRgbaBytes(pixels: IntArray, width: Int, height: Int): ByteArray {
    require(width > 0 && height > 0)
    val count = width.toLong() * height.toLong()
    require(count <= Int.MAX_VALUE / 4 && count == pixels.size.toLong())
    return ByteArray(pixels.size * 4).also { bytes ->
        pixels.forEachIndexed { index, pixel ->
            val offset = index * 4
            bytes[offset] = (pixel ushr 16).toByte()
            bytes[offset + 1] = (pixel ushr 8).toByte()
            bytes[offset + 2] = pixel.toByte()
            bytes[offset + 3] = (pixel ushr 24).toByte()
        }
    }
}
