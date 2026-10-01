package com.ztransfer.viewmodel

/** Structural inspection only; an absent field is not evidence of a truncated header. */
internal enum class JpegMetadataHeader { EXIF_COMPLETE, NO_EXIF, INCOMPLETE, INVALID }

internal fun inspectJpegMetadataHeader(bytes: ByteArray): JpegMetadataHeader {
    fun byte(index: Int) = bytes[index].toInt() and 255
    if (bytes.size < 2) return JpegMetadataHeader.INCOMPLETE
    if (byte(0) != 255 || byte(1) != 0xd8) return JpegMetadataHeader.INVALID
    var offset = 2
    while (offset < bytes.size) {
        if (byte(offset++) != 255) return JpegMetadataHeader.INVALID
        while (offset < bytes.size && byte(offset) == 255) offset++
        if (offset >= bytes.size) return JpegMetadataHeader.INCOMPLETE
        val marker = byte(offset++)
        if (marker == 0xda || marker == 0xd9) return JpegMetadataHeader.NO_EXIF
        if (marker == 0x01 || marker in 0xd0..0xd7) continue
        if (marker == 0 || marker == 0xd8) return JpegMetadataHeader.INVALID
        if (offset + 2 > bytes.size) return JpegMetadataHeader.INCOMPLETE
        val length = (byte(offset) shl 8) or byte(offset + 1)
        if (length < 2) return JpegMetadataHeader.INVALID
        if (length > bytes.size - offset) return JpegMetadataHeader.INCOMPLETE
        if (marker == 0xe1 && length >= 8 &&
            byte(offset + 2) == 69 && byte(offset + 3) == 120 &&
            byte(offset + 4) == 105 && byte(offset + 5) == 102 &&
            byte(offset + 6) == 0 && byte(offset + 7) == 0
        ) return JpegMetadataHeader.EXIF_COMPLETE
        offset += length
    }
    return JpegMetadataHeader.INCOMPLETE
}
