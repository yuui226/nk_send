package com.ztransfer.protocol

internal data class ParsedObjectCacheIdentity(
    val fileName: String,
    val captureDate: String?,
    val complete: Boolean,
)

/** Pure decoded ObjectInfo fields; transport stays platform-side and publishes [CameraFileInfo]. */
class PtpObjectInfo internal constructor(
    val handle: Int,
    val storageId: Int,
    val objectFormat: Int,
    val size: Long,
    val fileName: String?,
    val captureDate: String?,
    val isProtected: Boolean,
    val isAssociation: Boolean,
    val identityComplete: Boolean,
)

/** Returns null only when the fixed 53-byte ObjectInfo prefix is incomplete. */
fun parsePtpObjectInfo(
    handle: Int,
    data: ByteArray,
    formatPaddedDecimal: (value: Int, width: Int) -> String = ::formatAsciiPaddedDecimal,
): PtpObjectInfo? {
    if (data.size < 53) return null
    val storageId = data.readInt32LittleEndian(0)
    val format = data.readUInt16LittleEndian(4)
    val isAssociation = format == 0x3001
    if (isAssociation) {
        return PtpObjectInfo(
            handle = handle,
            storageId = storageId,
            objectFormat = format,
            size = data.readUInt32LittleEndian(8),
            fileName = null,
            captureDate = null,
            isProtected = data.readUInt16LittleEndian(6) != 0,
            isAssociation = true,
            identityComplete = true,
        )
    }

    val identity = parseObjectCacheIdentity(
        handle = handle,
        extension = PtpConstants.getExt(format),
        data = data,
        formatPaddedDecimal = formatPaddedDecimal,
    )
    return PtpObjectInfo(
        handle = handle,
        storageId = storageId,
        objectFormat = format,
        size = data.readUInt32LittleEndian(8),
        fileName = identity.fileName,
        captureDate = identity.captureDate,
        isProtected = data.readUInt16LittleEndian(6) != 0,
        isAssociation = false,
        identityComplete = identity.complete,
    )
}

/** Parses only fields participating in disk-cache identity, preserving incomplete fallbacks. */
internal fun parseObjectCacheIdentity(
    handle: Int,
    extension: String,
    data: ByteArray,
    formatPaddedDecimal: (value: Int, width: Int) -> String = ::formatAsciiPaddedDecimal,
): ParsedObjectCacheIdentity {
    val fallbackName = "DSC_${formatPaddedDecimal(handle and 0xFFFF, 4)}$extension"
    if (data.size < 53) return ParsedObjectCacheIdentity(fallbackName, null, false)

    val nameLength = data[52].toInt() and 0xFF
    val nameFieldComplete = hasUtf16NullTerminator(data, 53, nameLength)
    val decodedFileName = if (nameFieldComplete) {
        data.decodeUtf16LittleEndian(53, nameLength).trimEnd('\u0000')
    } else {
        null
    }
    val fileName = decodedFileName?.takeIf(String::isNotEmpty) ?: fallbackName
    if (!nameFieldComplete || decodedFileName.isNullOrEmpty()) {
        return ParsedObjectCacheIdentity(fileName, null, false)
    }

    val dateOffset = 53 + nameLength * 2
    if (data.size <= dateOffset) return ParsedObjectCacheIdentity(fileName, null, false)
    val dateLength = data[dateOffset].toInt() and 0xFF
    if (dateLength == 0) return ParsedObjectCacheIdentity(fileName, null, true)
    if (dateLength > (data.size - dateOffset - 1) / 2) {
        return ParsedObjectCacheIdentity(fileName, null, false)
    }
    if (!hasUtf16NullTerminator(data, dateOffset + 1, dateLength)) {
        return ParsedObjectCacheIdentity(fileName, null, false)
    }
    val date = data.decodeUtf16LittleEndian(dateOffset + 1, dateLength)
        .trimEnd('\u0000')
        .takeIf { it.length >= 8 }
    return ParsedObjectCacheIdentity(fileName, date, date != null)
}

/** Decodes a standalone PTP string and rejects truncated or unsafe filename values. */
fun parsePtpObjectFileName(data: ByteArray, offset: Int = 0): Pair<String, Int>? {
    if (offset !in data.indices) return null
    val codeUnits = data[offset].toInt() and 0xFF
    if (codeUnits <= 1) return null
    val byteCount = codeUnits * 2
    val valueOffset = offset + 1
    if (valueOffset + byteCount > data.size) return null
    if (!hasUtf16NullTerminator(data, valueOffset, codeUnits)) return null
    val decoded = data.decodeUtf16LittleEndian(valueOffset, codeUnits).trimEnd('\u0000')
    val fileName = cameraBaseFileName(decoded) ?: return null
    return fileName to (valueOffset + byteCount)
}

/** Parses GetObjectPropList queried specifically for ObjectFileName (0xDC07). */
fun parseObjectFileNamePropertyList(data: ByteArray): Map<Int, String> {
    if (data.size < 4) return emptyMap()
    val count = data.readUInt32LittleEndian(0)
    if (count > (data.size - 4) / 9L) return emptyMap()
    val names = LinkedHashMap<Int, String>(count.toInt().coerceAtMost(4096))
    var offset = 4
    repeat(count.toInt()) {
        if (offset + 8 > data.size) return emptyMap()
        val handle = data.readInt32LittleEndian(offset)
        val propertyCode = data.readUInt16LittleEndian(offset + 4)
        val dataType = data.readUInt16LittleEndian(offset + 6)
        offset += 8
        if (propertyCode != PtpConstants.OBJECT_PROP_OBJECT_FILE_NAME || dataType != 0xFFFF) {
            return emptyMap()
        }
        val parsed = parsePtpObjectFileName(data, offset) ?: return emptyMap()
        names[handle] = parsed.first
        offset = parsed.second
    }
    return names
}

private fun hasUtf16NullTerminator(data: ByteArray, offset: Int, codeUnits: Int): Boolean {
    if (codeUnits <= 0 || codeUnits > (data.size - offset) / 2) return false
    val terminatorOffset = offset + codeUnits * 2 - 2
    return data[terminatorOffset] == 0.toByte() && data[terminatorOffset + 1] == 0.toByte()
}

private fun cameraBaseFileName(value: String): String? {
    val baseName = value.substringAfterLast('/').substringAfterLast('\\').trim()
    return baseName.takeIf { name ->
        name.isNotEmpty() &&
            name.length <= 255 &&
            name.none { it.code < 0x20 || it == ':' }
    }
}
