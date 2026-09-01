package com.ztransfer.util

import java.util.Locale
import kotlin.math.abs

/**
 * Human-readable decimal-degree coordinates. Hemispheres replace signed values so the result is
 * immediately recognizable outside the app while remaining compact enough for photo borders.
 */
internal fun formatDecimalDegreeCoordinates(
    latitude: Double,
    longitude: Double,
    fractionDigits: Int,
): String {
    require(latitude.isFinite() && latitude in -90.0..90.0) { "latitude out of range" }
    require(longitude.isFinite() && longitude in -180.0..180.0) { "longitude out of range" }
    require(fractionDigits in 0..8) { "fractionDigits out of range" }

    val latitudeHemisphere = if (latitude < 0.0) "S" else "N"
    val longitudeHemisphere = if (longitude < 0.0) "W" else "E"
    val coordinatePattern = "%.${fractionDigits}f°%s, %.${fractionDigits}f°%s"
    return String.format(
        Locale.US,
        coordinatePattern,
        abs(latitude),
        latitudeHemisphere,
        abs(longitude),
        longitudeHemisphere,
    )
}
