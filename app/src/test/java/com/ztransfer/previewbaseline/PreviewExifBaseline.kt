package com.ztransfer.previewbaseline

import com.ztransfer.preview.PreviewExifSource
import com.ztransfer.preview.PreviewExifTag
import com.ztransfer.viewmodel.PhotoExif
import com.ztransfer.viewmodel.formatExposureCompensation

private fun parseRational(raw: String?): Float? {
    if (raw == null) return null
    val slash = raw.indexOf('/')
    return if (slash > 0) {
        val num = raw.substring(0, slash).toFloatOrNull() ?: return null
        val den = raw.substring(slash + 1).toFloatOrNull() ?: return null
        if (den == 0f) null else num / den
    } else {
        raw.toFloatOrNull()
    }
}
internal fun parseExifImpl(exif: PreviewExifSource): PhotoExif? {
    // 光圈：优先 TAG_F_NUMBER（0x829D，直接的 f 值 RATIONAL，多数尼康机身填这个）；
    // 缺失时回退 TAG_APERTURE_VALUE（APEX 编码，f = 2^(apex/2)）。两者都试以免漏显。
    val fNumber = parseRational(exif.attribute(PreviewExifTag.F_NUMBER))
        ?: parseRational(exif.attribute(PreviewExifTag.APERTURE_VALUE))
            ?.let { apex -> Math.pow(2.0, apex.toDouble() / 2.0).toFloat() }
    val aperture = fNumber?.let { f -> if (f % 1f < 0.05f) "f/%.0f".format(f) else "f/%.1f".format(f) }

    // 快门：TAG_EXPOSURE_TIME 直接返回秒数 RATIONAL（如 "1/250"）
    val exposureTime = parseRational(exif.attribute(PreviewExifTag.EXPOSURE_TIME))
    val shutter = exposureTime?.let { sec ->
        if (sec >= 1f) "%.1fs".format(sec) else "1/%.0f".format(1f / sec)
    }

    // ISO：SHORT 整数
    val isoRaw = exif.attribute(PreviewExifTag.PHOTOGRAPHIC_SENSITIVITY)
    val iso = if (isoRaw != null) "ISO$isoRaw" else null

    // Exposure compensation is the photographer's metering intent and cannot be inferred from
    // the final aperture/shutter/ISO values. Keep the common 0 EV case out of the preview bar.
    val exposureCompensation = formatExposureCompensation(
        parseRational(exif.attribute(PreviewExifTag.EXPOSURE_BIAS_VALUE)),
    )

    // 焦距：RATIONAL mm
    val focal = parseRational(exif.attribute(PreviewExifTag.FOCAL_LENGTH))
        ?.let { "%.0fmm".format(it) }
    val lensModel = exif.attribute(PreviewExifTag.LENS_MODEL)
        ?.trim()
        ?.takeIf(String::isNotEmpty)

    // 图像尺寸：SHORT/LONG 整数
    val dateTime = sequenceOf(
        PreviewExifTag.DATETIME_ORIGINAL,
        PreviewExifTag.DATETIME_DIGITIZED,
        PreviewExifTag.DATETIME,
    ).mapNotNull(exif::attribute)
        .firstOrNull { it.isNotBlank() }

    val coordinates = exif.decodedCoordinates()
    val latitude = (coordinates?.getOrNull(0)
        ?.takeIf { it.isFinite() && it != 0.0 && it in -90.0..90.0 }
        ?: parseGpsCoordinate(
            exif.attribute(PreviewExifTag.GPS_LATITUDE),
            exif.attribute(PreviewExifTag.GPS_LATITUDE_REF),
        ))?.takeIf { it.isFinite() && it in -90.0..90.0 }
    val longitude = (coordinates?.getOrNull(1)
        ?.takeIf { it.isFinite() && it != 0.0 && it in -180.0..180.0 }
        ?: parseGpsCoordinate(
            exif.attribute(PreviewExifTag.GPS_LONGITUDE),
            exif.attribute(PreviewExifTag.GPS_LONGITUDE_REF),
        ))?.takeIf { it.isFinite() && it in -180.0..180.0 }
    val validCoordinates = latitude != null && longitude != null
    val altitude = exif.decodedAltitude()
        .takeIf { it.isFinite() && it != 0.0 }

    return PhotoExif(
        aperture = aperture,
        shutterSpeed = shutter,
        iso = iso,
        focalLength = focal,
        dateTime = dateTime,
        lensModel = lensModel,
        exposureCompensation = exposureCompensation,
        latitude = latitude.takeIf { validCoordinates },
        longitude = longitude.takeIf { validCoordinates },
        altitudeMeters = altitude,
    )
}
private fun parseGpsCoordinate(value: String?, reference: String?): Double? {
    val parts = value
        ?.trim()
        ?.removePrefix("[")
        ?.removeSuffix("]")
        ?.split(Regex("[,;\\s]+"))
        ?.map { it.trim().trim('"', '\'') }
        ?.filter(String::isNotEmpty)
        ?: return null
    val absolute = when {
        parts.size == 1 -> parseRational(parts[0])?.toDouble() ?: return null
        parts.size >= 3 -> {
            val degrees = parseRational(parts[0])?.toDouble() ?: return null
            val minutes = parseRational(parts[1])?.toDouble() ?: return null
            val seconds = parseRational(parts[2])?.toDouble() ?: return null
            degrees + minutes / 60.0 + seconds / 3600.0
        }
        else -> return null
    }
    return if (reference.equals("S", ignoreCase = true) ||
        reference.equals("W", ignoreCase = true)
    ) -absolute else absolute
}
