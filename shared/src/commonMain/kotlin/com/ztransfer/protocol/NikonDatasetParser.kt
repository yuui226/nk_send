package com.ztransfer.protocol

/** DeviceInfo fields currently consumed by connection, browsing and remote-control features. */
data class LabDeviceInfo(
    val manufacturer: String,
    val model: String,
    val deviceVersion: String,
    val serial: String,
    val vendorExtId: Long,
    val vendorExtVersion: Int,
    val vendorExtDesc: String,
    val operations: Set<Int>,
    val events: Set<Int>,
    val props: Set<Int>,
)

/** Nikon GetVendorCodes(0x9439): u32 count followed by count u32 codes. */
fun parseVendorCodes32(data: ByteArray): Set<Int> {
    require(data.size >= 4) { "missing u32 count" }
    val cursor = PtpDataCursor(data)
    val count = cursor.readUInt32()
    val available = (data.size - 4) / 4
    require(count <= available.toLong()) {
        "declared $count codes but payload only contains $available"
    }
    val result = LinkedHashSet<Int>(count.toInt())
    repeat(count.toInt()) { result += cursor.readUInt32().toInt() }
    return result
}

fun parseDeviceInfo(data: ByteArray): LabDeviceInfo {
    val cursor = PtpDataCursor(data)
    cursor.readUInt16() // StandardVersion
    val vendorExtId = cursor.readUInt32()
    val vendorExtVersion = cursor.readUInt16()
    val vendorExtDesc = cursor.readPtpString()
    cursor.readUInt16() // FunctionalMode
    val operations = cursor.readUInt16Array().toSet()
    val events = cursor.readUInt16Array().toSet()
    val properties = cursor.readUInt16Array().toSet()
    cursor.readUInt16Array() // CaptureFormats
    cursor.readUInt16Array() // ImageFormats
    val manufacturer = cursor.readPtpString()
    val model = cursor.readPtpString()
    val version = cursor.readPtpString()
    val serial = cursor.readPtpString()
    return LabDeviceInfo(
        manufacturer = manufacturer,
        model = model,
        deviceVersion = version,
        serial = serial,
        vendorExtId = vendorExtId,
        vendorExtVersion = vendorExtVersion,
        vendorExtDesc = vendorExtDesc,
        operations = operations,
        events = events,
        props = properties,
    )
}

/** Nikon GetEvent(0x90C7): u16 count followed by {u16 code, u32 parameter}. */
fun parseNikonEvents(data: ByteArray): List<Pair<Int, Long>> {
    require(data.size >= 2) { "missing Nikon event count" }
    val cursor = PtpDataCursor(data)
    val count = cursor.readUInt16()
    require(count <= (data.size - 2) / 6) { "truncated Nikon event payload" }
    return List(count) { cursor.readUInt16() to cursor.readUInt32() }
}

/** Nikon GetEventEx(0x941C), exposing the first parameter exactly as the Android API did. */
fun parseNikonExtendedEvents(data: ByteArray): List<Pair<Int, Long>> {
    require(data.size >= 2) { "missing Nikon extended event count" }
    val count = PtpDataCursor(data).readUInt16()
    if (count == 0) return emptyList()
    require(data.size >= 4 && count <= (data.size - 4) / 4) {
        "truncated Nikon extended event payload"
    }
    val cursor = PtpDataCursor(data).apply { offset = 4 }
    return buildList(count) {
        repeat(count) {
            require(cursor.offset + 4 <= data.size) { "missing Nikon extended event header" }
            val code = cursor.readUInt16()
            val parameterCount = cursor.readUInt16()
            require(parameterCount in 0..5 && cursor.offset + parameterCount * 4 <= data.size) {
                "invalid Nikon extended event parameter count"
            }
            val firstParameter = if (parameterCount > 0) cursor.readUInt32() else 0L
            repeat((parameterCount - 1).coerceAtLeast(0)) { cursor.readUInt32() }
            add(code to firstParameter)
        }
    }
}

/** Bounds behavior intentionally matches the former Android cursor: malformed data throws. */
internal class PtpDataCursor(internal val data: ByteArray) {
    var offset: Int = 0

    fun readUInt8(): Int = data[offset++].toInt() and 0xFF

    fun readUInt16(): Int = data.readUInt16LittleEndian(offset).also { offset += 2 }

    fun readUInt32(): Long = data.readUInt32LittleEndian(offset).also { offset += 4 }

    fun readUInt64(): Long = data.readInt64LittleEndian(offset).also { offset += 8 }

    /** PTP string: u8 UTF-16 code-unit count including the trailing NUL. */
    fun readPtpString(): String {
        val count = readUInt8()
        if (count == 0) return ""
        val value = data.decodeUtf16LittleEndian(offset, count)
        offset += count * 2
        return value.trimEnd('\u0000')
    }

    fun readUInt16Array(): IntArray {
        val count = readUInt32()
        val available = (data.size - offset) / 2
        require(count <= available.toLong()) {
            "declared $count values but payload only contains $available"
        }
        return IntArray(count.toInt()) { readUInt16() }
    }
}

internal fun ByteArray.decodeUtf16LittleEndian(offset: Int, codeUnits: Int): String =
    buildString(codeUnits) {
        var index = 0
        while (index < codeUnits) {
            val character = readUInt16LittleEndian(offset + index * 2).toChar()
            when {
                character.isHighSurrogate() && index + 1 < codeUnits -> {
                    val next = readUInt16LittleEndian(offset + (index + 1) * 2).toChar()
                    if (next.isLowSurrogate()) {
                        append(character)
                        append(next)
                        index += 2
                    } else {
                        append('\uFFFD')
                        index++
                    }
                }
                character.isSurrogate() -> {
                    append('\uFFFD')
                    index++
                }
                else -> {
                    append(character)
                    index++
                }
            }
        }
    }
