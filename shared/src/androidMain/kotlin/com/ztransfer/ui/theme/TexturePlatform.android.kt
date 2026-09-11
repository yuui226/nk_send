package com.ztransfer.ui.theme

import android.graphics.Bitmap
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap

/** Preserve the original Android ARGB_8888 conversion, including Android's alpha handling. */
internal actual fun createTextureImageBitmap(pixels: IntArray, width: Int, height: Int): ImageBitmap =
    Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888).asImageBitmap()

internal actual class TextureCacheLock actual constructor() {
    private val monitor = Any()
    actual fun <T> withLock(action: () -> T): T = synchronized(monitor) { action() }
}
