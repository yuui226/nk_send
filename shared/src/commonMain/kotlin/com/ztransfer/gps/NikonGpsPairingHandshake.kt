package com.ztransfer.gps

/** Nikon Smart Device pairing message: one stage byte followed by four little-endian words. */
data class NikonGpsPairingPacket(
    val stage: Int,
    val timestamp: Long,
    val device: Long,
    val nonce: Long,
)

/** Platform-neutral codec for Nikon's fixed-size 17-byte GPS pairing packet. */
object NikonGpsPairingPacketCodec {
    private const val PACKET_SIZE = 17

    fun encode(packet: NikonGpsPairingPacket): ByteArray = ByteArray(PACKET_SIZE).also { bytes ->
        bytes[0] = packet.stage.toByte()
        bytes.writeInt64LittleEndian(offset = 1, value = packet.timestamp)
        bytes.writeInt32LittleEndian(offset = 9, value = packet.device)
        bytes.writeInt32LittleEndian(offset = 13, value = packet.nonce)
    }

    fun decode(bytes: ByteArray): NikonGpsPairingPacket? {
        if (bytes.size != PACKET_SIZE) return null
        return NikonGpsPairingPacket(
            stage = bytes[0].toInt() and 0xFF,
            timestamp = bytes.readInt64LittleEndian(offset = 1),
            device = bytes.readUInt32LittleEndian(offset = 9),
            nonce = bytes.readUInt32LittleEndian(offset = 13),
        )
    }
}

/** Raw values supplied by a platform secure-random generator for a new stage-1 packet. */
data class NikonGpsPairingEntropy(
    val device: Int,
    val timestamp: Long,
    val nonce: Int,
)

/** Minimal handshake state retained while Android or iOS owns the BLE connection. */
data class NikonGpsPairingState(
    val stage1: NikonGpsPairingPacket? = null,
    val stage3Sent: Boolean = false,
    val stage4Accepted: Boolean = false,
)

enum class NikonGpsPairingAction {
    SEND_STAGE1,
    SEND_STAGE3,
    REJECT_STAGE2,
    ACCEPT_STAGE4,
    IGNORE,
}

data class NikonGpsPairingDecision(
    val state: NikonGpsPairingState,
    val action: NikonGpsPairingAction,
    val packetToWrite: NikonGpsPairingPacket? = null,
)

/** Blowfish remains platform-owned; shared code only requests encryption of one eight-byte block. */
fun interface NikonGpsPairingBlockEncryptor {
    fun encrypt(block: ByteArray): ByteArray
}

/** Pure construction and transition rules for Nikon's four-message Smart Device handshake. */
object NikonGpsPairingHandshake {
    fun begin(
        entropy: NikonGpsPairingEntropy,
        deviceOverride: Long? = null,
        nonceOverride: Long? = null,
    ): NikonGpsPairingDecision {
        val stage1 = NikonGpsPairingPacket(
            stage = 1,
            timestamp = entropy.timestamp,
            device = deviceOverride
                ?: ((entropy.device.toLong() and 0xFFFF_FF00L) or 1L),
            nonce = nonceOverride ?: (entropy.nonce.toLong() and 0xFFFF_FFFFL),
        )
        return NikonGpsPairingDecision(
            state = NikonGpsPairingState(stage1 = stage1),
            action = NikonGpsPairingAction.SEND_STAGE1,
            packetToWrite = stage1,
        )
    }

    /**
     * Decides the next BLE-side action. Nikon's existing tolerant behavior is intentional: once
     * stage 1 exists, stage 4 is accepted even if a stage-2 notification was not observed.
     */
    fun advance(
        state: NikonGpsPairingState,
        incoming: NikonGpsPairingPacket,
        encryptor: NikonGpsPairingBlockEncryptor,
    ): NikonGpsPairingDecision {
        val stage1 = state.stage1 ?: return state.ignore()
        if (incoming.stage == 2 && !state.stage3Sent) {
            val stage3 = stage3For(stage1, incoming, encryptor)
                ?: return NikonGpsPairingDecision(
                    state = state,
                    action = NikonGpsPairingAction.REJECT_STAGE2,
                )
            val nextState = state.copy(stage3Sent = true)
            return NikonGpsPairingDecision(
                state = nextState,
                action = NikonGpsPairingAction.SEND_STAGE3,
                packetToWrite = stage3,
            )
        }
        if (incoming.stage == 4) {
            return NikonGpsPairingDecision(
                state = state.copy(stage4Accepted = true),
                action = NikonGpsPairingAction.ACCEPT_STAGE4,
            )
        }
        return state.ignore()
    }

    private fun stage3For(
        stage1: NikonGpsPairingPacket,
        stage2: NikonGpsPairingPacket,
        encryptor: NikonGpsPairingBlockEncryptor,
    ): NikonGpsPairingPacket? {
        val stage1Halves = bigEndianHalves(stage1.timestamp)
        val stage2Halves = bigEndianHalves(stage2.timestamp)
        val saltIndex = SALTS.indexOfFirst { salt ->
            val expected = hash(
                words = intArrayOf(
                    salt[0], salt[1],
                    stage2Halves.first, stage2Halves.second,
                    stage1Halves.first, stage1Halves.second,
                ),
                encryptor = encryptor,
            )
            expected.first == reverseBytes(stage2.device.toInt()) &&
                expected.second == reverseBytes(stage2.nonce.toInt())
        }
        if (saltIndex < 0) return null
        val salt = SALTS[saltIndex]
        val result = hash(
            words = intArrayOf(
                salt[0], salt[1],
                stage1Halves.first, stage1Halves.second,
                stage2Halves.first, stage2Halves.second,
            ),
            encryptor = encryptor,
        )
        return NikonGpsPairingPacket(
            stage = 3,
            timestamp = stage1.timestamp,
            device = reverseBytes(result.first).toLong() and 0xFFFF_FFFFL,
            nonce = reverseBytes(result.second).toLong() and 0xFFFF_FFFFL,
        )
    }

    private fun hash(
        words: IntArray,
        encryptor: NikonGpsPairingBlockEncryptor,
    ): Pair<Int, Int> {
        var left = 0x01020304
        var right = 0x05060708
        for (index in words.indices step 2) {
            val input = ByteArray(8)
            input.writeInt32BigEndian(offset = 0, value = words[index] xor left)
            input.writeInt32BigEndian(offset = 4, value = words[index + 1] xor right)
            val output = encryptor.encrypt(input)
            require(output.size == 8) { "Nikon GPS block encryptor must return 8 bytes" }
            left = output.readInt32BigEndian(offset = 0)
            right = output.readInt32BigEndian(offset = 4)
        }
        return left to right
    }

    private fun bigEndianHalves(value: Long): Pair<Int, Int> =
        reverseBytes(value.toInt()) to reverseBytes((value ushr 32).toInt())

    private fun NikonGpsPairingState.ignore(): NikonGpsPairingDecision =
        NikonGpsPairingDecision(state = this, action = NikonGpsPairingAction.IGNORE)

    private val SALTS = arrayOf(
        intArrayOf(0x704066e4, 0x0433d552),
        intArrayOf(0xed4b8fac.toInt(), 0x15f7e47b),
        intArrayOf(0x24471f11, 0x8b5ea1fc.toInt()),
        intArrayOf(0x05960c31, 0x2b8c7f41),
        intArrayOf(0xfda588c1.toInt(), 0xeba8b1f3.toInt()),
        intArrayOf(0x99166056.toInt(), 0x1bd3d550),
        intArrayOf(0xcd32687f.toInt(), 0xa9e28a30.toInt()),
        intArrayOf(0x2a8fe834, 0xdec7ebf4.toInt()),
    )
}

private fun ByteArray.writeInt32LittleEndian(offset: Int, value: Long) {
    repeat(4) { index -> this[offset + index] = (value ushr (index * 8)).toByte() }
}

private fun ByteArray.writeInt64LittleEndian(offset: Int, value: Long) {
    repeat(8) { index -> this[offset + index] = (value ushr (index * 8)).toByte() }
}

private fun ByteArray.readUInt32LittleEndian(offset: Int): Long {
    var value = 0L
    repeat(4) { index ->
        value = value or ((this[offset + index].toLong() and 0xFFL) shl (index * 8))
    }
    return value
}

private fun ByteArray.readInt64LittleEndian(offset: Int): Long {
    var value = 0L
    repeat(8) { index ->
        value = value or ((this[offset + index].toLong() and 0xFFL) shl (index * 8))
    }
    return value
}

private fun ByteArray.writeInt32BigEndian(offset: Int, value: Int) {
    repeat(4) { index -> this[offset + index] = (value ushr ((3 - index) * 8)).toByte() }
}

private fun ByteArray.readInt32BigEndian(offset: Int): Int =
    ((this[offset].toInt() and 0xFF) shl 24) or
        ((this[offset + 1].toInt() and 0xFF) shl 16) or
        ((this[offset + 2].toInt() and 0xFF) shl 8) or
        (this[offset + 3].toInt() and 0xFF)

private fun reverseBytes(value: Int): Int =
    (value ushr 24) or
        ((value ushr 8) and 0x0000_FF00) or
        ((value shl 8) and 0x00FF_0000) or
        (value shl 24)
