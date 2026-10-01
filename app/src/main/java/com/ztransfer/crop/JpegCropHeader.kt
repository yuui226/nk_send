package com.ztransfer.crop

/** Reads only the bounded original JPEG prefix. Never substitutes dimensions of its embedded preview. */
internal fun parseJpegCropHeader(bytes: ByteArray): JpegCropSource? {
    fun u8(at: Int) = bytes[at].toInt() and 255
    fun u16(at: Int) = (u8(at) shl 8) or u8(at + 1)
    if (bytes.size < 4 || u16(0) != 0xFFD8) return null
    var at = 2
    var orientation = 1
    var frame: JpegCropSource? = null
    while (at + 4 <= bytes.size) {
        if (u8(at++) != 255) return null
        while (at < bytes.size && u8(at) == 255) at++
        if (at >= bytes.size) return null
        val marker = u8(at++)
        if (marker == 0xDA) return frame?.copy(orientation = orientation)
        if (marker == 0xD9) return null
        if (marker == 0x01 || marker in 0xD0..0xD7) continue
        if (at + 2 > bytes.size) return null
        val length = u16(at)
        if (length < 2 || at + length > bytes.size) return null
        if (marker == 0xE1 && length >= 8 &&
            bytes.copyOfRange(at + 2, at + 8).contentEquals(byteArrayOf(69, 120, 105, 102, 0, 0))) {
            orientation = parseExifOrientation(bytes, at + 8, at + length) ?: return null
        }
        if (marker in listOf(0xC0, 0xC1, 0xC2)) {
            if (length < 8 || u8(at + 2) != 8) return null
            val height = u16(at + 3)
            val width = u16(at + 5)
            val components = u8(at + 7)
            if (width == 0 || height == 0 || components !in listOf(1, 3) || length != 8 + components * 3) return null
            val sampling = (0 until components).map { u8(at + 9 + it * 3) }
            if (sampling.any { (it shr 4) !in 1..4 || (it and 15) !in 1..4 }) return null
            frame = JpegCropSource(width, height, sampling.maxOf { it shr 4 } * 8,
                sampling.maxOf { it and 15 } * 8, orientation)
        }
        at += length
    }
    return null // Incomplete prefix is not enough to enable confirmation.
}

private fun parseExifOrientation(bytes: ByteArray, start: Int, end: Int): Int? {
    if (end - start < 8) return null
    val little = bytes[start] == 73.toByte() && bytes[start + 1] == 73.toByte()
    if (!little && !(bytes[start] == 77.toByte() && bytes[start + 1] == 77.toByte())) return null
    fun value(at: Int, count: Int): Long {
        var result = 0L
        for (i in 0 until count) {
            val shift = if (little) i * 8 else (count - 1 - i) * 8
            result = result or ((bytes[at + i].toLong() and 255) shl shift)
        }
        return result
    }
    if (value(start + 2, 2) != 42L) return null
    val offset = value(start + 4, 4)
    if (offset < 8 || offset > end - start - 2) return null
    val ifd = start + offset.toInt()
    val count = value(ifd, 2).toInt()
    if (count.toLong() * 12 + ifd + 2 > end) return null
    for (i in 0 until count) {
        val entry = ifd + 2 + i * 12
        if (value(entry, 2) == 0x112L) {
            if (value(entry + 2, 2) != 3L || value(entry + 4, 4) != 1L) return null
            return value(entry + 8, 2).toInt().takeIf { it in 1..8 }
        }
    }
    return 1
}

/** EXIF-only lookup: does not require SOF dimensions, MCU data or a complete JPEG prefix. */
internal fun parseJpegCropOrientation(bytes: ByteArray): Int? {
    fun u8(at: Int) = bytes[at].toInt() and 255
    fun u16(at: Int) = (u8(at) shl 8) or u8(at+1)
    if (bytes.size < 4 || u16(0) != 0xFFD8) return null
    var at = 2
    while (at + 4 <= bytes.size) {
        if (u8(at++) != 255) return null
        while (at < bytes.size && u8(at) == 255) at++
        if (at >= bytes.size) return null
        val marker = u8(at++)
        if (marker == 0xDA || marker == 0xD9) return 1
        if (marker == 0x01 || marker in 0xD0..0xD7) continue
        if (at+2 > bytes.size) return null
        val length = u16(at)
        if (length < 2 || at + length > bytes.size) return null
        if (marker == 0xE1 && length >= 8 &&
            bytes.copyOfRange(at+2,at+8).contentEquals(byteArrayOf(69,120,105,102,0,0))) {
            return parseExifOrientation(bytes, at+8, at+length)
        }
        at += length
    }
    return null
}
