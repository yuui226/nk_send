package com.ztransfer.util

import androidx.exifinterface.media.ExifInterface

/** Location from the same original photo, never from the phone's current position. */
internal data class PhotoCaptureLocation private constructor(
    val latitude: Double,
    val longitude: Double,
    val altitudeMeters: Double?,
) {
    companion object {
        fun from(latitude: Double?, longitude: Double?, altitudeMeters: Double?): PhotoCaptureLocation? {
            if (latitude == null || longitude == null || !latitude.isFinite() || !longitude.isFinite() ||
                latitude !in -90.0..90.0 || longitude !in -180.0..180.0 ||
                (latitude == 0.0 && longitude == 0.0)
            ) return null
            return PhotoCaptureLocation(latitude, longitude, altitudeMeters?.takeIf { it.isFinite() })
        }

        fun read(exif: ExifInterface): PhotoCaptureLocation? {
            val coordinates = exif.latLong ?: return null
            return from(coordinates[0], coordinates[1], exif.getAltitude(Double.NaN))
        }
    }

    /** Only fill missing GPS; preserve the original rational fields whenever they exist. */
    fun fillMissing(exif: ExifInterface): Boolean {
        if (read(exif) != null) return false
        exif.setLatLong(latitude, longitude)
        // An altitude without a valid coordinate pair is not a reliable location snapshot.
        exif.setAttribute(ExifInterface.TAG_GPS_ALTITUDE, null)
        exif.setAttribute(ExifInterface.TAG_GPS_ALTITUDE_REF, null)
        altitudeMeters?.let(exif::setAltitude)
        return true
    }
}
