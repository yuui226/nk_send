package com.ztransfer.ui.screen

import com.ztransfer.protocol.PtpConstants
import com.ztransfer.ui.util.formatFileSize

private const val FOUR_GIB_BYTES = 4L * 1024L * 1024L * 1024L

internal fun originalPreviewCaptureDateText(raw: String?): String? {
    if (raw == null || raw.length < 8 || !raw.take(8).all(Char::isDigit)) return null
    val year = raw.substring(0, 4).toInt()
    val month = raw.substring(4, 6).toInt()
    val day = raw.substring(6, 8).toInt()
    runCatching { java.time.LocalDate.of(year, month, day) }.getOrNull() ?: return null
    val date = "%04d-%02d-%02d".format(year, month, day)
    if (raw.length < 15 || raw[8] != 'T' || !raw.substring(9, 15).all(Char::isDigit)) {
        return date
    }
    val hour = raw.substring(9, 11).toInt()
    val minute = raw.substring(11, 13).toInt()
    val second = raw.substring(13, 15).toInt()
    runCatching { java.time.LocalTime.of(hour, minute, second) }.getOrNull() ?: return date
    return "$date %02d:%02d:%02d".format(hour, minute, second)
}

internal fun originalPreviewVideoMetadataText(
    fileSize: Long,
    captureDate: String?,
    overFourGbLabel: String,
): String = listOfNotNull(
    when {
        fileSize == PtpConstants.SIZE_UNKNOWN || fileSize > FOUR_GIB_BYTES -> overFourGbLabel
        fileSize > 0L -> formatFileSize(fileSize)
        else -> null
    },
    originalPreviewCaptureDateText(captureDate),
).joinToString("  ·  ")
