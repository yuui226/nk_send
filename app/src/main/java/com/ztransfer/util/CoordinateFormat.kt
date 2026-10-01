package com.ztransfer.util

import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToLong

/** Camera-style degrees and decimal minutes, with three decimal places in the minutes. */
internal fun formatDegreesMinutesCoordinates(latitude: Double, longitude: Double): String =
    "${formatDegreesMinutesLatitude(latitude)}, ${formatDegreesMinutesLongitude(longitude)}"

internal fun formatDegreesMinutesLatitude(latitude: Double): String =
    formatDegreesMinutesValue(latitude, 90.0, "N", "S", "latitude")

internal fun formatDegreesMinutesLongitude(longitude: Double): String =
    formatDegreesMinutesValue(longitude, 180.0, "E", "W", "longitude")

private fun formatDegreesMinutesValue(
    value: Double,
    maximum: Double,
    positiveHemisphere: String,
    negativeHemisphere: String,
    errorLabel: String,
): String {
    require(value.isFinite() && value in -maximum..maximum) { "$errorLabel out of range" }
    val hemisphere = if (value < 0.0) negativeHemisphere else positiveHemisphere
    // Round the total first: 59.9995 minutes must carry into the next degree, never show 60.000.
    val thousandthsOfMinutes = (abs(value) * 60_000).roundToLong()
    val degrees = thousandthsOfMinutes / 60_000
    val minutes = (thousandthsOfMinutes % 60_000) / 1_000
    val fraction = thousandthsOfMinutes % 1_000
    return String.format(Locale.US, "%s %d°%02d.%03d'", hemisphere, degrees, minutes, fraction)
}
