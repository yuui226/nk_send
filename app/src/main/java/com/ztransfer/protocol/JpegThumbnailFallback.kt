package com.ztransfer.protocol

/** Only a missing JPEG thumbnail warrants a bounded EXIF read; normal GetThumb stays untouched. */
internal fun jpegThumbnailFallbackHeaderBytes(
    responseCode: Int,
    hasThumbnail: Boolean,
    file: NikonCamera.FileInfo?,
): Int {
    if (hasThumbnail || file == null) return 0
    val extension = file.extension
    if (extension != ".jpg" && extension != ".jpeg") return 0
    if (responseCode != PtpConstants.NO_THUMBNAIL_PRESENT && responseCode != PtpConstants.RESPONSE_OK) return 0
    return file.size.coerceIn(0L, 128L * 1024L).toInt()
}
