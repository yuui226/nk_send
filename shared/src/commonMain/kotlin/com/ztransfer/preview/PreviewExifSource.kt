package com.ztransfer.preview

/** Previews intentionally have different fallback/Float formatting semantics from photo frames. */
enum class PreviewExifTag {
    F_NUMBER, APERTURE_VALUE, EXPOSURE_TIME, PHOTOGRAPHIC_SENSITIVITY, EXPOSURE_BIAS_VALUE,
    FOCAL_LENGTH, LENS_MODEL, DATETIME_ORIGINAL, DATETIME_DIGITIZED, DATETIME,
    GPS_LATITUDE, GPS_LATITUDE_REF, GPS_LONGITUDE, GPS_LONGITUDE_REF,
}

interface PreviewExifSource {
    fun attribute(tag: PreviewExifTag): String?
    fun decodedCoordinates(): DoubleArray?
    fun decodedAltitude(): Double
}

fun interface PreviewExifDecimalFormatter {
    /** EV alone uses ROOT; other fields preserve the user's default format locale. */
    fun fixed(value: Float, fractionDigits: Int, rootLocale: Boolean): String
}

/** Owned values for a Native metadata reader; no camera/cache/filesystem ownership. */
class NativePreviewExifValues : PreviewExifSource {
    private val attributes = mutableMapOf<PreviewExifTag, String>()
    private var coordinates: DoubleArray? = null
    var altitudeMeters: Double = Double.NaN

    fun set(tag: PreviewExifTag, value: String?) {
        if (value == null) attributes.remove(tag) else attributes[tag] = value
    }
    fun setDecodedCoordinates(latitude: Double, longitude: Double) {
        coordinates = doubleArrayOf(latitude, longitude)
    }
    /** ImageIO has already decoded rational DMS into Double degrees. Keep that precision.
     * AndroidX 1.3.7 accepts uppercase N/S/E/W only in its preferred decoded pair; other refs
     * leave the original preview's raw/Float fallback in charge. Missing one invalidates the pair.
     */
    fun setImageIoCoordinates(latitude: Double, latitudeReference: String?, longitude: Double, longitudeReference: String?) {
        val validReferences = setOf("N", "S", "E", "W")
        coordinates = if (latitudeReference in validReferences && longitudeReference in validReferences &&
            !latitude.isNaN() && !longitude.isNaN()) {
            fun signed(value: Double, reference: String?) = if (reference == "S" || reference == "W") -value else value
            doubleArrayOf(signed(latitude, latitudeReference), signed(longitude, longitudeReference))
        } else null
    }
    /** Match ExifInterface.getAltitude(NaN): an altitude without its reference is not decoded. */
    fun setImageIoAltitude(value: Double, reference: Int) {
        altitudeMeters = if (value >= 0.0 && reference >= 0) value * (if (reference == 1) -1 else 1) else Double.NaN
    }
    override fun attribute(tag: PreviewExifTag): String? = attributes[tag]
    override fun decodedCoordinates(): DoubleArray? = coordinates?.copyOf()
    override fun decodedAltitude(): Double = altitudeMeters
}

object NativePreviewExifBridge {
    fun metadata(values: NativePreviewExifValues, formatter: PreviewExifDecimalFormatter) =
        parsePreviewExif(values, formatter)
}
