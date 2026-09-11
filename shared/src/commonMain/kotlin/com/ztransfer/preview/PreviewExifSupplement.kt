package com.ztransfer.preview

/** Attribute decoding for Native's bounded TIFF reader, not an image/MakerNote decoder.
 * Types, ASCII replacement and GPS arithmetic follow the pinned AndroidX ExifInterface 1.3.7.
 * The original Android adapter and parsePreviewExif formatting policy are unchanged.
 */
internal class PreviewExifSupplement {
    private data class Attribute(val type: Int, val bytes: ByteArray, val priority: Int)
    private val attributes = mutableMapOf<Int, Attribute>()

    fun expectedType(tag: Int, directory: String): Int? = when (directory) {
        "TIFF" -> if (tag == 0x0132) 2 else null
        "EXIF" -> when (tag) { 0x8827 -> 3; 0x9003, 0x9004, 0xA434 -> 2; else -> null }
        "GPS" -> when (tag) { 1, 3 -> 2; 2, 4, 6 -> 5; 5 -> 1; else -> null }
        else -> null
    }

    fun accept(tag: Int, type: Int, bytes: ByteArray, priority: Int = 0) {
        if ((attributes[tag]?.priority ?: Int.MAX_VALUE) >= priority) attributes[tag] = Attribute(type, bytes, priority)
    }

    fun applyTo(values: NativePreviewExifValues, littleEndian: Boolean) {
        fun unsigned(bytes: ByteArray, at: Int, width: Int): Long {
            var value = 0L
            repeat(width) { i -> value = value or ((bytes[at + i].toLong() and 255) shl
                ((if (littleEndian) i else width - i - 1) * 8)) }
            return value
        }
        fun text(tag: Int): String? {
            val attribute = attributes[tag] ?: return null
            val bytes = attribute.bytes
            return when (attribute.type) {
                1 -> if (bytes.size == 1 && bytes[0].toInt() in 0..1) bytes[0].toString()
                    else bytes.joinToString("") { if (it < 0) "\uFFFD" else it.toInt().toChar().toString() }
                2 -> {
                    val prefix = byteArrayOf(65, 83, 67, 73, 73, 0, 0, 0)
                    val start = if (bytes.size >= prefix.size && prefix.indices.all { bytes[it] == prefix[it] }) prefix.size else 0
                    buildString {
                        for (index in start until bytes.size) {
                            val ch = bytes[index].toInt()
                            if (ch == 0) break
                            append(if (ch >= 32) ch.toChar() else '?')
                        }
                    }
                }
                3 -> (bytes.indices step 2).joinToString(",") { unsigned(bytes, it, 2).toString() }
                5 -> (bytes.indices step 8).joinToString(",") {
                    val n = unsigned(bytes, it, 4); val d = unsigned(bytes, it + 4, 4)
                    if (d == 0L) "0/1" else "$n/$d"
                }
                else -> null
            }
        }
        val fields = mapOf(0x8827 to PreviewExifTag.PHOTOGRAPHIC_SENSITIVITY,
            0xA434 to PreviewExifTag.LENS_MODEL, 0x9003 to PreviewExifTag.DATETIME_ORIGINAL,
            0x9004 to PreviewExifTag.DATETIME_DIGITIZED, 0x0132 to PreviewExifTag.DATETIME,
            1 to PreviewExifTag.GPS_LATITUDE_REF, 2 to PreviewExifTag.GPS_LATITUDE,
            3 to PreviewExifTag.GPS_LONGITUDE_REF, 4 to PreviewExifTag.GPS_LONGITUDE)
        // The walker intentionally does not implement every MakerNote/embedded-JPEG route.
        // Preserve ImageIO-only fields instead of treating an unvisited tag as confirmed absent.
        fields.forEach { (id, target) -> if (attributes.containsKey(id)) values.set(target, text(id)) }
        // AndroidX addDefaultValues copies DateTimeOriginal into a missing TIFF DateTime.
        // Do not replace an existing (including blank) DateTime attribute.
        if (!attributes.containsKey(0x0132) && attributes.containsKey(0x9003)) {
            values.set(PreviewExifTag.DATETIME, text(0x9003))
        }
        fun rational(value: String): Double? {
            val parts = value.split('/')
            if (parts.size != 2) return null
            val n = parts[0].toDoubleOrNull() ?: return null
            val d = parts[1].toDoubleOrNull() ?: return null
            return n / d
        }
        fun coordinate(tag: Int): Double? {
            val parts = text(tag)?.split(',') ?: return null
            if (parts.size < 3) return null
            val d = rational(parts[0]) ?: return null
            val m = rational(parts[1]) ?: return null
            val s = rational(parts[2]) ?: return null
            return d + m / 60.0 + s / 3600.0
        }
        // Both raw values and refs must decode as one pair. Lowercase refs deliberately leave
        // the original shared Float fallback in charge, not ImageIO's rounded degree value.
        if ((1..4).any(attributes::containsKey)) {
            // Never combine half a raw pair with a different embedded image's coordinate.
            fields.filterKeys { it in 1..4 }.forEach { (id, target) -> values.set(target, text(id)) }
            values.setImageIoCoordinates(coordinate(2) ?: Double.NaN, text(1),
                coordinate(4) ?: Double.NaN, text(3))
        }
        if (attributes.containsKey(5) || attributes.containsKey(6)) {
            val altitude = text(6)?.let(::rational) ?: Double.NaN
            values.setImageIoAltitude(altitude, text(5)?.toIntOrNull() ?: -1)
        }
    }
}
