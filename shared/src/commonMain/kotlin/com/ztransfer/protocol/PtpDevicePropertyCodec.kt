package com.ztransfer.protocol

class PtpDecodedValue internal constructor(
    val value: Long,
    val isScalar: Boolean,
)

/** Raw protocol descriptor. UI formatting and camera-specific policy remain in RemoteLab. */
class PtpDevicePropDescriptor internal constructor(
    val propertyCode: Int,
    val dataType: Int,
    val writable: Boolean,
    val defaultValue: Long,
    val defaultIsScalar: Boolean,
    val current: Long,
    val currentIsScalar: Boolean,
    val formFlag: Int,
    val rangeMin: Long? = null,
    val rangeMax: Long? = null,
    val rangeStep: Long? = null,
    val enumValues: List<Long> = emptyList(),
)

fun parsePtpDevicePropDescriptor(data: ByteArray): PtpDevicePropDescriptor {
    return parsePtpDevicePropDescriptor(data, expectedPropertyCode = null)
}

/** Probe form: validate the echoed low 16-bit code before parsing the remainder. */
fun parsePtpDevicePropDescriptor(
    expectedPropertyCode: Int,
    data: ByteArray,
): PtpDevicePropDescriptor = parsePtpDevicePropDescriptor(data, expectedPropertyCode)

private fun parsePtpDevicePropDescriptor(
    data: ByteArray,
    expectedPropertyCode: Int?,
): PtpDevicePropDescriptor {
    val cursor = PtpDataCursor(data)
    val propertyCode = cursor.readUInt16()
    if (expectedPropertyCode != null) {
        require(propertyCode == (expectedPropertyCode and 0xFFFF)) {
            "descriptor echoed ${propertyCode.hex4()}, expected ${expectedPropertyCode.hex4()}"
        }
    }
    val dataType = cursor.readUInt16()
    val writable = cursor.readUInt8() == 1
    val defaultValue = cursor.readTypedValue(dataType)
    val currentValue = cursor.readTypedValue(dataType)
    val formFlag = cursor.readUInt8()
    var rangeMin: Long? = null
    var rangeMax: Long? = null
    var rangeStep: Long? = null
    var enumValues = emptyList<Long>()
    when (formFlag) {
        1 -> {
            rangeMin = cursor.readTypedValue(dataType).value
            rangeMax = cursor.readTypedValue(dataType).value
            rangeStep = cursor.readTypedValue(dataType).value
        }
        2 -> {
            val count = cursor.readUInt16()
            enumValues = List(count) { cursor.readTypedValue(dataType).value }
        }
    }
    return PtpDevicePropDescriptor(
        propertyCode = propertyCode,
        dataType = dataType,
        writable = writable,
        defaultValue = defaultValue.value,
        defaultIsScalar = defaultValue.isScalar,
        current = currentValue.value,
        currentIsScalar = currentValue.isScalar,
        formFlag = formFlag,
        rangeMin = rangeMin,
        rangeMax = rangeMax,
        rangeStep = rangeStep,
        enumValues = enumValues,
    )
}

private fun Int.hex4(): String =
    "0x${(this and 0xFFFF).toString(16).uppercase().padStart(4, '0')}"

fun decodePtpTypedValue(dataType: Int, data: ByteArray): PtpDecodedValue =
    PtpDataCursor(data).readTypedValue(dataType)

fun encodePtpScalar(dataType: Int, value: Long): ByteArray {
    val size = ptpScalarSize(dataType) ?: 8
    return ByteArray(size) { index -> ((value shr (8 * index)) and 0xFF).toByte() }
}

fun ptpScalarSize(dataType: Int): Int? = when (dataType) {
    0x0001, 0x0002 -> 1
    0x0003, 0x0004 -> 2
    0x0005, 0x0006 -> 4
    0x0007, 0x0008 -> 8
    else -> null
}

fun decodePtpUInt32(data: ByteArray): Long = data.readUInt32LittleEndian(0)

/** Nikon GetVendorPropCodes(0x90CA): PTP AUINT16. */
fun parseVendorCodes16(data: ByteArray): Set<Int> =
    PtpDataCursor(data).readUInt16Array().toSet()

private fun PtpDataCursor.readTypedValue(dataType: Int): PtpDecodedValue = when (dataType) {
    0x0001 -> PtpDecodedValue(readUInt8().toByte().toLong(), true) // INT8
    0x0002 -> PtpDecodedValue(readUInt8().toLong(), true) // UINT8
    0x0003 -> PtpDecodedValue(readUInt16().toShort().toLong(), true) // INT16
    0x0004 -> PtpDecodedValue(readUInt16().toLong(), true) // UINT16
    0x0005 -> PtpDecodedValue(readUInt32().toInt().toLong(), true) // INT32
    0x0006 -> PtpDecodedValue(readUInt32(), true) // UINT32
    0x0007, 0x0008 -> PtpDecodedValue(readUInt64(), true) // raw signed Long bit pattern
    0x0009, 0x000A -> {
        skipChecked(16)
        PtpDecodedValue(0L, false)
    }
    0xFFFF -> {
        readPtpString()
        PtpDecodedValue(0L, false)
    }
    else -> {
        if (dataType and 0x4000 != 0) {
            val elementType = dataType and 0xFF
            // Keep the former 8-byte fallback for unsupported/128-bit array element types.
            val elementSize = when (elementType) {
                0x01, 0x02 -> 1
                0x03, 0x04 -> 2
                0x05, 0x06 -> 4
                else -> 8
            }
            val count = readUInt32()
            require(count <= Int.MAX_VALUE.toLong() / elementSize) { "PTP array is too large" }
            skipChecked(count.toInt() * elementSize)
        }
        PtpDecodedValue(0L, false)
    }
}

private fun PtpDataCursor.skipChecked(byteCount: Int) {
    require(byteCount >= 0 && byteCount <= data.size - offset) { "truncated PTP value" }
    offset += byteCount
}
