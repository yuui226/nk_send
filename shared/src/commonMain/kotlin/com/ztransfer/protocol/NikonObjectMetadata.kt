package com.ztransfer.protocol

private const val NIKON_OBJECT_METADATA_VERSION = 100
private const val NIKON_OBJECT_METADATA_HEADER_BYTES = 8
private const val NIKON_OBJECT_METADATA_RECORD_BYTES = 16
private const val NIKON_DCF_FILES_PER_DIRECTORY = 10_000L

private val NIKON_CAMERA_MEDIA_EXTENSIONS = setOf("jpg", "jpeg", "nef", "mov", "mp4")

data class NikonMakerFileInfo(
    val directoryNumber: Int,
    val fileNumber: Int,
)

data class NikonFileNumberAnchor(
    val handleSequence: Int,
    val directoryNumber: Int,
    val fileNumber: Int,
)

/**
 * Uses a MakerNote FileInfo record as the DCF numbering anchor for neighbouring paired-STA
 * objects. The media-kind byte in a handle is ignored; its low 24 bits are the file sequence.
 */
fun deriveNikonMakerFileInfo(
    anchor: NikonFileNumberAnchor,
    handle: Int,
): NikonMakerFileInfo? {
    val sequence = handle and 0x00FFFFFF
    val delta = sequence.toLong() - anchor.handleSequence.toLong()
    val absoluteFileNumber = anchor.fileNumber.toLong() + delta
    val directoryDelta = floorDiv(absoluteFileNumber, NIKON_DCF_FILES_PER_DIRECTORY)
    val fileNumber = floorMod(absoluteFileNumber, NIKON_DCF_FILES_PER_DIRECTORY).toInt()
    val directoryNumber = anchor.directoryNumber.toLong() + directoryDelta
    return NikonMakerFileInfo(directoryNumber.toInt(), fileNumber).takeIf {
        directoryNumber in 99L..999L
    }
}

fun nikonDefaultCameraFileName(
    fileInfo: NikonMakerFileInfo,
    extension: String,
): String? {
    val normalizedExtension = extension.removePrefix(".").uppercase()
    if (normalizedExtension.lowercase() !in NIKON_CAMERA_MEDIA_EXTENSIONS) return null
    return "DSC_${fileInfo.fileNumber.zeroPadded(4)}.$normalizedExtension"
}

/**
 * Parses Nikon GetObjectsMetadata(0x9434) capture dates. The payload length is deliberately exact:
 * an unknown firmware layout returns an empty map, while an invalid individual record is skipped.
 */
fun parseNikonObjectsMetadataCaptureDates(data: ByteArray?): Map<Int, String> {
    if (data == null || data.size < NIKON_OBJECT_METADATA_HEADER_BYTES) return emptyMap()
    val version = data.readInt32LittleEndian(0)
    val count = data.readInt32LittleEndian(4)
    if (version != NIKON_OBJECT_METADATA_VERSION || count <= 0 ||
        count > (data.size - NIKON_OBJECT_METADATA_HEADER_BYTES) /
            NIKON_OBJECT_METADATA_RECORD_BYTES ||
        NIKON_OBJECT_METADATA_HEADER_BYTES.toLong() +
            count * NIKON_OBJECT_METADATA_RECORD_BYTES.toLong() != data.size.toLong()
    ) {
        return emptyMap()
    }
    val result = LinkedHashMap<Int, String>(count)
    repeat(count) { index ->
        val offset = NIKON_OBJECT_METADATA_HEADER_BYTES +
            index * NIKON_OBJECT_METADATA_RECORD_BYTES
        val handle = data.readInt32LittleEndian(offset)
        val second = data[offset + 9].toInt() and 0xFF
        val minute = data[offset + 10].toInt() and 0xFF
        val hour = data[offset + 11].toInt() and 0xFF
        val day = data[offset + 12].toInt() and 0xFF
        val month = data[offset + 13].toInt() and 0xFF
        val year = data.readUInt16LittleEndian(offset + 14)
        if (handle != 0 && year in 1990..2200 && month in 1..12 && day in 1..31 &&
            hour in 0..23 && minute in 0..59 && second in 0..60
        ) {
            result[handle] = buildString(15) {
                append(year.zeroPadded(4))
                append(month.zeroPadded(2))
                append(day.zeroPadded(2))
                append('T')
                append(hour.zeroPadded(2))
                append(minute.zeroPadded(2))
                append(second.zeroPadded(2))
            }
        }
    }
    return result
}

/** Known media-kind bytes observed in paired Nikon STA handles. */
fun staDirectExtensionFromHandle(handle: Int): String? = when (handle ushr 24 and 0xFF) {
    0x29 -> ".jpg"
    0x09 -> ".nef"
    0x61 -> ".mp4"
    else -> null
}

private fun floorDiv(value: Long, positiveDivisor: Long): Long {
    val quotient = value / positiveDivisor
    return if (value % positiveDivisor < 0L) quotient - 1L else quotient
}

private fun floorMod(value: Long, positiveDivisor: Long): Long =
    value - floorDiv(value, positiveDivisor) * positiveDivisor

private fun Int.zeroPadded(width: Int): String {
    val text = toString()
    return if (text.startsWith('-')) {
        "-" + text.drop(1).padStart((width - 1).coerceAtLeast(0), '0')
    } else {
        text.padStart(width, '0')
    }
}
