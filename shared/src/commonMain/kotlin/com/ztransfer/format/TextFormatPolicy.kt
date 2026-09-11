package com.ztransfer.format

/**
 * Applies the platform's fixed-decimal renderer after common code has selected the exact value,
 * precision, unit, and threshold branch. Android keeps Locale.US formatting; Apple can use its
 * native locale-independent formatter without duplicating these rules.
 */
fun formatFileSizeText(
    bytes: Long,
    renderFixedDecimal: (value: Double, fractionDigits: Int) -> String,
): String = when {
    bytes < 1_024L -> "$bytes B"
    bytes < 1_048_576L -> "${bytes / 1_024L} KB"
    bytes < 1_073_741_824L ->
        "${renderFixedDecimal(bytes / 1_048_576.0, 1)} MB"
    else -> "${renderFixedDecimal(bytes / 1_073_741_824.0, 2)} GB"
}

fun formatTransferSpeedText(
    bytesPerSecond: Long,
    renderFixedDecimal: (value: Double, fractionDigits: Int) -> String,
): String = when {
    bytesPerSecond < 1_024L -> "$bytesPerSecond B/s"
    bytesPerSecond < 1_048_576L ->
        "${renderFixedDecimal(bytesPerSecond / 1_024.0, 1)} KB/s"
    else -> "${renderFixedDecimal(bytesPerSecond / 1_048_576.0, 1)} MB/s"
}

fun formatDurationText(
    milliseconds: Long,
    renderFixedDecimal: (value: Double, fractionDigits: Int) -> String,
): String {
    if (milliseconds < 0L) return "0.0s"
    val totalSeconds = milliseconds / 1_000.0
    return if (totalSeconds < 60.0) {
        "${renderFixedDecimal(totalSeconds, 1)}s"
    } else {
        val minutes = milliseconds / 60_000L
        val seconds = milliseconds % 60_000L / 1_000L
        "${minutes}m${seconds.toString().padStart(2, '0')}s"
    }
}

fun formatDecimalDegreeCoordinatesText(
    latitude: Double,
    longitude: Double,
    fractionDigits: Int,
    renderFixedDecimal: (value: Double, fractionDigits: Int) -> String,
): String = "${formatDecimalDegreeLatitudeText(latitude, fractionDigits, renderFixedDecimal)}, " +
    formatDecimalDegreeLongitudeText(longitude, fractionDigits, renderFixedDecimal)

fun formatDecimalDegreeLatitudeText(
    latitude: Double,
    fractionDigits: Int,
    renderFixedDecimal: (value: Double, fractionDigits: Int) -> String,
): String = formatDecimalDegreeValueText(
    value = latitude,
    maximum = 90.0,
    positiveHemisphere = "N",
    negativeHemisphere = "S",
    fractionDigits = fractionDigits,
    errorLabel = "latitude",
    renderFixedDecimal = renderFixedDecimal,
)

fun formatDecimalDegreeLongitudeText(
    longitude: Double,
    fractionDigits: Int,
    renderFixedDecimal: (value: Double, fractionDigits: Int) -> String,
): String = formatDecimalDegreeValueText(
    value = longitude,
    maximum = 180.0,
    positiveHemisphere = "E",
    negativeHemisphere = "W",
    fractionDigits = fractionDigits,
    errorLabel = "longitude",
    renderFixedDecimal = renderFixedDecimal,
)

private fun formatDecimalDegreeValueText(
    value: Double,
    maximum: Double,
    positiveHemisphere: String,
    negativeHemisphere: String,
    fractionDigits: Int,
    errorLabel: String,
    renderFixedDecimal: (value: Double, fractionDigits: Int) -> String,
): String {
    require(value.isFinite() && value in -maximum..maximum) { "$errorLabel out of range" }
    require(fractionDigits in 0..8) { "fractionDigits out of range" }
    val hemisphere = if (value < 0.0) negativeHemisphere else positiveHemisphere
    return "${renderFixedDecimal(kotlin.math.abs(value), fractionDigits)}°$hemisphere"
}
