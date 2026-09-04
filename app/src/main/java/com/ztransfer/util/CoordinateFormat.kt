package com.ztransfer.util

import com.ztransfer.format.formatDecimalDegreeCoordinatesText
import com.ztransfer.format.formatDecimalDegreeLatitudeText
import com.ztransfer.format.formatDecimalDegreeLongitudeText
import java.util.Locale

/**
 * Human-readable decimal-degree coordinates. Hemispheres replace signed values so the result is
 * immediately recognizable outside the app while remaining compact enough for photo borders.
 */
internal fun formatDecimalDegreeCoordinates(
    latitude: Double,
    longitude: Double,
    fractionDigits: Int,
): String {
    return formatDecimalDegreeCoordinatesText(
        latitude = latitude,
        longitude = longitude,
        fractionDigits = fractionDigits,
        renderFixedDecimal = ::renderUsFixedDecimal,
    )
}

internal fun formatDecimalDegreeLatitude(latitude: Double, fractionDigits: Int): String =
    formatDecimalDegreeLatitudeText(
        latitude = latitude,
        fractionDigits = fractionDigits,
        renderFixedDecimal = ::renderUsFixedDecimal,
    )

internal fun formatDecimalDegreeLongitude(longitude: Double, fractionDigits: Int): String =
    formatDecimalDegreeLongitudeText(
        longitude = longitude,
        fractionDigits = fractionDigits,
        renderFixedDecimal = ::renderUsFixedDecimal,
    )

private fun renderUsFixedDecimal(value: Double, fractionDigits: Int): String =
    String.format(Locale.US, "%.${fractionDigits}f", value)
