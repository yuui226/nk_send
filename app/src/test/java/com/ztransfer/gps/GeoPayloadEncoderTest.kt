package com.ztransfer.gps

import java.time.Instant
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertArrayEquals
import org.junit.Test

class GeoPayloadEncoderTest {
    @Test
    fun encodesNikonGeoPacketShapeAndCoordinates() {
        val payload = GeoPayloadEncoder.encode(
            latitude = 39.9042,
            longitude = -116.4074,
            altitudeMeters = -12.5,
            satellites = 14,
            timestamp = Instant.parse("2025-01-02T03:04:05Z"),
        )

        assertEquals(41, payload.size)
        val buffer = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(0x007F.toShort(), buffer.short)
        assertEquals('N'.code.toByte(), buffer.get())
        assertEquals(39, buffer.get().toInt())
        assertEquals(54, buffer.get().toInt())
        buffer.get()
        buffer.get()
        assertEquals('W'.code.toByte(), buffer.get())
        assertEquals(116, buffer.get().toInt())
        assertEquals(24, buffer.get().toInt())
        buffer.get()
        buffer.get()
        assertEquals(14, buffer.get().toInt())
        assertEquals('M'.code.toByte(), buffer.get())
        assertEquals(12, buffer.short.toInt())
        assertEquals(2025, buffer.short.toInt())
        assertEquals(1, buffer.get().toInt())
        assertEquals(2, buffer.get().toInt())
        assertEquals(3, buffer.get().toInt())
        assertEquals(4, buffer.get().toInt())
        assertEquals(5, buffer.get().toInt())
        assertEquals(0, buffer.get().toInt())
        assertEquals(1, buffer.get().toInt())
        assertArrayEquals("WGS-84".toByteArray(), payload.copyOfRange(25, 31))
    }

    @Test
    fun clampsAltitudeToUnsignedProtocolRange() {
        val payload = GeoPayloadEncoder.encode(0.0, 0.0, 65_535.0, 120, Instant.EPOCH)
        val altitude = ByteBuffer.wrap(payload, 14, 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt() and 0xFFFF
        assertEquals(65_535, altitude)
        assertTrue(payload[13].toInt() == 'P'.code)
        assertEquals(99, payload[12].toInt())
    }
}
