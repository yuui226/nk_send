package com.ztransfer.protocol

/**
 * Reads Nikon MakerNote tag 0x00B8 (FileInfo) from a bounded JPEG/NEF prefix. FileInfo contains the
 * DCF directory and four-digit file number even when paired STA denies ObjectInfo. The parser does
 * not guess the camera-configurable three-character filename prefix.
 */
fun nikonMakerFileInfo(bytes: ByteArray): NikonMakerFileInfo? {
    fun tiffStart(): Int? {
        if (bytes.size >= 8 &&
            ((bytes[0] == 'I'.code.toByte() && bytes[1] == 'I'.code.toByte()) ||
                (bytes[0] == 'M'.code.toByte() && bytes[1] == 'M'.code.toByte()))
        ) {
            return 0
        }
        if (bytes.size < 12 || bytes[0] != 0xFF.toByte() || bytes[1] != 0xD8.toByte()) return null
        var offset = 2
        while (offset + 4 <= bytes.size) {
            if (bytes[offset] != 0xFF.toByte()) return null
            while (offset < bytes.size && bytes[offset] == 0xFF.toByte()) offset++
            if (offset >= bytes.size) return null
            val marker = bytes[offset].toInt() and 0xFF
            offset++
            if (marker == 0xD9 || marker == 0xDA) return null
            if (marker == 0x01 || marker in 0xD0..0xD7) continue
            if (offset + 2 > bytes.size) return null
            val length = ((bytes[offset].toInt() and 0xFF) shl 8) or
                (bytes[offset + 1].toInt() and 0xFF)
            if (length < 2 || offset + length > bytes.size) return null
            val payload = offset + 2
            if (marker == 0xE1 && payload + 14 <= offset + length &&
                bytes.copyOfRange(payload, payload + 6).contentEquals(
                    byteArrayOf(
                        'E'.code.toByte(),
                        'x'.code.toByte(),
                        'i'.code.toByte(),
                        'f'.code.toByte(),
                        0,
                        0,
                    ),
                )
            ) {
                return payload + 6
            }
            offset += length
        }
        return null
    }

    data class Entry(val type: Int, val count: Long, val value: Long, val inlineOffset: Int)

    fun byteOrder(base: Int): Boolean? = when {
        base + 8 > bytes.size -> null
        bytes[base] == 'I'.code.toByte() && bytes[base + 1] == 'I'.code.toByte() -> true
        bytes[base] == 'M'.code.toByte() && bytes[base + 1] == 'M'.code.toByte() -> false
        else -> null
    }

    fun u16(offset: Int, littleEndian: Boolean): Int? {
        if (offset < 0 || offset + 2 > bytes.size) return null
        val a = bytes[offset].toInt() and 0xFF
        val b = bytes[offset + 1].toInt() and 0xFF
        return if (littleEndian) a or (b shl 8) else (a shl 8) or b
    }

    fun u32(offset: Int, littleEndian: Boolean): Long? {
        if (offset < 0 || offset + 4 > bytes.size) return null
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

    fun findEntry(ifdOffset: Int, littleEndian: Boolean, tag: Int): Entry? {
        if (ifdOffset < 0 || ifdOffset.toLong() + 2L > bytes.size.toLong()) return null
        val count = u16(ifdOffset, littleEndian) ?: return null
        val entriesEnd = ifdOffset.toLong() + 2L + count.toLong() * 12L + 4L
        if (count > 512 || entriesEnd > bytes.size.toLong()) return null
        repeat(count) { index ->
            val entry = ifdOffset + 2 + index * 12
            if (u16(entry, littleEndian) == tag) {
                return Entry(
                    type = u16(entry + 2, littleEndian) ?: return null,
                    count = u32(entry + 4, littleEndian) ?: return null,
                    value = u32(entry + 8, littleEndian) ?: return null,
                    inlineOffset = entry + 8,
                )
            }
        }
        return null
    }

    fun entryDataOffset(base: Int, entry: Entry, requiredBytes: Int): Int? {
        if (requiredBytes < 0) return null
        val unitSize = when (entry.type) {
            1, 2, 7 -> 1
            3 -> 2
            4, 9 -> 4
            5, 10 -> 8
            else -> return null
        }
        if (entry.count <= 0 || entry.count > Int.MAX_VALUE.toLong() / unitSize) return null
        val declaredBytes = entry.count * unitSize
        if (declaredBytes < requiredBytes.toLong()) return null
        val offset = if (declaredBytes <= 4) {
            entry.inlineOffset
        } else {
            val absolute = base.toLong() + entry.value
            absolute.takeIf { it in 0L..Int.MAX_VALUE.toLong() }?.toInt() ?: return null
        }
        return offset.takeIf {
            it >= 0 && it.toLong() + requiredBytes.toLong() <= bytes.size.toLong()
        }
    }

    fun relativeOffset(base: Int, relative: Long): Int? {
        val absolute = base.toLong() + relative
        return absolute.takeIf { it in 0L until bytes.size.toLong() }?.toInt()
    }

    val outerBase = tiffStart() ?: return null
    val outerLittle = byteOrder(outerBase) ?: return null
    if (u16(outerBase + 2, outerLittle) != 42) return null
    val ifd0 = relativeOffset(outerBase, u32(outerBase + 4, outerLittle) ?: return null)
        ?: return null
    val exifPointer = findEntry(ifd0, outerLittle, 0x8769) ?: return null
    if (exifPointer.type != 4 || exifPointer.count != 1L) return null
    val exifIfd = relativeOffset(outerBase, exifPointer.value) ?: return null
    val makerEntry = findEntry(exifIfd, outerLittle, 0x927C) ?: return null
    val makerOffset = entryDataOffset(outerBase, makerEntry, requiredBytes = 18) ?: return null
    if (bytes[makerOffset] != 'N'.code.toByte() ||
        bytes[makerOffset + 1] != 'i'.code.toByte() ||
        bytes[makerOffset + 2] != 'k'.code.toByte() ||
        bytes[makerOffset + 3] != 'o'.code.toByte() ||
        bytes[makerOffset + 4] != 'n'.code.toByte() ||
        bytes[makerOffset + 5] != 0.toByte()
    ) {
        return null
    }

    val makerBase = makerOffset + 10
    val makerLittle = byteOrder(makerBase) ?: return null
    if (u16(makerBase + 2, makerLittle) != 42) return null
    val makerIfd = relativeOffset(makerBase, u32(makerBase + 4, makerLittle) ?: return null)
        ?: return null
    val fileInfoEntry = findEntry(makerIfd, makerLittle, 0x00B8) ?: return null
    val fileInfo = entryDataOffset(makerBase, fileInfoEntry, requiredBytes = 10) ?: return null

    fun candidate(littleEndian: Boolean): NikonMakerFileInfo? {
        val directory = u16(fileInfo + 6, littleEndian) ?: return null
        val file = u16(fileInfo + 8, littleEndian) ?: return null
        return NikonMakerFileInfo(directory, file).takeIf {
            it.directoryNumber in 99..999 && it.fileNumber in 0..9999
        }
    }
    val little = candidate(true)
    val big = candidate(false)
    return when {
        little != null && big == null -> little
        big != null && little == null -> big
        makerLittle -> little ?: big
        else -> big ?: little
    }
}
