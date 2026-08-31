package com.ztransfer.gps

import kotlin.math.abs

internal const val GPS_PROVIDER_NAME = "gps"
internal const val GPS_ALTITUDE_MAX_AGE_MS = 2 * 60_000L
internal const val GPS_ALTITUDE_MAX_DISTANCE_METERS = 1_000f

/** Network providers on some phones mark a synthetic 0 m value as present. */
internal fun trustedGpsAltitude(
    provider: String?,
    hasAltitude: Boolean,
    altitudeMeters: Double,
): Double? = altitudeMeters.takeIf {
    provider == GPS_PROVIDER_NAME && hasAltitude && altitudeMeters.isFinite()
}

internal fun canReuseGpsAltitude(
    nowMs: Long,
    fixTimeMs: Long,
    distanceMeters: Float,
): Boolean = fixTimeMs > 0L &&
    abs(nowMs - fixTimeMs) <= GPS_ALTITUDE_MAX_AGE_MS &&
    distanceMeters.isFinite() &&
    distanceMeters <= GPS_ALTITUDE_MAX_DISTANCE_METERS
