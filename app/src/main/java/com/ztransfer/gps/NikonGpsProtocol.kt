package com.ztransfer.gps

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec

internal data class GpsPairingPacket(
    val stage: Int,
    val timestamp: Long,
    val device: Long,
    val nonce: Long,
) {
    fun encode(): ByteArray = ByteBuffer.allocate(17)
        .order(ByteOrder.LITTLE_ENDIAN)
        .put(stage.toByte())
        .putLong(timestamp)
        .putInt(device.toInt())
        .putInt(nonce.toInt())
        .array()

    companion object {
        fun decode(bytes: ByteArray): GpsPairingPacket? {
            if (bytes.size != 17) return null
            val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            return GpsPairingPacket(
                stage = b.get().toInt() and 0xFF,
                timestamp = b.long,
                device = b.int.toLong() and 0xFFFF_FFFFL,
                nonce = b.int.toLong() and 0xFFFF_FFFFL,
            )
        }
    }
}

/** Nikon's four-message Smart Device handshake. Kept independent from the Android BLE layer. */
internal class NikonGpsPairingProtocol(
    private val random: SecureRandom = SecureRandom(),
) {
    private val cipher = Cipher.getInstance("Blowfish/ECB/NoPadding").apply {
        init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(byteArrayOf(
                0xFF.toByte(), 0xFF.toByte(), 0xAA.toByte(), 0x55.toByte(),
                0x11, 0x22, 0x33, 0x00,
            ), "Blowfish"),
        )
    }

    fun newStage1(deviceOverride: Long? = null, nonceOverride: Long? = null): GpsPairingPacket {
        val device = deviceOverride ?: ((random.nextInt().toLong() and 0xFFFF_FF00L) or 1L)
        return GpsPairingPacket(
            stage = 1,
            timestamp = random.nextLong(),
            device = device,
            nonce = nonceOverride ?: (random.nextInt().toLong() and 0xFFFF_FFFFL),
        )
    }

    fun stage3For(stage1: GpsPairingPacket, stage2: GpsPairingPacket): GpsPairingPacket? {
        val saltIndex = salts.indexOfFirst { salt ->
            val expected = hash(intArrayOf(
                salt[0], salt[1],
                beHalves(stage2.timestamp).first, beHalves(stage2.timestamp).second,
                beHalves(stage1.timestamp).first, beHalves(stage1.timestamp).second,
            ))
            expected.first == reverse(stage2.device.toInt()) &&
                expected.second == reverse(stage2.nonce.toInt())
        }
        if (saltIndex < 0) return null
        val a = beHalves(stage1.timestamp)
        val b = beHalves(stage2.timestamp)
        val result = hash(intArrayOf(salts[saltIndex][0], salts[saltIndex][1], a.first, a.second, b.first, b.second))
        return GpsPairingPacket(
            stage = 3,
            timestamp = stage1.timestamp,
            device = reverse(result.first).toLong() and 0xFFFF_FFFFL,
            nonce = reverse(result.second).toLong() and 0xFFFF_FFFFL,
        )
    }

    private fun hash(words: IntArray): Pair<Int, Int> {
        var left = 0x01020304
        var right = 0x05060708
        for (i in words.indices step 2) {
            val input = ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN)
                .putInt(words[i] xor left)
                .putInt(words[i + 1] xor right)
                .array()
            val out = cipher.doFinal(input)
            left = ByteBuffer.wrap(out).order(ByteOrder.BIG_ENDIAN).int
            right = ByteBuffer.wrap(out).order(ByteOrder.BIG_ENDIAN).int
        }
        return left to right
    }

    private fun beHalves(value: Long): Pair<Int, Int> =
        reverse(value.toInt()) to reverse((value ushr 32).toInt())

    private fun reverse(value: Int): Int = Integer.reverseBytes(value)

    private val salts = arrayOf(
        intArrayOf(0x704066e4, 0x0433d552), intArrayOf(0xed4b8fac.toInt(), 0x15f7e47b),
        intArrayOf(0x24471f11, 0x8b5ea1fc.toInt()), intArrayOf(0x05960c31, 0x2b8c7f41),
        intArrayOf(0xfda588c1.toInt(), 0xeba8b1f3.toInt()), intArrayOf(0x99166056.toInt(), 0x1bd3d550),
        intArrayOf(0xcd32687f.toInt(), 0xa9e28a30.toInt()), intArrayOf(0x2a8fe834, 0xdec7ebf4.toInt()),
    )
}
