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
    private enum class DirectoryKind { TIFF, EXIF, OTHER }

    fun read(source: PreviewExifByteSource, size: Long): PreviewExifRationalValues {
        var budget = 8 * 1024 * 1024
        var requests = 0
        val rawValues = mutableMapOf<PreviewExifTag, ByteArray?>()
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
            var base = 0L; var end = size
            var little = true
            // Android retains visited relative offsets and attribute bytes across JPEG APP1s.
            val visited = mutableSetOf<Long>()
            fun u16(b: ByteArray, at: Int): Int {
                val a = b[at].toInt() and 255; val c = b[at + 1].toInt() and 255
                return if (little) a or (c shl 8) else (a shl 8) or c
            }
            fun u32(b: ByteArray, at: Int): Long {
                var value = 0L
                repeat(4) { i -> value = value or ((b[at + i].toLong() and 255) shl ((if (little) i else 3 - i) * 8)) }
                return value
            }
            fun parseTiff(segmentBase: Long, segmentEnd: Long) {
                base = segmentBase; end = segmentEnd
                val header = bytes(base, 8, end)
                little = when {
                    header[0] == 73.toByte() && header[1] == 73.toByte() -> true
                    header[0] == 77.toByte() && header[1] == 77.toByte() -> false
                    else -> throw Invalid()
                }
                if (u16(header, 2) != 42) throw Invalid()
                fun absolute(relative: Long): Long {
                    if (relative < 0 || relative > end - base) throw Invalid()
                    return base + relative
                }
                // Out-of-line TIFF data offsets are readInt in ExifInterface, unlike pointer values.
                fun dataOffset(b: ByteArray, at: Int): Long = absolute(u32(b, at).toInt().toLong())
                fun ifd(relative: Long, kind: DirectoryKind, depth: Int, root: Boolean = false) {
                    if (relative <= 0 || (!visited.add(relative) && !root)) return
                    if (depth > 64 || visited.size > 256) throw Invalid()
                    val start = absolute(relative)
                    val count = u16(bytes(start, 2, end), 0).toShort().toInt()
                    if (count <= 0) return // Android reads this field as signed short, including zero.
                    val entries = bytes(start + 2, count * 12 + 4, end)
                    repeat(count) { index ->
                        val at = index * 12
                        val tag = u16(entries, at); val encodedType = u16(entries, at + 2)
                        val components = u32(entries, at + 4)
                        // Even non-numeric GPS/interop visits matter: a later EXIF pointer to an
                        // already visited relative offset must not reinterpret that directory.
                        val pointerKind = when {
                            kind == DirectoryKind.TIFF && tag == 0x8769 -> DirectoryKind.EXIF
                            kind == DirectoryKind.TIFF && tag == 0x014A -> DirectoryKind.TIFF
                            kind == DirectoryKind.TIFF && tag == 0x8825 -> DirectoryKind.OTHER
                            kind == DirectoryKind.EXIF && tag == 0xA005 -> DirectoryKind.OTHER
                            else -> null
                        }
                        if (pointerKind != null && encodedType in setOf(3, 4, 7)) {
                            val unit = if (encodedType == 3) 2 else 4
                            if (components > Int.MAX_VALUE / unit) return@repeat
                            val pointer = if (components * unit <= 4) {
                                if (unit == 2) u16(entries, at + 8).toLong() else u32(entries, at + 8)
                            } else {
                                val body = bytes(dataOffset(entries, at + 8), unit, end)
                                if (unit == 2) u16(body, 0).toLong() else u32(body, 0)
                            }
                            if (pointer > 0 && pointer < end - base) ifd(pointer, pointerKind, depth + 1)
                        }
                        val target = if (kind == DirectoryKind.EXIF) rationalTags[tag] else null
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
                            rawValues[target] = null
                            return@repeat
                        }
                        rawValues[target] = bytes(dataOffset(entries, at + 8), 8, end)
                    }
                    val next = u32(entries, count * 12).toInt().toLong()
                    if (next > 0 && next < end - base) ifd(next, DirectoryKind.TIFF, depth + 1)
                }
                val first = u32(header, 4).toInt().toLong()
                if (first < 8) throw Invalid()
                // Each APP1 root is read even if its relative offset was already seen.
                ifd(first, DirectoryKind.TIFF, 0, root = true)
            }
            val signature = bytes(0, 2)
            if (signature[0] == 0xFF.toByte() && signature[1] == 0xD8.toByte()) {
                var offset = 2L
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
                        parseTiff(offset + 8, offset + length)
                    }
                    offset += length
                }
            } else {
                parseTiff(0, size)
            }
            // ExifInterface stores bytes, not normalized numbers; getAttribute uses the final
            // EXIF byte order even for attributes retained from a preceding APP1 segment.
            val values = rawValues.mapValues { (target, data) ->
                if (data == null) return@mapValues null
                var numerator = u32(data, 0); var denominator = u32(data, 4)
                if (target == PreviewExifTag.EXPOSURE_BIAS_VALUE) {
                    numerator = numerator.toInt().toLong(); denominator = denominator.toInt().toLong()
                }
                if (denominator == 0L) { numerator = 0; denominator = 1 }
                if (target == PreviewExifTag.F_NUMBER || target == PreviewExifTag.EXPOSURE_TIME) {
                    (numerator.toDouble() / denominator.toDouble()).toString()
                } else "$numerator/$denominator"
            }
            return PreviewExifRationalValues(true, values)
        } catch (_: Invalid) {
            return PreviewExifRationalValues(false, emptyMap())
        }
    }
}
