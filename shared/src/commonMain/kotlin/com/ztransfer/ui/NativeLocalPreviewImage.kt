package com.ztransfer.ui

/** Full-resolution local PNG; never interpreted as a 1920-pixel camera FHD payload. */
class NativeLocalPreviewImage internal constructor(
    internal val encoded: ByteArray,
    val width: Int,
    val height: Int,
)

internal fun ownedLocalPreviewPng(bytes: ByteArray): NativeLocalPreviewImage? {
    // Only representation bounds, not a downsample or product resolution limit. Allocation may fail.
    if (!isBoundedSinglePhotoPng(bytes, maxBytes = Int.MAX_VALUE, maxEdge = Int.MAX_VALUE)) return null
    fun dimension(offset: Int): Int = (offset until offset + 4).fold(0) { value, i ->
        (value shl 8) or (bytes[i].toInt() and 255)
    }
    return NativeLocalPreviewImage(bytes, dimension(16), dimension(20))
}

interface NativeLocalPreviewCompletion { fun complete(image: NativeLocalPreviewImage?) }
