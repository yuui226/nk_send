package com.ztransfer.viewmodel

import kotlin.math.abs

/** Platform-neutral photo metadata. Missing or unreadable EXIF values remain null. */
data class PhotoExif(
    val aperture: String?,
    val shutterSpeed: String?,
    val iso: String?,
    val focalLength: String?,
    val dateTime: String? = null,
    val lensModel: String? = null,
    /** Non-zero exposure compensation intent recorded by the camera, e.g. "+0.7 EV". */
    val exposureCompensation: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val altitudeMeters: Double? = null,
    val address: String? = null,
)

fun exposureCompensationText(
    value: Float?,
    formatOneDecimal: (Float) -> String,
): String? {
    val ev = value?.takeIf(Float::isFinite) ?: return null
    if (abs(ev) < 0.05f) return null
    return (if (ev > 0f) "+" else "") + formatOneDecimal(ev) + " EV"
}
