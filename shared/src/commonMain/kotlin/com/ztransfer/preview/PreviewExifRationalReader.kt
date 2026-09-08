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
    val partial: Boolean = false,
    private val supplement: PreviewExifSupplement? = null,
    private val littleEndian: Boolean = true,
) {
    /** The five rational tags clear synthesized decimals; optional extras replace observed tags only. */
    fun applyTo(values: NativePreviewExifValues) {
        if (complete || partial) rationalTags.values.forEach { values.set(it, attributes[it]) }
        if (complete || partial) supplement?.applyTo(values, littleEndian)
    }
    fun value(tag: PreviewExifTag): String? = attributes[tag]
}

/** Bounded preview attributes, not a second image/MakerNote decoder. Existing numeric-only
 * entry points retain their five-tag contract; Native metadata opts into text/ISO/GPS fields.
 * Types and Float-vs-Double attribute representation follow AndroidX ExifInterface 1.3.7.
 * No JPEG entropy/image scan, MakerNote traversal or full-file allocation is needed.
 */
object PreviewExifRationalReader {
    const val maximumReadBytes = 512 * 1024
    private class Invalid : Exception()
    private class Unavailable : Exception()
    private enum class DirectoryKind { TIFF, EXIF, GPS, OTHER }

    fun read(source: PreviewExifByteSource, size: Long): PreviewExifRationalValues = readInternal(source, size, false)

    /** Bounded camera headers may end after useful attributes. Never use for local file I/O. */
    fun readHeader(source: PreviewExifByteSource, size: Long): PreviewExifRationalValues = readInternal(source, size, true)

    /** Native preview metadata uses the same directory walk and limits, adding non-rational fields. */
    fun readMetadata(source: PreviewExifByteSource, size: Long, header: Boolean): PreviewExifRationalValues =
        readInternal(source, size, header, captureMetadata = true)

    private fun readInternal(source: PreviewExifByteSource, size: Long, retainPartial: Boolean, captureMetadata: Boolean = false): PreviewExifRationalValues {
        var budget = 8 * 1024 * 1024
        var requests = 0
        val rawValues = mutableMapOf<PreviewExifTag, ByteArray?>()
        val supplement = if (captureMetadata) PreviewExifSupplement() else null
        fun bytes(offset: Long, count: Int, end: Long = size): ByteArray {
            if (count < 0 || count > maximumReadBytes || offset < 0 || offset > end || count.toLong() > end - offset || end > size) throw Invalid()
            if (++requests > 4096 || count > budget) throw Unavailable()
            budget -= count
            if (count == 0) return ByteArray(0)
            val result = source.read(offset, count) ?: throw Unavailable()
            if (result.size != count) throw Unavailable()
            return result
        }
        var little = true
        var recognized = false
        fun u16(b: ByteArray, at: Int): Int {
            val a = b[at].toInt() and 255; val c = b[at + 1].toInt() and 255
            return if (little) a or (c shl 8) else (a shl 8) or c
        }
        fun u32(b: ByteArray, at: Int): Long {
            var value = 0L
            repeat(4) { i -> value = value or ((b[at + i].toLong() and 255) shl ((if (little) i else 3 - i) * 8)) }
            return value
        }
        fun result(complete: Boolean, partial: Boolean = false): PreviewExifRationalValues {
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
            return PreviewExifRationalValues(complete, values, partial, supplement, little)
        }
        try {
            var base = 0L; var end = size
            // Android retains visited relative offsets and attribute bytes across JPEG APP1s.
            val visited = mutableSetOf<Long>()
            // Android getRawAttributes probes primary/preview/thumbnail JPEGs only when that
            // directory lacks an image dimension. MakerNote bytes are not arbitrary JPEG input.
            class ImageDirectory {
                var width = false
                var height = false
                var offset: Long? = null
                var length: Long? = null
            }
            val images = mutableListOf<ImageDirectory>()
            fun parseTiff(segmentBase: Long, segmentEnd: Long) {
                base = segmentBase; end = segmentEnd
                val order = bytes(base, 2, end)
                little = when {
                    order[0] == 73.toByte() && order[1] == 73.toByte() -> true
                    order[0] == 77.toByte() && order[1] == 77.toByte() -> false
                    else -> throw Invalid()
                }
                if (u16(bytes(base + 2, 2, end), 0) != 42) throw Invalid()
                fun absolute(relative: Long): Long {
                    if (relative < 0 || relative > end - base) throw Invalid()
                    return base + relative
                }
                // Out-of-line TIFF data offsets are readInt in ExifInterface, unlike pointer values.
                fun dataOffset(b: ByteArray, at: Int): Long = absolute(u32(b, at).toInt().toLong())
                fun ifd(relative: Long, kind: DirectoryKind, depth: Int, root: Boolean = false) {
                    if (relative <= 0 || (!visited.add(relative) && !root)) return
                    if (depth > 64 || visited.size > 256) throw Unavailable()
                    val start = absolute(relative)
                    val count = u16(bytes(start, 2, end), 0).toShort().toInt()
                    if (count <= 0) return // Android reads this field as signed short, including zero.
                    val image = if (captureMetadata && kind == DirectoryKind.TIFF)
                        ImageDirectory().also(images::add) else null
                    repeat(count) { index ->
                        // Read in encounter order: a truncated later entry must not erase earlier values.
                        val entries = bytes(start + 2 + index * 12L, 12, end)
                        val at = 0
                        val tag = u16(entries, at); val encodedType = u16(entries, at + 2)
                        val components = u32(entries, at + 4)
                        if (image != null && components == 1L && encodedType in setOf(3, 4, 7)) {
                            val scalar = if (encodedType == 3) u16(entries, 8).toLong() else u32(entries, 8)
                            when (tag) {
                                0x0100 -> image.width = true
                                0x0101 -> image.height = true
                                0x0201 -> image.offset = scalar
                                0x0202 -> image.length = scalar
                            }
                        }
                        // Even non-numeric GPS/interop visits matter: a later EXIF pointer to an
                        // already visited relative offset must not reinterpret that directory.
                        val pointerKind = when {
                            kind == DirectoryKind.TIFF && tag == 0x8769 -> DirectoryKind.EXIF
                            kind == DirectoryKind.TIFF && tag == 0x014A -> DirectoryKind.TIFF
                            kind == DirectoryKind.TIFF && tag == 0x8825 -> if (captureMetadata) DirectoryKind.GPS else DirectoryKind.OTHER
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
                        // Reuse this exact visited-offset and APP1 boundary policy. Do not ask
                        // ImageIO to select an unrelated embedded thumbnail's metadata.
                        val metadataType = supplement?.expectedType(tag, kind.name)
                        if (metadataType != null && (encodedType == metadataType || encodedType == 7)) {
                            val width = when (metadataType) { 3 -> 2; 5 -> 8; else -> 1 }
                            if (components <= Int.MAX_VALUE / width) {
                                val length = (components * width).toInt()
                                val body = if (length <= 4) entries.copyOfRange(8, 8 + length)
                                    else bytes(dataOffset(entries, 8), length, end)
                                supplement?.accept(tag, metadataType, body, if (kind == DirectoryKind.TIFF && !root) 1 else 0)
                            }
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
                    val next = u32(bytes(start + 2 + count * 12L, 4, end), 0).toInt().toLong()
                    if (next > 0 && next < end - base) ifd(next, DirectoryKind.TIFF, depth + 1)
                }
                val first = u32(bytes(base + 4, 4, end), 0).toInt().toLong()
                if (first < 8) throw Invalid()
                // Each APP1 root is read even if its relative offset was already seen.
                ifd(first, DirectoryKind.TIFF, 0, root = true)
            }
            fun parseJpeg(start: Long, limit: Long) {
                if (start != 0L && !bytes(start, 2, limit).contentEquals(byteArrayOf(-1, -40))) throw Invalid()
                var offset = start + 2
                while (offset < limit) {
                    if (bytes(offset++, 1, limit)[0] != 0xFF.toByte()) throw Invalid()
                    var marker = bytes(offset++, 1, limit)[0].toInt() and 255
                    while (marker == 255) marker = bytes(offset++, 1, limit)[0].toInt() and 255
                    if (marker == 0xDA || marker == 0xD9) break
                    if (marker == 0x01 || marker in 0xD0..0xD7) continue
                    val lengthBytes = bytes(offset, 2, limit)
                    val length = ((lengthBytes[0].toInt() and 255) shl 8) or (lengthBytes[1].toInt() and 255)
                    if (length < 2 || length.toLong() > limit - offset) throw Invalid()
                    if (marker == 0xE1 && length >= 8 && bytes(offset + 2, 6, limit).contentEquals(byteArrayOf(69, 120, 105, 102, 0, 0))) {
                        parseTiff(offset + 8, offset + length)
                    }
                    offset += length
                }
            }
            val signature = bytes(0, 2)
            recognized = signature.contentEquals(byteArrayOf(-1, -40)) ||
                signature.contentEquals(byteArrayOf(73, 73)) || signature.contentEquals(byteArrayOf(77, 77))
            if (signature[0] == 0xFF.toByte() && signature[1] == 0xD8.toByte()) {
                parseJpeg(0, size)
            } else {
                parseTiff(0, size)
                if (captureMetadata) {
                    for (image in images.toList().take(3)) {
                        if (image.width && image.height) continue
                        val offset = image.offset ?: continue
                        if (image.length == null) continue
                        // Pinned AndroidX 1.3.7 reads the offset attribute twice here: the second
                        // value is its buffer length. Lock this quirk, do not silently fix it.
                        if (offset <= 0 || offset > 8 * 1024 * 1024 || offset > size - offset) continue
                        parseJpeg(offset, offset + offset)
                    }
                }
            }
            // ExifInterface stores bytes, not normalized numbers; getAttribute uses the final
            // EXIF byte order even for attributes retained from a preceding APP1 segment.
            return result(complete = true)
        } catch (_: Unavailable) {
            return PreviewExifRationalValues(false, emptyMap())
        } catch (_: Invalid) {
            return if (retainPartial && recognized) result(complete = false, partial = true)
                else PreviewExifRationalValues(false, emptyMap())
        }
    }
}
