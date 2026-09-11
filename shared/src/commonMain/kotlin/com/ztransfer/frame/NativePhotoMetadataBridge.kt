package com.ztransfer.frame

/** Only locale/decimal rendering crosses the platform boundary, as in the Android EXIF adapter. */
fun interface NativePhotoDecimalFormatter {
    fun fixed(value: Double, fractionDigits: Int): String
}

object NativePhotoMetadataBridge {
    fun number(text: String?): Double = text?.let(::parsePhotoFrameExifRational) ?: Double.NaN

    fun metadata(values: PhotoFrameExifValues, formatter: NativePhotoDecimalFormatter): PhotoFrameMetadata =
        photoFrameMetadataFromExifValues(values,
            formatAperture = { formatApertureText(it, formatter::fixed) },
            formatShutter = { formatShutterText(it, formatter::fixed) },
            formatFocalLength = { "${formatter.fixed(it, 0)}mm" })
}
