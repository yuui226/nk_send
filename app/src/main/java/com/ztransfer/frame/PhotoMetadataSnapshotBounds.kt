package com.ztransfer.frame

/** Camera labels are short. Do not retain oversized EXIF text in every queued/retry recipe. */
internal fun PhotoFrameMetadata.boundedForQueue(): PhotoFrameMetadata {
    fun String?.bounded(): String? {
        if (this == null || length <= 256) return this
        val end = if (this[255].isHighSurrogate() && this[256].isLowSurrogate()) 255 else 256
        return substring(0, end)
    }
    // Keep the common path allocation-free; only malformed/excessive text needs a new snapshot.
    if ((make?.length ?: 0) <= 256 && (model?.length ?: 0) <= 256 &&
        (aperture?.length ?: 0) <= 256 && (shutter?.length ?: 0) <= 256 &&
        (iso?.length ?: 0) <= 256 && (focalLength?.length ?: 0) <= 256 &&
        (lensModel?.length ?: 0) <= 256 && (dateTime?.length ?: 0) <= 256 &&
        (address?.length ?: 0) <= 256 && (city?.length ?: 0) <= 256 &&
        (region?.length ?: 0) <= 256) return this
    return copy(make = make.bounded(), model = model.bounded(), aperture = aperture.bounded(),
        shutter = shutter.bounded(), iso = iso.bounded(), focalLength = focalLength.bounded(),
        lensModel = lensModel.bounded(), dateTime = dateTime.bounded(), address = address.bounded(),
        city = city.bounded(), region = region.bounded())
}
