package com.ztransfer.ui.theme

import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import kotlinx.cinterop.ExperimentalForeignApi
import org.jetbrains.skia.ColorAlphaType
import org.jetbrains.skia.ColorSpace
import org.jetbrains.skia.ColorType
import org.jetbrains.skia.Image
import org.jetbrains.skia.ImageInfo
import platform.Foundation.NSRecursiveLock

/** Unpremultiplied input must not be interpreted as opaque or premultiplied colored pixels. */
internal actual fun createTextureImageBitmap(pixels: IntArray, width: Int, height: Int): ImageBitmap {
    val bytes = textureRgbaBytes(pixels, width, height)
    val image = Image.makeRaster(
        ImageInfo(width, height, ColorType.RGBA_8888, ColorAlphaType.UNPREMUL, ColorSpace.sRGB),
        bytes, width * 4,
    )
    // Compose 1.8.2 creates a separate immutable Bitmap; the temporary Image can be released.
    return try { image.toComposeImageBitmap() } finally { image.close() }
}

@OptIn(ExperimentalForeignApi::class)
internal actual class TextureCacheLock actual constructor() {
    private val lock = NSRecursiveLock()
    actual fun <T> withLock(action: () -> T): T {
        lock.lock()
        return try { action() } finally { lock.unlock() }
    }
}
