package com.ztransfer.viewmodel

import androidx.exifinterface.media.ExifInterface
import com.ztransfer.preview.PreviewExifSource
import com.ztransfer.preview.PreviewExifTag
import com.ztransfer.preview.PreviewExifDecimalFormatter
import java.util.Locale

/** Lazy tag access preserves the original fallback evaluation order and Android numeric decoder. */
internal class AndroidPreviewExifSource(private val exif: ExifInterface) : PreviewExifSource {
    override fun attribute(tag: PreviewExifTag): String? = exif.getAttribute(when (tag) {
        PreviewExifTag.F_NUMBER -> ExifInterface.TAG_F_NUMBER
        PreviewExifTag.APERTURE_VALUE -> ExifInterface.TAG_APERTURE_VALUE
        PreviewExifTag.EXPOSURE_TIME -> ExifInterface.TAG_EXPOSURE_TIME
        PreviewExifTag.PHOTOGRAPHIC_SENSITIVITY -> ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY
        PreviewExifTag.EXPOSURE_BIAS_VALUE -> ExifInterface.TAG_EXPOSURE_BIAS_VALUE
        PreviewExifTag.FOCAL_LENGTH -> ExifInterface.TAG_FOCAL_LENGTH
        PreviewExifTag.LENS_MODEL -> ExifInterface.TAG_LENS_MODEL
        PreviewExifTag.DATETIME_ORIGINAL -> ExifInterface.TAG_DATETIME_ORIGINAL
        PreviewExifTag.DATETIME_DIGITIZED -> ExifInterface.TAG_DATETIME_DIGITIZED
        PreviewExifTag.DATETIME -> ExifInterface.TAG_DATETIME
        PreviewExifTag.GPS_LATITUDE -> ExifInterface.TAG_GPS_LATITUDE
        PreviewExifTag.GPS_LATITUDE_REF -> ExifInterface.TAG_GPS_LATITUDE_REF
        PreviewExifTag.GPS_LONGITUDE -> ExifInterface.TAG_GPS_LONGITUDE
        PreviewExifTag.GPS_LONGITUDE_REF -> ExifInterface.TAG_GPS_LONGITUDE_REF
    })
    override fun decodedCoordinates(): DoubleArray? = exif.latLong
    override fun decodedAltitude(): Double = exif.getAltitude(Double.NaN)
}

internal object AndroidPreviewExifDecimalFormatter : PreviewExifDecimalFormatter {
    override fun fixed(value: Float, fractionDigits: Int, rootLocale: Boolean): String =
        if (rootLocale) String.format(Locale.ROOT, "%.${fractionDigits}f", value)
        else "%.${fractionDigits}f".format(value)
}
