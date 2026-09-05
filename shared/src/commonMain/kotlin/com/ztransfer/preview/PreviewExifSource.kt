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
    override fun attribute(tag: PreviewExifTag): String? = attributes[tag]
    override fun decodedCoordinates(): DoubleArray? = coordinates?.copyOf()
    override fun decodedAltitude(): Double = altitudeMeters
}

object NativePreviewExifBridge {
    fun metadata(values: NativePreviewExifValues, formatter: PreviewExifDecimalFormatter) =
        parsePreviewExif(values, formatter)
}
