package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

class PtpIpProtocolCodecTest {
    @Test
    fun legacyAndStandardInitRequestsMatchFixedWireVectors() {
        val ascendingGuid = bytes(
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
            0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
        )
        assertContentEquals(
            hex("2C00000001000000000102030405060708090A0B0C0D0E0F" +
                "4E0069006B006F006E0050005400500000000100"),
            PtpIpProtocolCodec.encodeLegacyInitCommandRequest(ascendingGuid, "NikonPTP"),
        )

        val persistentGuid = "0123456789abcdef".encodeToByteArray()
        assertContentEquals(
            hex("300000000100000030313233343536373839616263646566" +
                "5A005400720061006E007300660065007200000000000100"),
            PtpIpProtocolCodec.encodeStandardInitCommandRequest(persistentGuid, "ZTransfer"),
        )
    }

    @Test
    fun initAckAndEventInitPreserveConnectionIdentity() {
        val payload = hex("44332211000102030405060708090A0B0C0D0E0F")
        val ack = requireNotNull(PtpIpProtocolCodec.decodeInitCommandAck(payload))
        assertEquals(0x11223344, ack.connectionNumber)
        assertEquals("000102030405060708090a0b0c0d0e0f", ack.responderGuidHex)
        assertNull(PtpIpProtocolCodec.decodeInitCommandAck(null))
        assertEquals(null, requireNotNull(PtpIpProtocolCodec.decodeInitCommandAck(payload.copyOf(4))).responderGuidHex)
        assertEquals(null, requireNotNull(PtpIpProtocolCodec.decodeInitCommandAck(payload.copyOf(19))).responderGuidHex)
        assertFailsWith<IndexOutOfBoundsException> {
            PtpIpProtocolCodec.decodeInitCommandAck(payload.copyOf(3))
        }

        assertContentEquals(
            hex("0C0000000300000044332211"),
            PtpIpProtocolCodec.encodeInitEventRequest(0x11223344),
        )
    }

    @Test
    fun commandRequestMatchesWireVectorAndKeepsFiveParameterLimit() {
        assertContentEquals(
            hex("16000000060000000100000002104433221188776655"),
            PtpIpProtocolCodec.encodeCommandRequest(
                operationCode = PtpConstants.OPEN_SESSION,
                transactionId = 0x11223344,
                parameters = intArrayOf(0x55667788),
            ),
        )

        val limited = PtpIpProtocolCodec.encodeCommandRequest(
            operationCode = 0x90C4,
            transactionId = 7,
            parameters = intArrayOf(1, 2, 3, 4, 5, 6),
        )
        assertContentEquals(
            hex("260000000600000001000000C49007000000" +
                "0100000002000000030000000400000005000000"),
            limited,
        )
    }

    @Test
    fun commandWithDataMatchesThreeConcatenatedWirePackets() {
        assertContentEquals(
            hex(
                "16000000060000000200000016104433221188776655" +
                    "1400000009000000443322110300000000000000" +
                    "0F0000000C00000044332211AABBCC",
            ),
            PtpIpProtocolCodec.encodeCommandWithData(
                operationCode = 0x1016,
                transactionId = 0x11223344,
                data = bytes(0xAA, 0xBB, 0xCC),
                parameters = intArrayOf(0x55667788),
            ),
        )

        assertContentEquals(
            hex(
                "120000000600000002000000161000000000" +
                    "1400000009000000000000000000000000000000" +
                    "0C0000000C00000000000000",
            ),
            PtpIpProtocolCodec.encodeCommandWithData(
                operationCode = 0x1016,
                transactionId = 0,
                data = byteArrayOf(),
            ),
        )
    }

    @Test
    fun cancelEventAndResponseCompatibilityCasesStayFixed() {
        assertContentEquals(
            hex("0C0000000B00000044332211"),
            PtpIpProtocolCodec.encodeCancelRequest(0x11223344),
        )

        val event = requireNotNull(
            PtpIpProtocolCodec.decodeEvent(hex("05A0FFFFFFFFEFCDAB89")),
        )
        assertEquals(0xA005, event.code)
        assertEquals(0xFFFFFFFFL, event.transactionId)
        assertEquals(0x89ABCDEFL, event.firstParameter)
        assertEquals(0L, requireNotNull(PtpIpProtocolCodec.decodeEvent(hex("084044332211"))).firstParameter)
        assertEquals(0L, requireNotNull(PtpIpProtocolCodec.decodeEvent(hex("084044332211000000"))).firstParameter)
        assertNull(PtpIpProtocolCodec.decodeEvent(hex("0840443322")))

        assertEquals(
            0xA005,
            PtpIpProtocolCodec.decodeResponseCode(hex("05A0EFCDAB89")),
        )
        assertEquals(0, PtpIpProtocolCodec.decodeResponseCode(bytes(0x05, 0xA0), payloadLength = 1))
        assertFailsWith<IndexOutOfBoundsException> {
            PtpIpProtocolCodec.decodeResponseCode(bytes(0x05))
        }
    }

    @Test
    fun initRequestRejectsNonGuid() {
        assertFailsWith<IllegalArgumentException> {
            PtpIpProtocolCodec.encodeStandardInitCommandRequest(ByteArray(15), "ZTransfer")
        }
    }

    private fun hex(value: String): ByteArray {
        require(value.length % 2 == 0)
        return ByteArray(value.length / 2) { index ->
            value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }

    private fun bytes(vararg values: Int): ByteArray =
        ByteArray(values.size) { index -> values[index].toByte() }
}
