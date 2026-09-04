package com.ztransfer.protocol

/** Decoded fields used by both command-channel handshakes. */
class PtpIpInitCommandAck internal constructor(
    val connectionNumber: Int,
    val responderGuidHex: String?,
)

/** PTP/IP event payload. Additional event parameters remain available for a later typed model. */
class PtpIpEvent internal constructor(
    val code: Int,
    val transactionId: Long,
    val firstParameter: Long,
)

/**
 * Platform-neutral PTP/IP handshake and command packet codec.
 *
 * Socket ownership, random GUID generation, transaction sequencing and flushing stay in each
 * platform implementation. This object only defines the bytes sent over an established channel.
 */
object PtpIpProtocolCodec {
    private const val MAX_COMMAND_PARAMETERS = 5
    private const val STANDARD_PROTOCOL_VERSION = 0x00010000

    /** Nikon hotspot compatibility form whose protocol version is a 16-bit value. */
    fun encodeLegacyInitCommandRequest(
        initiatorGuid: ByteArray,
        initiatorName: String,
    ): ByteArray = encodeInitCommandRequest(
        initiatorGuid = initiatorGuid,
        initiatorName = initiatorName,
        protocolVersion = 1,
        protocolVersionBytes = 2,
    )

    /** Standard PTP/IP form whose protocol version is a 32-bit value. */
    fun encodeStandardInitCommandRequest(
        initiatorGuid: ByteArray,
        initiatorName: String,
    ): ByteArray = encodeInitCommandRequest(
        initiatorGuid = initiatorGuid,
        initiatorName = initiatorName,
        protocolVersion = STANDARD_PROTOCOL_VERSION,
        protocolVersionBytes = 4,
    )

    fun decodeInitCommandAck(payload: ByteArray?): PtpIpInitCommandAck? {
        if (payload == null) return null
        return PtpIpInitCommandAck(
            connectionNumber = payload.readInt32LittleEndian(0),
            responderGuidHex = if (payload.size >= 20) payload.toLowercaseHex(4, 20) else null,
        )
    }

    fun encodeInitEventRequest(connectionNumber: Int): ByteArray {
        val packet = ByteArray(12)
        packet.writeInt32LittleEndian(0, packet.size)
        packet.writeInt32LittleEndian(4, PtpConstants.INIT_EVT_REQ)
        packet.writeInt32LittleEndian(8, connectionNumber)
        return packet
    }

    fun encodeCommandRequest(
        operationCode: Int,
        transactionId: Int,
        parameters: IntArray = intArrayOf(),
    ): ByteArray {
        val parameterCount = parameters.size.coerceAtMost(MAX_COMMAND_PARAMETERS)
        val packet = ByteArray(18 + parameterCount * 4)
        writeCommandRequest(
            destination = packet,
            offset = 0,
            operationCode = operationCode,
            transactionId = transactionId,
            parameters = parameters,
            parameterCount = parameterCount,
            dataPhaseInfo = 1,
        )
        return packet
    }

    /** Command request followed by Start-Data and one End-Data packet, matching Android writes. */
    fun encodeCommandWithData(
        operationCode: Int,
        transactionId: Int,
        data: ByteArray,
        parameters: IntArray = intArrayOf(),
    ): ByteArray {
        val parameterCount = parameters.size.coerceAtMost(MAX_COMMAND_PARAMETERS)
        val commandSize = 18 + parameterCount * 4
        val startDataSize = 20
        val endDataSize = 12 + data.size
        require(data.size <= Int.MAX_VALUE - commandSize - startDataSize - 12) {
            "PTP/IP command data too large"
        }
        val packet = ByteArray(commandSize + startDataSize + endDataSize)

        writeCommandRequest(
            destination = packet,
            offset = 0,
            operationCode = operationCode,
            transactionId = transactionId,
            parameters = parameters,
            parameterCount = parameterCount,
            dataPhaseInfo = 2,
        )

        var offset = commandSize
        packet.writeInt32LittleEndian(offset, startDataSize)
        packet.writeInt32LittleEndian(offset + 4, PtpConstants.START_DATA_PACKET)
        packet.writeInt32LittleEndian(offset + 8, transactionId)
        packet.writeInt64LittleEndian(offset + 12, data.size.toLong())

        offset += startDataSize
        packet.writeInt32LittleEndian(offset, endDataSize)
        packet.writeInt32LittleEndian(offset + 4, PtpConstants.END_DATA_PACKET)
        packet.writeInt32LittleEndian(offset + 8, transactionId)
        data.copyInto(packet, destinationOffset = offset + 12)
        return packet
    }

    fun encodeCancelRequest(transactionId: Int): ByteArray {
        val packet = ByteArray(12)
        packet.writeInt32LittleEndian(0, packet.size)
        packet.writeInt32LittleEndian(4, PtpConstants.CANCEL)
        packet.writeInt32LittleEndian(8, transactionId)
        return packet
    }

    /** Preserves the existing tolerant event behavior: 6-byte events are valid without parameters. */
    fun decodeEvent(payload: ByteArray?): PtpIpEvent? {
        if (payload == null || payload.size < 6) return null
        return PtpIpEvent(
            code = payload.readUInt16LittleEndian(0),
            transactionId = payload.readUInt32LittleEndian(2),
            firstParameter = if (payload.size >= 10) {
                payload.readUInt32LittleEndian(6)
            } else {
                0L
            },
        )
    }

    /** Reads a copied response payload; a malformed non-empty short payload still fails as before. */
    fun decodeResponseCode(payload: ByteArray): Int = payload.readUInt16LittleEndian(0)

    /** Reads from a reusable raw buffer while respecting its actual payload size. */
    fun decodeResponseCode(payloadBuffer: ByteArray, payloadLength: Int): Int =
        if (payloadLength < 2) 0 else payloadBuffer.readUInt16LittleEndian(0)

    private fun encodeInitCommandRequest(
        initiatorGuid: ByteArray,
        initiatorName: String,
        protocolVersion: Int,
        protocolVersionBytes: Int,
    ): ByteArray {
        require(initiatorGuid.size == 16) { "PTP/IP initiator GUID must be 16 bytes" }
        val nameBytes = initiatorName.toUtf16LittleEndianNullTerminated()
        val packet = ByteArray(8 + initiatorGuid.size + nameBytes.size + protocolVersionBytes)
        packet.writeInt32LittleEndian(0, packet.size)
        packet.writeInt32LittleEndian(4, PtpConstants.INIT_CMD_REQ)
        initiatorGuid.copyInto(packet, destinationOffset = 8)
        nameBytes.copyInto(packet, destinationOffset = 24)
        val versionOffset = 24 + nameBytes.size
        if (protocolVersionBytes == 2) {
            packet.writeUInt16LittleEndian(versionOffset, protocolVersion)
        } else {
            packet.writeInt32LittleEndian(versionOffset, protocolVersion)
        }
        return packet
    }

    private fun writeCommandRequest(
        destination: ByteArray,
        offset: Int,
        operationCode: Int,
        transactionId: Int,
        parameters: IntArray,
        parameterCount: Int,
        dataPhaseInfo: Int,
    ) {
        val packetSize = 18 + parameterCount * 4
        destination.writeInt32LittleEndian(offset, packetSize)
        destination.writeInt32LittleEndian(offset + 4, PtpConstants.CMD_REQUEST)
        destination.writeInt32LittleEndian(offset + 8, dataPhaseInfo)
        destination.writeUInt16LittleEndian(offset + 12, operationCode and 0xFFFF)
        destination.writeInt32LittleEndian(offset + 14, transactionId)
        repeat(parameterCount) { index ->
            destination.writeInt32LittleEndian(offset + 18 + index * 4, parameters[index])
        }
    }
}

private fun ByteArray.toLowercaseHex(fromIndex: Int, toIndex: Int): String = buildString {
    for (index in fromIndex until toIndex) {
        val value = this@toLowercaseHex[index].toInt() and 0xFF
        append(HEX_DIGITS[value ushr 4])
        append(HEX_DIGITS[value and 0x0F])
    }
}

private const val HEX_DIGITS = "0123456789abcdef"

private fun String.toUtf16LittleEndianNullTerminated(): ByteArray {
    require(length <= (Int.MAX_VALUE / 2) - 1) { "PTP/IP initiator name too long" }
    return ByteArray((length + 1) * 2).also { bytes ->
        forEachIndexed { index, character ->
            bytes.writeUInt16LittleEndian(index * 2, character.code)
        }
    }
}
