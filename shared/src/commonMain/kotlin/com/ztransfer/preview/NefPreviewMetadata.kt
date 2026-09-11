package com.ztransfer.preview

fun staDirectCaptureDate(exifDate: String?): String? {
    val digits = exifDate?.filter(Char::isDigit) ?: return null
    if (digits.length < 14) return null
    return digits.take(8) + "T" + digits.substring(8, 14)
}

data class NefPreviewReference(val offset: Long, val length: Int)

/** Returns the exact range of the largest complete JPEG embedded in a bounded RAW prefix. */
fun largestEmbeddedJpegRange(
    bytes: ByteArray,
    validLength: Int = bytes.size,
): NefPreviewReference? {
    val limit = validLength.coerceIn(0, bytes.size)
    var bestStart = -1
    var bestEnd = -1
    var start = -1
    var index = 0
    while (index + 1 < limit) {
        val first = bytes[index].toInt() and 0xFF
        val second = bytes[index + 1].toInt() and 0xFF
        if (first == 0xFF && second == 0xD8) {
            start = index
            index += 2
            continue
        }
        if (start >= 0 && first == 0xFF && second == 0xD9) {
            val end = index + 2
            if (end - start > bestEnd - bestStart) {
                bestStart = start
                bestEnd = end
            }
            start = -1
            index += 2
            continue
        }
        index++
    }
    return if (bestStart >= 0) {
        NefPreviewReference(bestStart.toLong(), bestEnd - bestStart)
    } else {
        null
    }
}

/** Returns the largest complete JPEG embedded in a bounded RAW prefix. */
fun largestEmbeddedJpeg(bytes: ByteArray): ByteArray? =
    largestEmbeddedJpegRange(bytes)?.let { range ->
        bytes.copyOfRange(range.offset.toInt(), range.offset.toInt() + range.length)
    }

data class NefHeaderMetadata(
    val captureDate: String?,
    val previews: List<NefPreviewReference>,
)

/** Parses the bounded TIFF directory tree and returns exact embedded-JPEG ranges. */
fun parseNefHeaderMetadata(
    bytes: ByteArray,
    validLength: Int = bytes.size,
): NefHeaderMetadata {
    val limit = validLength.coerceIn(0, bytes.size)
    if (limit < 8) return NefHeaderMetadata(null, emptyList())
    val littleEndian = when {
        bytes[0] == 'I'.code.toByte() && bytes[1] == 'I'.code.toByte() -> true
        bytes[0] == 'M'.code.toByte() && bytes[1] == 'M'.code.toByte() -> false
        else -> return NefHeaderMetadata(null, emptyList())
    }

    fun u16(offset: Int): Int? {
        if (offset < 0 || offset + 2 > limit) return null
        val first = bytes[offset].toInt() and 0xFF
        val second = bytes[offset + 1].toInt() and 0xFF
        return if (littleEndian) first or (second shl 8) else (first shl 8) or second
    }
    fun u32(offset: Int): Long? {
        if (offset < 0 || offset + 4 > limit) return null
        var value = 0L
        if (littleEndian) {
            repeat(4) { index ->
                value = value or ((bytes[offset + index].toLong() and 0xFF) shl (index * 8))
            }
        } else {
            repeat(4) { index ->
                value = (value shl 8) or (bytes[offset + index].toLong() and 0xFF)
            }
        }
        return value
    }
    if (u16(2) != 42) return NefHeaderMetadata(null, emptyList())

    val previews = ArrayList<NefPreviewReference>()
    val visited = HashSet<Int>()
    var bestDate: Pair<Int, String>? = null

    fun typeSize(type: Int): Int = when (type) {
        1, 2, 7 -> 1
        3 -> 2
        4, 9 -> 4
        5, 10 -> 8
        else -> 0
    }

    fun valueOffset(entryOffset: Int, type: Int, count: Long): Int? {
        val unit = typeSize(type)
        if (unit == 0 || count <= 0 || count > Int.MAX_VALUE / unit) return null
        val byteCount = count.toInt() * unit
        return if (byteCount <= 4) entryOffset + 8 else u32(entryOffset + 8)?.toInt()
    }

    fun numericValues(entryOffset: Int, type: Int, count: Long): List<Long> {
        if (type != 3 && type != 4) return emptyList()
        val start = valueOffset(entryOffset, type, count) ?: return emptyList()
        val step = if (type == 3) 2 else 4
        if (count > 64 || start < 0 || start + count * step > limit) return emptyList()
        return (0 until count.toInt()).mapNotNull { index ->
            if (type == 3) u16(start + index * step)?.toLong() else u32(start + index * step)
        }
    }

    fun asciiValue(entryOffset: Int, type: Int, count: Long): String? {
        if (type != 2 || count <= 1 || count > 128) return null
        val start = valueOffset(entryOffset, type, count) ?: return null
        val length = count.toInt()
        if (start < 0 || start + length > limit) return null
        return bytes.copyOfRange(start, start + length)
            .decodeRawAscii()
            .trimEnd('\u0000', ' ')
            .takeIf(String::isNotBlank)
    }

    fun parseIfd(ifdOffset: Int, depth: Int) {
        if (depth > 8 || ifdOffset < 8 || !visited.add(ifdOffset)) return
        val count = u16(ifdOffset) ?: return
        if (count > 512) return
        val entriesStart = ifdOffset + 2
        if (entriesStart + count * 12 + 4 > limit) return

        var jpegOffsets = emptyList<Long>()
        var jpegLengths = emptyList<Long>()
        var stripOffsets = emptyList<Long>()
        var stripLengths = emptyList<Long>()
        var compression: Long? = null
        val childIfds = ArrayList<Int>()

        repeat(count) { index ->
            val entry = entriesStart + index * 12
            val tag = u16(entry) ?: return@repeat
            val type = u16(entry + 2) ?: return@repeat
            val valueCount = u32(entry + 4) ?: return@repeat
            val values = numericValues(entry, type, valueCount)
            when (tag) {
                0x0103 -> compression = values.firstOrNull()
                0x0111 -> stripOffsets = values
                0x0117 -> stripLengths = values
                0x014A, 0x8769 -> values.mapTo(childIfds) { it.toInt() }
                0x0201 -> jpegOffsets = values
                0x0202 -> jpegLengths = values
                0x0132, 0x9003, 0x9004 -> {
                    val priority = when (tag) {
                        0x9003 -> 3
                        0x9004 -> 2
                        else -> 1
                    }
                    asciiValue(entry, type, valueCount)?.let { raw ->
                        staDirectCaptureDate(raw)?.let { date ->
                            if (bestDate == null || priority > checkNotNull(bestDate).first) {
                                bestDate = priority to date
                            }
                        }
                    }
                }
            }
        }

        fun addRanges(offsets: List<Long>, lengths: List<Long>) {
            offsets.zip(lengths).forEach { (offset, length) ->
                if (offset > 0L && length in 4..STA_DIRECT_MAX_EMBEDDED_PREVIEW_BYTES.toLong()) {
                    previews += NefPreviewReference(offset, length.toInt())
                }
            }
        }
        addRanges(jpegOffsets, jpegLengths)
        if (compression == 6L) addRanges(stripOffsets, stripLengths)

        val nextIfdOffset = u32(entriesStart + count * 12)?.toInt() ?: 0
        if (nextIfdOffset > 0) childIfds += nextIfdOffset
        childIfds.forEach { child -> parseIfd(child, depth + 1) }
    }

    parseIfd(u32(4)?.toInt() ?: return NefHeaderMetadata(null, emptyList()), 0)
    return NefHeaderMetadata(
        captureDate = bestDate?.second,
        previews = previews.distinct().sortedByDescending(NefPreviewReference::length),
    )
}

private const val STA_DIRECT_MAX_EMBEDDED_PREVIEW_BYTES = 16 * 1024 * 1024

internal fun ByteArray.decodeRawAscii(): String = buildString(size) {
    for (byte in this@decodeRawAscii) {
        append(if (byte >= 0) byte.toInt().toChar() else '\uFFFD')
    }
}
