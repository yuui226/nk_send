package com.ztransfer.protocol

private data class XmpRatingPatterns(val attribute: Regex, val element: Regex)

private val xmpNamespacePattern = Regex(
    "xmlns:([A-Za-z_][\\w.-]*)\\s*=\\s*[\\\"']http://ns.adobe.com/xap/1.0/[\\\"']",
)
private val xmpRatingPatternCache = HashMap<String, XmpRatingPatterns>()
private val xmpRatingPatternLock = Any()

private fun xmpRatingPatterns(prefix: String): XmpRatingPatterns = synchronized(xmpRatingPatternLock) {
    xmpRatingPatternCache.getOrPut(prefix) {
        val name = Regex.escape("$prefix:Rating")
        XmpRatingPatterns(
            attribute = Regex("\\b$name\\s*=\\s*[\\\"']\\s*(-?\\d+)\\s*[\\\"']"),
            element = Regex("<$name\\s*>\\s*(-?\\d+)\\s*</$name\\s*>"),
        )
    }
}

/** A missing/truncated/unsupported field is unknown, never zero stars. */
internal fun parsePhotoRating(bytes: ByteArray): Int? {
    fun xmp(start: Int, end: Int): Int? {
        val text = bytes.copyOfRange(start, end).toString(Charsets.UTF_8)
        for (match in xmpNamespacePattern.findAll(text)) {
            val patterns = xmpRatingPatterns(match.groupValues[1])
            val value = patterns.attribute.find(text)?.groupValues?.get(1)
                ?: patterns.element.find(text)?.groupValues?.get(1)
            value?.toIntOrNull()?.takeIf { it in -1..5 }?.let { return it }
        }
        return null
    }

    fun tiff(start: Int, end: Int): Int? {
        if (start < 0 || end - start < 8) return null
        val little = bytes[start] == 73.toByte() && bytes[start + 1] == 73.toByte()
        if (!little && !(bytes[start] == 77.toByte() && bytes[start + 1] == 77.toByte())) return null
        fun uint(p: Int, n: Int): Long? {
            if (p < start || p.toLong() + n > end) return null
            var value = 0L
            repeat(n) { i -> value = value or ((bytes[p + i].toLong() and 255) shl (8 * if (little) i else n - 1 - i)) }
            return value
        }
        if (uint(start + 2, 2) != 42L) return null
        val offset = uint(start + 4, 4) ?: return null
        if (offset < 8 || offset > end.toLong() - start - 2) return null
        val ifd = start + offset.toInt()
        val count = uint(ifd, 2)?.toInt() ?: return null
        if (ifd.toLong() + 2 + count.toLong() * 12 > end) return null
        var rating: Int? = null
        repeat(count) { index ->
            val p = ifd + 2 + index * 12
            if (uint(p, 2) == 0x4746L) {
                if (uint(p + 2, 2) == 3L && uint(p + 4, 4) == 1L)
                    rating = uint(p + 8, 2)?.toInt()?.takeIf { it in 0..5 }
            }
            // TIFF/NEF can carry the standard XMP packet in tag 700.
            if (uint(p, 2) == 700L && uint(p + 2, 2) in listOf(1L, 7L)) {
                val length = uint(p + 4, 4) ?: return@repeat
                val position = if (length <= 4) (p + 8).toLong() else start + (uint(p + 8, 4) ?: return@repeat)
                if (length in 1..262144 && position >= start && position + length <= end) {
                    xmp(position.toInt(), (position + length).toInt())?.let { return it }
                }
            }
        }
        return rating
    }
    if (bytes.size < 8) return null
    if (bytes[0] != 0xff.toByte() || bytes[1] != 0xd8.toByte()) return tiff(0, bytes.size)
    var p = 2
    var exifRating: Int? = null
    while (p + 4 <= bytes.size) {
        if (bytes[p] != 0xff.toByte()) return exifRating
        val marker = bytes[p + 1].toInt() and 255
        if (marker == 0xda || marker == 0xd9) break
        val length = ((bytes[p + 2].toInt() and 255) shl 8) or (bytes[p + 3].toInt() and 255)
        if (length < 2 || p.toLong() + 2 + length > bytes.size) break
        val start = p + 4
        val end = p + 2 + length
        if (marker == 0xe1) {
            val exif = byteArrayOf(69, 120, 105, 102, 0, 0)
            if (end - start >= 6 && exif.indices.all { bytes[start + it] == exif[it] }) {
                exifRating = tiff(start + 6, end) ?: exifRating
            } else {
                val prefix = "http://ns.adobe.com/xap/1.0/\u0000".toByteArray()
                if (end - start >= prefix.size && prefix.indices.all { bytes[start + it] == prefix[it] }) {
                    xmp(start + prefix.size, end)?.let { return it }
                }
            }
        }
        p = end
    }
    return exifRating
}

/** Exact Nikon wire values verified against in-camera stars; never round unknown values. */
internal fun parseNikonObjectRating(bytes: ByteArray): Int? {
    if (bytes.size != 2) return null
    return when ((bytes[0].toInt() and 255) or ((bytes[1].toInt() and 255) shl 8)) {
        0 -> 0
        1 -> 1
        25 -> 2
        50 -> 3
        75 -> 4
        99 -> 5
        else -> null
    }
}
