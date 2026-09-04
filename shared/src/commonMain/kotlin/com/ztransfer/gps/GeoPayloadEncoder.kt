package com.ztransfer.gps

import kotlin.math.abs
import kotlin.math.floor

/** Platform-neutral UTC fields written into a Nikon GEO packet. */
data class GeoUtcDateTime(
    val year: Int,
    val month: Int,
    val day: Int,
    val hour: Int,
    val minute: Int,
    val second: Int,
) {
    init {
        require(year in 0..0xFFFF) { "year out of range" }
        require(month in 1..12) { "month out of range" }
        require(day in 1..31) { "day out of range" }
        require(hour in 0..23) { "hour out of range" }
        require(minute in 0..59) { "minute out of range" }
        require(second in 0..59) { "second out of range" }
    }
}

/** Encodes Nikon's 41-byte Smart Device GEO packet without platform dependencies. */
object GeoPayloadEncoder {
    private const val PAYLOAD_SIZE = 41
    private const val HEADER = 0x007F
    private const val MAX_SATELLITES = 99
    private const val MAX_ALTITUDE_METERS = 65_535.0
    private const val RESERVED_ZERO_COUNT = 10
    private val DATUM = byteArrayOf(
        'W'.code.toByte(),
        'G'.code.toByte(),
        'S'.code.toByte(),
        '-'.code.toByte(),
        '8'.code.toByte(),
        '4'.code.toByte(),
    )

    fun encode(
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double,
        satellites: Int,
        timestamp: GeoUtcDateTime,
    ): ByteArray {
        require(latitude in -90.0..90.0) { "latitude out of range" }
        require(longitude in -180.0..180.0) { "longitude out of range" }
        val lat = coordinate(latitude, 'N', 'S', 90)
        val lon = coordinate(longitude, 'E', 'W', 180)
        val altitude = if (altitudeMeters.isFinite()) altitudeMeters else 0.0
        val altitudeRef = if (altitude < 0.0) 'M' else 'P'
        val altitudeAbs = abs(altitude).coerceAtMost(MAX_ALTITUDE_METERS).toInt()
        val payload = ByteArray(PAYLOAD_SIZE)
        var offset = 0

        fun put(value: Int) {
            payload[offset++] = value.toByte()
        }

        fun putUInt16LittleEndian(value: Int) {
            put(value)
            put(value ushr 8)
        }

        putUInt16LittleEndian(HEADER)
        put(lat.direction.code)
        put(lat.degrees)
        put(lat.minutes)
        put(lat.subMinutes1)
        put(lat.subMinutes2)
        put(lon.direction.code)
        put(lon.degrees)
        put(lon.minutes)
        put(lon.subMinutes1)
        put(lon.subMinutes2)
        put(satellites.coerceIn(0, MAX_SATELLITES))
        put(altitudeRef.code)
        putUInt16LittleEndian(altitudeAbs)
        putUInt16LittleEndian(timestamp.year)
        put(timestamp.month)
        put(timestamp.day)
        put(timestamp.hour)
        put(timestamp.minute)
        put(timestamp.second)
        put(0)
        put(1)
        DATUM.forEach { put(it.toInt()) }
        repeat(RESERVED_ZERO_COUNT) { put(0) }
        check(offset == PAYLOAD_SIZE)
        return payload
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
