package com.ztransfer.preview

/** Synchronous random reads only; the Native owner supplies an already-validated descriptor. */
fun interface PreviewExifByteSource {
    fun read(offset: Long, count: Int): ByteArray?
}

private val rationalTags = mapOf(
    0x829D to PreviewExifTag.F_NUMBER,
    0x829A to PreviewExifTag.EXPOSURE_TIME,
    0x9202 to PreviewExifTag.APERTURE_VALUE,
    0x9204 to PreviewExifTag.EXPOSURE_BIAS_VALUE,
    0x920A to PreviewExifTag.FOCAL_LENGTH,
)

class PreviewExifRationalValues internal constructor(
    val complete: Boolean,
    private val attributes: Map<PreviewExifTag, String?>,
) {
    /** Even a missing/invalid raw tag replaces an ImageIO synthesized decimal. */
    fun applyTo(values: NativePreviewExifValues) {
        if (complete) rationalTags.values.forEach { values.set(it, attributes[it]) }
    }
    fun value(tag: PreviewExifTag): String? = attributes[tag]
}

/** Small supplement for the five numeric preview tags, not a second image/EXIF decoder.
 * Types and Float-vs-Double attribute representation follow AndroidX ExifInterface 1.3.7.
 * No JPEG entropy/image scan, MakerNote traversal or full-file allocation is needed.
 */
object PreviewExifRationalReader {
    const val maximumReadBytes = 512 * 1024
    private class Invalid : Exception()

    fun read(source: PreviewExifByteSource, size: Long): PreviewExifRationalValues {
        var budget = 8 * 1024 * 1024
        var requests = 0
        val values = mutableMapOf<PreviewExifTag, String?>()
        fun bytes(offset: Long, count: Int, end: Long = size): ByteArray {
            if (count < 0 || count > maximumReadBytes || offset < 0 || offset > end || count.toLong() > end - offset ||
                end > size || ++requests > 4096 || count > budget) throw Invalid()
            budget -= count
            if (count == 0) return ByteArray(0)
            val result = source.read(offset, count) ?: throw Invalid()
            if (result.size != count) throw Invalid()
            return result
        }
        try {
            val signature = bytes(0, 2)
            var base = 0L; var end = size
            if (signature[0] == 0xFF.toByte() && signature[1] == 0xD8.toByte()) {
                var offset = 2L
                var found = false
                while (offset < size) {
                    if (bytes(offset++, 1)[0] != 0xFF.toByte()) throw Invalid()
                    var marker = bytes(offset++, 1)[0].toInt() and 255
                    while (marker == 255) marker = bytes(offset++, 1)[0].toInt() and 255
                    if (marker == 0xDA || marker == 0xD9) break
                    if (marker == 0x01 || marker in 0xD0..0xD7) continue
                    val lengthBytes = bytes(offset, 2)
                    val length = ((lengthBytes[0].toInt() and 255) shl 8) or (lengthBytes[1].toInt() and 255)
                    if (length < 2 || length.toLong() > size - offset) throw Invalid()
                    if (marker == 0xE1 && length >= 8 && bytes(offset + 2, 6).contentEquals(byteArrayOf(69, 120, 105, 102, 0, 0))) {
                        base = offset + 8; end = offset + length; found = true; break
                    }
                    offset += length
                }
                if (!found) return PreviewExifRationalValues(true, emptyMap())
            }
            val header = bytes(base, 8, end)
            val little = when {
                header[0] == 73.toByte() && header[1] == 73.toByte() -> true
                header[0] == 77.toByte() && header[1] == 77.toByte() -> false
                else -> throw Invalid()
            }
            fun u16(b: ByteArray, at: Int): Int {
                val a = b[at].toInt() and 255; val c = b[at + 1].toInt() and 255
                return if (little) a or (c shl 8) else (a shl 8) or c
            }
            fun u32(b: ByteArray, at: Int): Long {
                var value = 0L
                repeat(4) { i -> value = value or ((b[at + i].toLong() and 255) shl ((if (little) i else 3 - i) * 8)) }
                return value
            }
            if (u16(header, 2) != 42) throw Invalid()
            val visited = mutableSetOf<Long>()
            fun absolute(relative: Long): Long {
                if (relative < 0 || relative > end - base) throw Invalid()
                return base + relative
            }
            // Out-of-line TIFF data offsets are readInt in ExifInterface, unlike pointer values.
            fun dataOffset(b: ByteArray, at: Int): Long = absolute(u32(b, at).toInt().toLong())
            fun ifd(relative: Long, exif: Boolean, depth: Int) {
                if (relative <= 0 || !visited.add(relative)) return
                if (depth > 64 || visited.size > 256) throw Invalid()
                val start = absolute(relative)
                val count = u16(bytes(start, 2, end), 0).toShort().toInt()
                if (count <= 0) return // Android reads this field as signed short, including zero.
                val entries = bytes(start + 2, count * 12 + 4, end)
                repeat(count) { index ->
                    val at = index * 12
                    val tag = u16(entries, at); val encodedType = u16(entries, at + 2)
                    val components = u32(entries, at + 4)
                    // TIFF image groups may point to EXIF or another image group; EXIF itself
                    // has no EXIF/sub-IFD pointer tag. Traverse at the original encounter order.
                    if (!exif && tag in setOf(0x8769, 0x014A) && encodedType in setOf(3, 4, 7)) {
                        val unit = if (encodedType == 3) 2 else 4
                        if (components > Int.MAX_VALUE / unit) return@repeat
                        val pointer = if (components * unit <= 4) {
                            if (unit == 2) u16(entries, at + 8).toLong() else u32(entries, at + 8)
                        } else {
                            val body = bytes(dataOffset(entries, at + 8), unit, end)
                            if (unit == 2) u16(body, 0).toLong() else u32(body, 0)
                        }
                        if (pointer > 0 && pointer < end - base) ifd(pointer, tag == 0x8769, depth + 1)
                    }
                    val target = if (exif) rationalTags[tag] else null
                    if (target == null) return@repeat
                    val expected = if (target == PreviewExifTag.EXPOSURE_BIAS_VALUE) 10 else 5
                    if (encodedType != expected && encodedType != 7) return@repeat
                    if (components > Int.MAX_VALUE / 8) return@repeat
                    if (components != 1L) {
                        // An empty/multi-value attribute cannot parse as the preview's one Float.
                        if (components > 0) {
                            val offset = dataOffset(entries, at + 8)
                            if (components * 8 > end - offset) throw Invalid()
                        }
                        values[target] = null
                        return@repeat
                    }
                    val data = bytes(dataOffset(entries, at + 8), 8, end)
                    var numerator = u32(data, 0); var denominator = u32(data, 4)
                    if (expected == 10) { numerator = numerator.toInt().toLong(); denominator = denominator.toInt().toLong() }
                    // ExifInterface.Rational normalizes a zero denominator before getAttribute.
                    if (denominator == 0L) { numerator = 0; denominator = 1 }
                    values[target] = if (target == PreviewExifTag.F_NUMBER || target == PreviewExifTag.EXPOSURE_TIME) {
                        (numerator.toDouble() / denominator.toDouble()).toString()
                    } else "$numerator/$denominator"
                }
                val next = u32(entries, count * 12).toInt().toLong()
                if (next > 0 && next < end - base) ifd(next, false, depth + 1)
            }
            val first = u32(header, 4)
            if (first < 8) throw Invalid()
            ifd(first, false, 0)
            return PreviewExifRationalValues(true, values.toMap())
        } catch (_: Invalid) {
            return PreviewExifRationalValues(false, emptyMap())
        }
    }
}
