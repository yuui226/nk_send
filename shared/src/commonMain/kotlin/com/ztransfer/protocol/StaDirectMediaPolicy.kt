package com.ztransfer.protocol

private const val STA_DIRECT_MAX_EMBEDDED_PREVIEW_BYTES = 16 * 1024 * 1024

fun staDirectObjectExtension(header: ByteArray): String = when {
    header.size >= 2 && header[0] == 0xFF.toByte() && header[1] == 0xD8.toByte() -> ".jpg"
    header.size >= 4 &&
        ((header[0] == 'I'.code.toByte() && header[1] == 'I'.code.toByte() &&
            header[2] == 0x2A.toByte() && header[3] == 0.toByte()) ||
            (header[0] == 'M'.code.toByte() && header[1] == 'M'.code.toByte() &&
                header[2] == 0.toByte() && header[3] == 0x2A.toByte())) -> ".nef"
    header.size >= 12 && header.copyOfRange(4, 8).contentEquals("ftyp".encodeToByteArray()) -> {
        val brand = header.copyOfRange(8, 12).decodeToString()
        if (brand == "qt  ") ".mov" else ".mp4"
    }
    else -> ".bin"
}


fun jpegExifSegmentRange(header: ByteArray): IntRange? {
    if (header.size < 10 || header[0] != 0xFF.toByte() || header[1] != 0xD8.toByte()) return null
    var offset = 2
    while (offset + 4 <= header.size) {
        val markerStart = offset
        if (header[offset] != 0xFF.toByte()) return null
        while (offset < header.size && header[offset] == 0xFF.toByte()) offset++
        if (offset >= header.size) return null
        val marker = header[offset].toInt() and 0xFF
        offset++
        if (marker == 0xD9 || marker == 0xDA) return null
        if (marker == 0x01 || marker in 0xD0..0xD7) continue
        if (offset + 2 > header.size) return null
        val segmentLength =
            ((header[offset].toInt() and 0xFF) shl 8) or (header[offset + 1].toInt() and 0xFF)
        if (segmentLength < 2) return null
        val segmentEnd = offset + segmentLength
        if (segmentEnd > header.size) return null
        val payloadOffset = offset + 2
        val isExif = marker == 0xE1 && payloadOffset + 6 <= segmentEnd &&
            header[payloadOffset] == 'E'.code.toByte() &&
            header[payloadOffset + 1] == 'x'.code.toByte() &&
            header[payloadOffset + 2] == 'i'.code.toByte() &&
            header[payloadOffset + 3] == 'f'.code.toByte() &&
            header[payloadOffset + 4] == 0.toByte() &&
            header[payloadOffset + 5] == 0.toByte()
        if (isExif) {
            return markerStart until segmentEnd
        }
        offset = segmentEnd
    }
    return null
}

fun jpegExifEnvelope(header: ByteArray): ByteArray? {
    val segment = jpegExifSegmentRange(header) ?: return null
    val segmentBytes = segment.last - segment.first + 1
    return ByteArray(2 + segmentBytes + 2).also { envelope ->
        envelope[0] = 0xFF.toByte()
        envelope[1] = 0xD8.toByte()
        header.copyInto(
            envelope,
            destinationOffset = 2,
            startIndex = segment.first,
            endIndex = segment.last + 1,
        )
        envelope[envelope.lastIndex - 1] = 0xFF.toByte()
        envelope[envelope.lastIndex] = 0xD9.toByte()
    }
}

fun needsStaDirectJpegHeaderExpansion(
    prefix: ByteArray,
    maximumHeaderBytes: Int,
): Boolean = prefix.size < maximumHeaderBytes && jpegExifSegmentRange(prefix) == null


data class JpegMpfPreviewReference(
    val offset: Long,
    val length: Int,
    val imageType: Int,
)

/**
 * Parses the MP Index IFD in a JPEG APP2 `MPF\0` segment. MP image offsets are relative to the
 * TIFF byte-order field at the start of the MP header; only independently stored large-thumbnail
 * JPEGs are returned. The primary image at offset 0 is deliberately excluded.
 */
fun parseJpegMpfPreviews(
    bytes: ByteArray,
    objectSize: Long = Long.MAX_VALUE,
): List<JpegMpfPreviewReference> {
    data class MpfSegment(val tiffBase: Int, val end: Int)

    fun findMpfSegment(): MpfSegment? {
        if (bytes.size < 4 || bytes[0] != 0xFF.toByte() || bytes[1] != 0xD8.toByte()) return null
        var offset = 2
        while (offset + 1 < bytes.size) {
            while (offset < bytes.size && bytes[offset] == 0xFF.toByte()) offset++
            if (offset >= bytes.size) return null
            val marker = bytes[offset].toInt() and 0xFF
            offset++
            if (marker == 0xD9 || marker == 0xDA) return null
            if (marker == 0x01 || marker in 0xD0..0xD7) continue
            if (offset + 2 > bytes.size) return null
            val segmentLength = ((bytes[offset].toInt() and 0xFF) shl 8) or
                (bytes[offset + 1].toInt() and 0xFF)
            if (segmentLength < 2 || offset.toLong() + segmentLength > bytes.size.toLong()) {
                return null
            }
            val payload = offset + 2
            if (marker == 0xE2 && segmentLength >= 14 &&
                bytes[payload] == 'M'.code.toByte() &&
                bytes[payload + 1] == 'P'.code.toByte() &&
                bytes[payload + 2] == 'F'.code.toByte() &&
                bytes[payload + 3] == 0.toByte()
            ) {
                return MpfSegment(tiffBase = payload + 4, end = offset + segmentLength)
            }
            offset += segmentLength
        }
        return null
    }

    val segment = findMpfSegment() ?: return emptyList()
    val littleEndian = when {
        bytes[segment.tiffBase] == 'I'.code.toByte() &&
            bytes[segment.tiffBase + 1] == 'I'.code.toByte() -> true
        bytes[segment.tiffBase] == 'M'.code.toByte() &&
            bytes[segment.tiffBase + 1] == 'M'.code.toByte() -> false
        else -> return emptyList()
    }

    fun u16(offset: Int): Int? {
        if (offset < segment.tiffBase || offset + 2 > segment.end) return null
        val a = bytes[offset].toInt() and 0xFF
        val b = bytes[offset + 1].toInt() and 0xFF
        return if (littleEndian) a or (b shl 8) else (a shl 8) or b
    }

    fun u32(offset: Int): Long? {
        if (offset < segment.tiffBase || offset + 4 > segment.end) return null
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

    if (u16(segment.tiffBase + 2) != 42) return emptyList()
    val ifdOffset = u32(segment.tiffBase + 4) ?: return emptyList()
    val ifdStartLong = segment.tiffBase.toLong() + ifdOffset
    if (ifdStartLong !in segment.tiffBase.toLong() until segment.end.toLong()) return emptyList()
    val ifdStart = ifdStartLong.toInt()
    val entryCount = u16(ifdStart) ?: return emptyList()
    if (entryCount > 64 || ifdStart.toLong() + 2L + entryCount.toLong() * 12L > segment.end) {
        return emptyList()
    }

    var declaredImageCount: Int? = null
    var mpEntryOffset: Int? = null
    var mpEntryBytes = 0
    repeat(entryCount) { index ->
        val entry = ifdStart + 2 + index * 12
        val tag = u16(entry) ?: return@repeat
        val type = u16(entry + 2) ?: return@repeat
        val count = u32(entry + 4) ?: return@repeat
        when (tag) {
            0xB001 -> if (type == 4 && count == 1L) {
                declaredImageCount = u32(entry + 8)?.toInt()
            }
            0xB002 -> if (type == 7 && count in 16L..(16L * 64L) && count % 16L == 0L) {
                val relative = u32(entry + 8) ?: return@repeat
                val absolute = segment.tiffBase.toLong() + relative
                if (absolute >= segment.tiffBase && absolute + count <= segment.end) {
                    mpEntryOffset = absolute.toInt()
                    mpEntryBytes = count.toInt()
                }
            }
        }
    }

    val entriesStart = mpEntryOffset ?: return emptyList()
    val availableCount = mpEntryBytes / 16
    val imageCount = minOf(declaredImageCount ?: availableCount, availableCount, 64)
    val previews = ArrayList<JpegMpfPreviewReference>(imageCount)
    repeat(imageCount) { index ->
        val entry = entriesStart + index * 16
        val attributes = u32(entry) ?: return@repeat
        val length = u32(entry + 4) ?: return@repeat
        val relativeOffset = u32(entry + 8) ?: return@repeat
        val imageFormat = (attributes ushr 24) and 0x07
        val imageType = (attributes and 0x00FFFFFF).toInt()
        val absoluteOffset = segment.tiffBase.toLong() + relativeOffset
        if (imageFormat == 0L && imageType in 0x010001..0x010005 &&
            relativeOffset > 0L &&
            length in 4L..STA_DIRECT_MAX_EMBEDDED_PREVIEW_BYTES.toLong() &&
            absoluteOffset > 0L && absoluteOffset + length <= objectSize
        ) {
            previews += JpegMpfPreviewReference(
                offset = absoluteOffset,
                length = length.toInt(),
                imageType = imageType,
            )
        }
    }
    return previews.distinct().sortedWith(
        compareBy<JpegMpfPreviewReference> {
            when (it.imageType) {
                0x010002 -> 0 // exact FHD
                0x010003 -> 1 // 4K if FHD is absent
                0x010001 -> 2 // VGA is still better than the EXIF thumbnail
                else -> 3
            }
        }.thenBy(JpegMpfPreviewReference::length),
    )
}

/** Reads QuickTime/MP4 `mvhd.creation_time` (seconds since 1904-01-01, big-endian). */

data class StaDirectRawThumbnailProbePlan(
    val initialBytes: Int,
    val maximumBytes: Int,
)

fun staDirectRawThumbnailProbePlan(
    availableBytes: Long,
    previousThumbnailBytes: Int,
): StaDirectRawThumbnailProbePlan? {
    if (availableBytes <= 0L) return null
    val previous = previousThumbnailBytes.coerceAtLeast(0).toLong()
    val maximum = minOf(
        availableBytes,
        maxOf(192L * 1024, previous + 64L * 1024),
        Int.MAX_VALUE.toLong(),
    ).toInt()
    val initial = minOf(
        maximum.toLong(),
        maxOf(128L * 1024, previous + 16L * 1024),
    ).toInt()
    return StaDirectRawThumbnailProbePlan(initial, maximum)
}


private const val QUICKTIME_EPOCH_OFFSET_SECONDS = 2_082_844_800L

fun staDirectVideoCaptureSeconds(bytes: ByteArray): Long? {
    var index = 0
    while (index + 12 <= bytes.size) {
        if (bytes[index] == 'm'.code.toByte() &&
            bytes[index + 1] == 'v'.code.toByte() &&
            bytes[index + 2] == 'h'.code.toByte() &&
            bytes[index + 3] == 'd'.code.toByte()
        ) {
            val version = bytes[index + 4].toInt() and 0xFF
            val creationOffset = index + 8
            val byteCount = if (version == 0) 4 else if (version == 1) 8 else return null
            if (creationOffset + byteCount > bytes.size) return null
            var secondsSince1904 = 0L
            repeat(byteCount) { offset ->
                secondsSince1904 = (secondsSince1904 shl 8) or
                    (bytes[creationOffset + offset].toLong() and 0xFF)
            }
            val unixSeconds = secondsSince1904 - QUICKTIME_EPOCH_OFFSET_SECONDS
            if (unixSeconds <= 0L) return null
            return unixSeconds
        }
        index++
    }
    return null
}
