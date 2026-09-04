package com.ztransfer.protocol

import com.ztransfer.test.byteValues
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PtpIpPacketCodecTest {
    @Test
    fun emptyPongPacketMatchesTheWireVector() {
        val packet = PtpIpPacketCodec.encode(PtpConstants.PONG)

        assertContentEquals(
            byteValues(0x08, 0, 0, 0, 0x0E, 0, 0, 0),
            packet,
        )
        assertEquals(8, PtpIpPacketCodec.readLength(packet))
        assertEquals(PtpConstants.PONG, PtpIpPacketCodec.readType(packet))
    }

    @Test
    fun eventPacketWithPayloadMatchesTheWireVector() {
        val payload = byteValues(
            0x08, 0x40,
            0x44, 0x33, 0x22, 0x11,
            0x88, 0x77, 0x66, 0x55,
        )

        val packet = PtpIpPacketCodec.encode(PtpConstants.EVENT, payload)

        assertContentEquals(
            byteValues(
                0x12, 0, 0, 0,
                0x08, 0, 0, 0,
                0x08, 0x40,
                0x44, 0x33, 0x22, 0x11,
                0x88, 0x77, 0x66, 0x55,
            ),
            packet,
        )
        assertEquals(18, PtpIpPacketCodec.readLength(packet))
        assertEquals(PtpConstants.EVENT, PtpIpPacketCodec.readType(packet))
    }

    @Test
    fun packetLengthValidationKeepsExistingInclusiveBounds() {
        assertFalse(PtpIpPacketCodec.isValidLength(7))
        assertTrue(PtpIpPacketCodec.isValidLength(8))
        assertTrue(PtpIpPacketCodec.isValidLength(PtpIpPacketCodec.MAX_PACKET_SIZE))
        assertFalse(PtpIpPacketCodec.isValidLength(PtpIpPacketCodec.MAX_PACKET_SIZE + 1))
        assertFalse(PtpIpPacketCodec.isValidLength(-1))
        assertFails { PtpIpPacketCodec.readType(ByteArray(7)) }
    }

    @Test
    fun littleEndianPrimitivesKeepSignedAndUnsignedBitPatterns() {
        val bytes = ByteArray(14)
        bytes.writeUInt16LittleEndian(0, 0xA005)
        bytes.writeInt32LittleEndian(2, 0x89ABCDEF.toInt())
        bytes.writeInt64LittleEndian(6, 0x0123456789ABCDEFL)

        assertContentEquals(
            byteValues(
                0x05, 0xA0,
                0xEF, 0xCD, 0xAB, 0x89,
                0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01,
            ),
            bytes,
        )
        assertEquals(0xA005, bytes.readUInt16LittleEndian(0))
        assertEquals(0x89ABCDEF.toInt(), bytes.readInt32LittleEndian(2))
        assertEquals(0x89ABCDEFL, bytes.readUInt32LittleEndian(2))
        assertEquals(0x0123456789ABCDEFL, bytes.readInt64LittleEndian(6))
    }

}
