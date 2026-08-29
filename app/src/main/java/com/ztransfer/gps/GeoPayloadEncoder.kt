package com.ztransfer.gps

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.time.Instant
import java.time.ZoneOffset
import java.time.ZonedDateTime
import kotlin.math.abs
import kotlin.math.floor

/** Encodes Nikon's 41-byte Smart Device GEO packet without Android dependencies. */
object GeoPayloadEncoder {
    private const val HEADER = 0x007F

    fun encode(
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double,
        satellites: Int,
        timestamp: Instant = Instant.now(),
    ): ByteArray {
        require(latitude in -90.0..90.0) { "latitude out of range" }
        require(longitude in -180.0..180.0) { "longitude out of range" }
        val lat = coordinate(latitude, 'N', 'S', 90)
        val lon = coordinate(longitude, 'E', 'W', 180)
        val time = timestamp.atZone(ZoneOffset.UTC)
        val altitude = if (altitudeMeters.isFinite()) altitudeMeters else 0.0
        val altitudeRef = if (altitude < 0.0) 'M' else 'P'
        val altitudeAbs = abs(altitude).coerceAtMost(65535.0).toInt()

        return ByteBuffer.allocate(41).order(ByteOrder.LITTLE_ENDIAN).apply {
            putShort(HEADER.toShort())
            put(lat.direction.code.toByte())
            put(lat.degrees.toByte())
            put(lat.minutes.toByte())
            put(lat.subMinutes1.toByte())
            put(lat.subMinutes2.toByte())
            put(lon.direction.code.toByte())
            put(lon.degrees.toByte())
            put(lon.minutes.toByte())
            put(lon.subMinutes1.toByte())
            put(lon.subMinutes2.toByte())
            put(satellites.coerceIn(0, 99).toByte())
            put(altitudeRef.code.toByte())
            putShort(altitudeAbs.toShort())
            putShort(time.year.toShort())
            put(time.monthValue.toByte())
            put(time.dayOfMonth.toByte())
            put(time.hour.toByte())
            put(time.minute.toByte())
            put(time.second.toByte())
            put(0)
            put(1)
            put("WGS-84".toByteArray(Charsets.US_ASCII))
            repeat(10) { put(0) }
        }.array()
    }

    private data class Coordinate(
        val direction: Char,
        val degrees: Int,
        val minutes: Int,
        val subMinutes1: Int,
        val subMinutes2: Int,
    )

    private fun coordinate(
        decimal: Double,
        positive: Char,
        negative: Char,
        maxDegrees: Int,
    ): Coordinate {
        val absolute = abs(decimal)
        var degrees = floor(absolute).toInt().coerceAtMost(maxDegrees)
        var minuteValue = (absolute - degrees) * 60.0
        var minutes = floor(minuteValue).toInt()
        var sub1 = floor((minuteValue - minutes) * 100.0 + 1e-9).toInt()
        var sub2 = floor((((minuteValue - minutes) * 100.0) - sub1) * 100.0 + 1e-9).toInt()
        if (sub2 >= 100) sub2 = 99
        if (sub1 >= 100) sub1 = 99
        if (minutes >= 60) {
            minutes = 0
            degrees = (degrees + 1).coerceAtMost(maxDegrees)
        }
        return Coordinate(
            direction = if (decimal < 0.0) negative else positive,
            degrees = degrees,
            minutes = minutes,
            subMinutes1 = sub1,
            subMinutes2 = sub2,
        )
    }
}
