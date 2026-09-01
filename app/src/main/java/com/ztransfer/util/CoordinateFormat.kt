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
    return "${formatDecimalDegreeLatitude(latitude, fractionDigits)}, " +
        formatDecimalDegreeLongitude(longitude, fractionDigits)
}

internal fun formatDecimalDegreeLatitude(latitude: Double, fractionDigits: Int): String =
    formatDecimalDegreeValue(
        value = latitude,
        maximum = 90.0,
        positiveHemisphere = "N",
        negativeHemisphere = "S",
        fractionDigits = fractionDigits,
        errorLabel = "latitude",
    )

internal fun formatDecimalDegreeLongitude(longitude: Double, fractionDigits: Int): String =
    formatDecimalDegreeValue(
        value = longitude,
        maximum = 180.0,
        positiveHemisphere = "E",
        negativeHemisphere = "W",
        fractionDigits = fractionDigits,
        errorLabel = "longitude",
    )

private fun formatDecimalDegreeValue(
    value: Double,
    maximum: Double,
    positiveHemisphere: String,
    negativeHemisphere: String,
    fractionDigits: Int,
    errorLabel: String,
): String {
    require(value.isFinite() && value in -maximum..maximum) { "$errorLabel out of range" }
    require(fractionDigits in 0..8) { "fractionDigits out of range" }
    val hemisphere = if (value < 0.0) negativeHemisphere else positiveHemisphere
    return String.format(Locale.US, "%.${fractionDigits}f°%s", abs(value), hemisphere)
}
