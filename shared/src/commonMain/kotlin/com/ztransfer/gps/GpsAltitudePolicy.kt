package com.ztransfer.gps

import kotlin.math.abs

internal const val GPS_PROVIDER_NAME = "gps"
internal const val GPS_ALTITUDE_MAX_AGE_MS = 2 * 60_000L
internal const val GPS_ALTITUDE_MAX_DISTANCE_METERS = 1_000f
internal const val GPS_FALLBACK_ALTITUDE_METERS = 0.0

/** Network providers on some phones mark a synthetic 0 m value as present. */
fun trustedGpsAltitude(
    provider: String?,
    hasAltitude: Boolean,
    altitudeMeters: Double,
): Double? = altitudeMeters.takeIf {
    provider == GPS_PROVIDER_NAME && hasAltitude && altitudeMeters.isFinite()
}

fun canReuseGpsAltitude(
    nowMs: Long,
    fixTimeMs: Long,
    distanceMeters: Float,
): Boolean = fixTimeMs > 0L &&
    abs(nowMs - fixTimeMs) <= GPS_ALTITUDE_MAX_AGE_MS &&
    distanceMeters.isFinite() &&
    distanceMeters <= GPS_ALTITUDE_MAX_DISTANCE_METERS

/** Coordinates must not be blocked indoors just because Android has no trustworthy altitude. */
fun cameraAltitudeForWrite(trustedAltitudeMeters: Double?): Double =
    trustedAltitudeMeters ?: GPS_FALLBACK_ALTITUDE_METERS

/** The first trustworthy altitude after a fallback write should bypass the normal GEO cadence. */
fun shouldForceTrustedAltitudeRefresh(
    previousTrustedAltitudeMeters: Double?,
    currentTrustedAltitudeMeters: Double?,
): Boolean = previousTrustedAltitudeMeters == null && currentTrustedAltitudeMeters != null
