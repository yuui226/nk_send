package com.ztransfer.gps

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec

internal data class GpsPairingPacket(
    val stage: Int,
    val timestamp: Long,
    val device: Long,
    val nonce: Long,
) {
    fun encode(): ByteArray = NikonGpsPairingPacketCodec.encode(toShared())

    companion object {
        fun decode(bytes: ByteArray): GpsPairingPacket? =
            NikonGpsPairingPacketCodec.decode(bytes)?.toAndroid()
    }
}

/** Nikon's four-message Smart Device handshake. Kept independent from the Android BLE layer. */
internal class NikonGpsPairingProtocol(
    random: SecureRandom? = null,
) {
    private val secureRandom by lazy { random ?: SecureRandom() }
    private val cipher by lazy {
        Cipher.getInstance("Blowfish/ECB/NoPadding").apply {
            init(
                Cipher.ENCRYPT_MODE,
                SecretKeySpec(byteArrayOf(
                    0xFF.toByte(), 0xFF.toByte(), 0xAA.toByte(), 0x55.toByte(),
                    0x11, 0x22, 0x33, 0x00,
                ), "Blowfish"),
            )
        }
    }
    private val encryptor = NikonGpsPairingBlockEncryptor { block -> cipher.doFinal(block) }

    fun newStage1(deviceOverride: Long? = null, nonceOverride: Long? = null): GpsPairingPacket {
        return begin(deviceOverride, nonceOverride).packetToWrite!!.toAndroid()
    }

    fun begin(
        deviceOverride: Long? = null,
        nonceOverride: Long? = null,
    ): NikonGpsPairingDecision {
        // Preserve SecureRandom consumption order from the original Android implementation.
        val deviceEntropy = if (deviceOverride == null) secureRandom.nextInt() else 0
        val timestampEntropy = secureRandom.nextLong()
        val nonceEntropy = if (nonceOverride == null) secureRandom.nextInt() else 0
        return NikonGpsPairingHandshake.begin(
            entropy = NikonGpsPairingEntropy(
                device = deviceEntropy,
                timestamp = timestampEntropy,
                nonce = nonceEntropy,
            ),
            deviceOverride = deviceOverride,
            nonceOverride = nonceOverride,
        )
    }

    fun advance(
        state: NikonGpsPairingState,
        incoming: GpsPairingPacket,
    ): NikonGpsPairingDecision = NikonGpsPairingHandshake.advance(
        state = state,
        incoming = incoming.toShared(),
        encryptor = encryptor,
    )

    fun stage3For(stage1: GpsPairingPacket, stage2: GpsPairingPacket): GpsPairingPacket? =
        advance(
            state = NikonGpsPairingState(stage1 = stage1.toShared()),
            incoming = stage2,
        ).takeIf { it.action == NikonGpsPairingAction.SEND_STAGE3 }
            ?.packetToWrite
            ?.toAndroid()
}

private fun GpsPairingPacket.toShared(): NikonGpsPairingPacket =
    NikonGpsPairingPacket(
        stage = stage,
        timestamp = timestamp,
        device = device,
        nonce = nonce,
    )

private fun NikonGpsPairingPacket.toAndroid(): GpsPairingPacket =
    GpsPairingPacket(
        stage = stage,
        timestamp = timestamp,
        device = device,
        nonce = nonce,
    )
