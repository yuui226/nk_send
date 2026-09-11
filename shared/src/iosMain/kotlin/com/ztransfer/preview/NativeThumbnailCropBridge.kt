package com.ztransfer.preview

import kotlinx.cinterop.*
import platform.Foundation.NSData
import platform.posix.memcpy

/** One bulk copy of straight sRGB ARGB for detection; the original CGImage is cropped by Apple. */
@OptIn(ExperimentalForeignApi::class)
object NativeThumbnailCropBridge {
    fun crop(data: NSData, width: Int, height: Int, video: Boolean): ThumbnailCrop? {
        val required = width.toLong() * height * 4
        if (width <= 0 || height <= 0 || required !in 1..(128L * 1024 * 1024) ||
            data.length != required.toULong()) return null
        val pointer = data.bytes ?: return null
        val bytes = ByteArray(required.toInt())
        bytes.usePinned { memcpy(it.addressOf(0), pointer, data.length) }
        val full = Pixels(bytes, width, width, height, 0, 0)
        val first = ThumbnailCropPolicy.letterbox(full) ?: ThumbnailCrop(0, 0, width, height)
        val second = if (video) ThumbnailCropPolicy.videoBars(
            Pixels(bytes, width, first.width, first.height, first.left, first.top)) else null
        val result = second?.let { ThumbnailCrop(first.left + it.left, first.top + it.top, it.width, it.height) } ?: first
        return result.takeUnless { it.left == 0 && it.top == 0 && it.width == width && it.height == height }
    }
    private class Pixels(val bytes: ByteArray, val stride: Int, override val width: Int,
                         override val height: Int, val left: Int, val top: Int) : ThumbnailCropPixels {
        override fun readLine(index: Int, horizontal: Boolean, into: IntArray) {
            val count = if (horizontal) width else height
            repeat(count) { position ->
                val x = left + if (horizontal) position else index
                val y = top + if (horizontal) index else position
                val offset = (y * stride + x) * 4
                into[position] = ((bytes[offset].toInt() and 255) shl 24) or
                    ((bytes[offset + 1].toInt() and 255) shl 16) or
                    ((bytes[offset + 2].toInt() and 255) shl 8) or (bytes[offset + 3].toInt() and 255)
            }
        }
    }
}
