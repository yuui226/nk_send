package com.ztransfer.frame

import kotlin.math.pow

/** Platform-neutral EXIF values collected by the Android ExifInterface or the future iOS reader. */
data class PhotoFrameExifValues(
    val make: String? = null,
    val model: String? = null,
    val fNumber: Double = Double.NaN,
    val apertureValue: Double = Double.NaN,
    val exposureTimeSeconds: Double = Double.NaN,
    val shutterSpeedValue: Double = Double.NaN,
    val iso: String? = null,
    val focalLength: Double = Double.NaN,
    val lensModel: String? = null,
    val dateTimeOriginal: String? = null,
    val dateTimeDigitized: String? = null,
    val dateTime: String? = null,
    val decodedLatitude: Double? = null,
    val decodedLongitude: Double? = null,
    val latitudeDms: String? = null,
    val latitudeReference: String? = null,
    val longitudeDms: String? = null,
    val longitudeReference: String? = null,
    val decodedAltitudeMeters: Double = Double.NaN,
    val altitudeRational: String? = null,
    val altitudeBelowSeaLevel: Boolean = false,
)

/**
 * Applies the original EXIF fallback and normalization policy. Number rendering is injected so
 * Android can retain its Locale.US rounding and iOS can provide an equivalent formatter.
 */
fun photoFrameMetadataFromExifValues(
    values: PhotoFrameExifValues,
    formatAperture: (Double) -> String,
    formatShutter: (Double) -> String,
    formatFocalLength: (Double) -> String,
): PhotoFrameMetadata {
    val fNumber = values.fNumber
        .takeIf { it.isFinite() && it > 0.0 }
        ?: values.apertureValue
            .takeIf(Double::isFinite)
            ?.let { 2.0.pow(it / 2.0) }
    val exposureSeconds = values.exposureTimeSeconds
        .takeIf { it.isFinite() && it > 0.0 }
        ?: values.shutterSpeedValue
            .takeIf(Double::isFinite)
            ?.let { 2.0.pow(-it) }
    val latitude = (values.decodedLatitude
        ?.takeIf { it.isFinite() && it != 0.0 && it in -90.0..90.0 }
        ?: parsePhotoFrameExifCoordinate(values.latitudeDms, values.latitudeReference))
        ?.takeIf { it.isFinite() && it in -90.0..90.0 }
    val longitude = (values.decodedLongitude
        ?.takeIf { it.isFinite() && it != 0.0 && it in -180.0..180.0 }
        ?: parsePhotoFrameExifCoordinate(values.longitudeDms, values.longitudeReference))
        ?.takeIf { it.isFinite() && it in -180.0..180.0 }
    val altitude = values.decodedAltitudeMeters
        .takeIf { it.isFinite() && it != 0.0 }
        ?: parsePhotoFrameExifRational(values.altitudeRational.orEmpty())
            ?.takeIf { it.isFinite() && it != 0.0 }
            ?.let { if (values.altitudeBelowSeaLevel) -it else it }

    return PhotoFrameMetadata(
        make = values.make,
        model = values.model,
        aperture = fNumber?.let(formatAperture),
        shutter = exposureSeconds?.let(formatShutter),
        iso = normalizeIso(values.iso),
        focalLength = values.focalLength
            .takeIf { it.isFinite() && it > 0.0 }
            ?.let(formatFocalLength),
        lensModel = values.lensModel?.trim()?.takeIf(String::isNotEmpty),
        dateTime = sequenceOf(values.dateTimeOriginal, values.dateTimeDigitized, values.dateTime)
            .mapNotNull(::normalizeCaptureDateTime)
            .firstOrNull(),
        latitude = latitude,
        longitude = longitude,
        altitudeMeters = altitude,
        address = null,
    )
}

fun parsePhotoFrameExifCoordinate(value: String?, reference: String?): Double? {
    val parts = value
        ?.trim()
        ?.removePrefix("[")
        ?.removeSuffix("]")
        ?.split(Regex("[,;\\s]+"))
        ?.map { it.trim().trim('"', '\'') }
        ?.filter(String::isNotEmpty)
        ?: return null
    val absolute = when {
        parts.size == 1 -> parsePhotoFrameExifRational(parts[0]) ?: return null
        parts.size >= 3 -> {
            val degrees = parsePhotoFrameExifRational(parts[0]) ?: return null
            val minutes = parsePhotoFrameExifRational(parts[1]) ?: return null
            val seconds = parsePhotoFrameExifRational(parts[2]) ?: return null
            degrees + minutes / 60.0 + seconds / 3600.0
        }
        else -> return null
    }
    return if (reference.equals("S", ignoreCase = true) ||
        reference.equals("W", ignoreCase = true)
    ) -absolute else absolute
}

fun parsePhotoFrameExifRational(value: String): Double? {
    val pieces = value.split('/', limit = 2)
    if (pieces.size == 1) return pieces[0].toDoubleOrNull()
    val numerator = pieces[0].toDoubleOrNull() ?: return null
    val denominator = pieces[1].toDoubleOrNull()?.takeIf { it != 0.0 } ?: return null
    return numerator / denominator
}
