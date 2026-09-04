package com.ztransfer.gps

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NikonGpsPairingHandshakeTest {
    @Test
    fun packetCodecUsesTheCapturedLittleEndianLayout() {
        val packet = NikonGpsPairingPacket(
            stage = 0xFF,
            timestamp = 0xFEDC_BA98_7654_3210uL.toLong(),
            device = 0xF0E0_D0C0L,
            nonce = 0xFFFF_FFFFL,
        )

        val encoded = NikonGpsPairingPacketCodec.encode(packet)

        assertContentEquals(
            byteArrayOf(
                0xFF.toByte(),
                0x10, 0x32, 0x54, 0x76, 0x98.toByte(), 0xBA.toByte(), 0xDC.toByte(), 0xFE.toByte(),
                0xC0.toByte(), 0xD0.toByte(), 0xE0.toByte(), 0xF0.toByte(),
                0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(),
            ),
            encoded,
        )
        assertEquals(packet, NikonGpsPairingPacketCodec.decode(encoded))
    }

    @Test
    fun packetDecoderRejectsEveryNonProtocolLength() {
        assertNull(NikonGpsPairingPacketCodec.decode(ByteArray(0)))
        assertNull(NikonGpsPairingPacketCodec.decode(ByteArray(16)))
        assertNull(NikonGpsPairingPacketCodec.decode(ByteArray(18)))
    }

    @Test
    fun packetDecoderPreservesUnsignedStageAndWords() {
        val bytes = byteArrayOf(
            0xFE.toByte(),
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0x80.toByte(),
            0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(),
        )

        val decoded = NikonGpsPairingPacketCodec.decode(bytes)

        assertEquals(0xFE, decoded?.stage)
        assertEquals(0x8000_0000L, decoded?.device)
        assertEquals(0xFFFF_FFFFL, decoded?.nonce)
    }

    @Test
    fun stage1MapsPlatformEntropyExactlyLikeAndroid() {
        val decision = NikonGpsPairingHandshake.begin(
            NikonGpsPairingEntropy(
                device = 0x89AB_CDEFu.toInt(),
                timestamp = 0x0123_4567_89AB_CDEFL,
                nonce = 0xFEDC_BA98u.toInt(),
            ),
        )

        assertEquals(NikonGpsPairingAction.SEND_STAGE1, decision.action)
        assertEquals(
            NikonGpsPairingPacket(
                stage = 1,
                timestamp = 0x0123_4567_89AB_CDEFL,
                device = 0x89AB_CD01L,
                nonce = 0xFEDC_BA98L,
            ),
            decision.packetToWrite,
        )
        assertEquals(decision.packetToWrite, decision.state.stage1)
        assertFalse(decision.state.stage3Sent)
        assertFalse(decision.state.stage4Accepted)
    }

    @Test
    fun fakeCipherDrivesStage2Stage3AndStage4Transitions() {
        val started = NikonGpsPairingHandshake.begin(
            NikonGpsPairingEntropy(device = 0, timestamp = 0, nonce = 0),
        )
        val stage2 = NikonGpsPairingPacket(
            stage = 2,
            timestamp = 0,
            // These two values authenticate salt[0] when the fake cipher returns its input.
            device = 0xE065_4271L,
            nonce = 0x5AD2_3501L,
        )

        val stage3 = NikonGpsPairingHandshake.advance(started.state, stage2, IDENTITY_CIPHER)

        assertEquals(NikonGpsPairingAction.SEND_STAGE3, stage3.action)
        assertTrue(stage3.state.stage3Sent)
        assertEquals(
            NikonGpsPairingPacket(
                stage = 3,
                timestamp = 0,
                device = 0xE065_4271L,
                nonce = 0x5AD2_3501L,
            ),
            stage3.packetToWrite,
        )

        val replay = NikonGpsPairingHandshake.advance(stage3.state, stage2, FAIL_IF_CALLED_CIPHER)
        assertEquals(NikonGpsPairingAction.IGNORE, replay.action)
        assertEquals(stage3.state, replay.state)

        val incomingStage3 = NikonGpsPairingHandshake.advance(
            started.state,
            NikonGpsPairingPacket(stage = 3, timestamp = 0, device = 0, nonce = 0),
            FAIL_IF_CALLED_CIPHER,
        )
        assertEquals(NikonGpsPairingAction.IGNORE, incomingStage3.action)
        assertEquals(started.state, incomingStage3.state)

        val acceptedStage4 = NikonGpsPairingHandshake.advance(
            // Preserve Android's tolerant transition even when stage 2 was not observed.
            state = started.state,
            incoming = NikonGpsPairingPacket(stage = 4, timestamp = 7, device = 8, nonce = 9),
            encryptor = FAIL_IF_CALLED_CIPHER,
        )
        assertEquals(NikonGpsPairingAction.ACCEPT_STAGE4, acceptedStage4.action)
        assertTrue(acceptedStage4.state.stage4Accepted)
        assertEquals(started.state.stage1, acceptedStage4.state.stage1)
        assertFalse(acceptedStage4.state.stage3Sent)
    }

    @Test
    fun invalidStage2AuthenticationIsRejectedWithoutAdvancing() {
        val started = NikonGpsPairingHandshake.begin(
            NikonGpsPairingEntropy(device = 1, timestamp = 2, nonce = 3),
        )
        val invalidStage2 = NikonGpsPairingPacket(stage = 2, timestamp = 4, device = 5, nonce = 6)

        val rejected = NikonGpsPairingHandshake.advance(started.state, invalidStage2, IDENTITY_CIPHER)

        assertEquals(NikonGpsPairingAction.REJECT_STAGE2, rejected.action)
        assertEquals(started.state, rejected.state)
        assertNull(rejected.packetToWrite)
    }

    private companion object {
        val IDENTITY_CIPHER = NikonGpsPairingBlockEncryptor { block -> block.copyOf() }
        val FAIL_IF_CALLED_CIPHER = NikonGpsPairingBlockEncryptor {
            error("cipher must not be called for this transition")
        }
    }
}
