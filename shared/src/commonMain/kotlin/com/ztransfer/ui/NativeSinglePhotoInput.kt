package com.ztransfer.ui

/** Default bounds for the normalized diagnostic image; local originals opt into representation bounds. */
internal const val SINGLE_PHOTO_MAX_BYTES = 20 * 1024 * 1024

internal fun isBoundedSinglePhotoPng(bytes: ByteArray, maxBytes: Int = SINGLE_PHOTO_MAX_BYTES, maxEdge: Int = 2048): Boolean {
    if (bytes.size !in 33..maxBytes) return false
    val signature = intArrayOf(137, 80, 78, 71, 13, 10, 26, 10)
    if (signature.indices.any { (bytes[it].toInt() and 255) != signature[it] }) return false
    fun u32(offset: Int): Long = (offset until offset + 4).fold(0L) { value, i ->
        (value shl 8) or (bytes[i].toLong() and 255)
    }
    if (u32(8) != 13L || u32(12) != 0x49484452L) return false // First chunk must be IHDR.
    return u32(16) in 1..maxEdge.toLong() && u32(20) in 1..maxEdge.toLong()
}
