package com.ztransfer.protocol

/** Platform-neutral framing for the 8-byte PTP/IP packet header. */
object PtpIpPacketCodec {
    const val HEADER_SIZE = 8

    // Large enough for real transfers while preventing corrupt lengths from requesting multi-GB
    // buffers in platform stream readers.
    const val MAX_PACKET_SIZE = 256 * 1024 * 1024

    /** Reads the signed 32-bit wire length without allocating a header object. */
    fun readLength(bytes: ByteArray, offset: Int = 0): Int =
        bytes.readInt32LittleEndian(offset)

    /** Reads the signed 32-bit packet type without allocating a header object. */
    fun readType(bytes: ByteArray, offset: Int = 0): Int =
        bytes.readInt32LittleEndian(offset + 4)

    fun isValidLength(length: Int): Boolean = length in HEADER_SIZE..MAX_PACKET_SIZE

    /** Encodes one complete packet with exactly one result allocation. */
    fun encode(type: Int, payload: ByteArray? = null): ByteArray {
        val payloadSize = payload?.size ?: 0
        require(payloadSize <= MAX_PACKET_SIZE - HEADER_SIZE) { "PTP/IP payload too large" }
        val packet = ByteArray(HEADER_SIZE + payloadSize)
        packet.writeInt32LittleEndian(0, packet.size)
        packet.writeInt32LittleEndian(4, type)
        payload?.copyInto(packet, destinationOffset = HEADER_SIZE)
        return packet
    }
}

internal fun ByteArray.readUInt16LittleEndian(offset: Int): Int =
    (this[offset].toInt() and 0xFF) or
        ((this[offset + 1].toInt() and 0xFF) shl 8)

internal fun ByteArray.readInt32LittleEndian(offset: Int): Int =
    (this[offset].toInt() and 0xFF) or
        ((this[offset + 1].toInt() and 0xFF) shl 8) or
        ((this[offset + 2].toInt() and 0xFF) shl 16) or
        ((this[offset + 3].toInt() and 0xFF) shl 24)

internal fun ByteArray.readUInt32LittleEndian(offset: Int): Long =
    readInt32LittleEndian(offset).toLong() and 0xFFFFFFFFL

internal fun ByteArray.readInt64LittleEndian(offset: Int): Long =
    readUInt32LittleEndian(offset) or
        (readInt32LittleEndian(offset + 4).toLong() shl 32)

internal fun ByteArray.writeUInt16LittleEndian(offset: Int, value: Int) {
    require(value in 0..0xFFFF) { "unsigned 16-bit value out of range" }
    this[offset] = value.toByte()
    this[offset + 1] = (value ushr 8).toByte()
}

internal fun ByteArray.writeInt32LittleEndian(offset: Int, value: Int) {
    repeat(Int.SIZE_BYTES) { index ->
        this[offset + index] = (value ushr (index * 8)).toByte()
    }
}

internal fun ByteArray.writeInt64LittleEndian(offset: Int, value: Long) {
    repeat(Long.SIZE_BYTES) { index ->
        this[offset + index] = (value ushr (index * 8)).toByte()
    }
}
