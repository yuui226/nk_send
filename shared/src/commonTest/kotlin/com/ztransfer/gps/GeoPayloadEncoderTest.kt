package com.ztransfer.gps

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class GeoPayloadEncoderTest {
    @Test
    fun encodesNikonGeoPacketShapeAndCoordinates() {
        val payload = GeoPayloadEncoder.encode(
            latitude = 39.9042,
            longitude = -116.4074,
            altitudeMeters = -12.5,
            satellites = 14,
            timestamp = GeoUtcDateTime(2025, 1, 2, 3, 4, 5),
        )

        assertContentEquals(
            bytes(
                0x7F, 0x00,
                'N'.code, 39, 54, 25, 20,
                'W'.code, 116, 24, 44, 39,
                14,
                'M'.code, 12, 0,
                0xE9, 0x07, 1, 2, 3, 4, 5,
                0, 1,
                'W'.code, 'G'.code, 'S'.code, '-'.code, '8'.code, '4'.code,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            ),
            payload,
        )
        assertEquals(41, payload.size)
        assertEquals(0x007F, payload.readUInt16LittleEndian(0))
        assertEquals('N'.code.toByte(), payload[2])
        assertEquals(39, payload[3].toInt())
        assertEquals(54, payload[4].toInt())
        assertEquals('W'.code.toByte(), payload[7])
        assertEquals(116, payload[8].toInt())
        assertEquals(24, payload[9].toInt())
        assertEquals(14, payload[12].toInt())
        assertEquals('M'.code.toByte(), payload[13])
        assertEquals(12, payload.readUInt16LittleEndian(14))
        assertEquals(2025, payload.readUInt16LittleEndian(16))
        assertEquals(1, payload[18].toInt())
        assertEquals(2, payload[19].toInt())
        assertEquals(3, payload[20].toInt())
        assertEquals(4, payload[21].toInt())
        assertEquals(5, payload[22].toInt())
        assertEquals(0, payload[23].toInt())
        assertEquals(1, payload[24].toInt())
        assertContentEquals(bytes('W'.code, 'G'.code, 'S'.code, '-'.code, '8'.code, '4'.code), payload.copyOfRange(25, 31))
    }

    @Test
    fun clampsAltitudeAndSatellitesToProtocolRanges() {
        val payload = GeoPayloadEncoder.encode(
            latitude = 0.0,
            longitude = 0.0,
            altitudeMeters = 65_535.0,
            satellites = 120,
            timestamp = GeoUtcDateTime(1970, 1, 1, 0, 0, 0),
        )

        assertContentEquals(
            bytes(
                0x7F, 0x00,
                'N'.code, 0, 0, 0, 0,
                'E'.code, 0, 0, 0, 0,
                99,
                'P'.code, 0xFF, 0xFF,
                0xB2, 0x07, 1, 1, 0, 0, 0,
                0, 1,
                'W'.code, 'G'.code, 'S'.code, '-'.code, '8'.code, '4'.code,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            ),
            payload,
        )
        assertEquals(65_535, payload.readUInt16LittleEndian(14))
        assertTrue(payload[13].toInt() == 'P'.code)
        assertEquals(99, payload[12].toInt())
    }

    private fun ByteArray.readUInt16LittleEndian(offset: Int): Int =
        (this[offset].toInt() and 0xFF) or
            ((this[offset + 1].toInt() and 0xFF) shl 8)

    private fun bytes(vararg values: Int): ByteArray =
        ByteArray(values.size) { index -> values[index].toByte() }
}
