@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import com.ztransfer.catalog.captureDayKey
import com.ztransfer.protocol.PtpConstants

/** Original PTP wall-clock display; never reinterpret capture time in the phone's time zone. */
@kotlin.native.HiddenFromObjC
fun previewCaptureDateText(
    raw: String?,
    dateText: (Int, Int, Int) -> String,
    timeText: (Int, Int, Int) -> String,
): String? {
    if (raw == null || raw.length < 8 || !raw.take(8).all(Char::isDigit)) return null
    val year = raw.substring(0, 4).toInt()
    val month = raw.substring(4, 6).toInt()
    val day = raw.substring(6, 8).toInt()
    // Java LocalDate accepts proleptic year zero; the file-filter key intentionally does not.
    // Gregorian dates repeat every 400 years, so validate zero as 400 but display the original zero.
    val validationYear = if (year == 0) 400 else year
    val key = validationYear * 10_000 + month * 100 + day
    if (captureDayKey(key.toString().padStart(8, '0')) != key) return null
    val date = dateText(year, month, day)
    if (raw.length < 15 || raw[8] != 'T' || !raw.substring(9, 15).all(Char::isDigit)) return date
    val hour = raw.substring(9, 11).toInt()
    val minute = raw.substring(11, 13).toInt()
    val second = raw.substring(13, 15).toInt()
    if (hour !in 0..23 || minute !in 0..59 || second !in 0..59) return date
    return "$date ${timeText(hour, minute, second)}"
}

/** The original SIZE_UNKNOWN/4 GiB branch and punctuation, with platform rendering at the edge. */
@kotlin.native.HiddenFromObjC
fun previewVideoMetadataText(
    fileSize: Long, captureDate: String?, overFourGbLabel: String,
    sizeText: (Long) -> String, captureText: (String?) -> String?,
): String = listOfNotNull(
    when {
        fileSize == PtpConstants.SIZE_UNKNOWN || fileSize > 4L * 1024L * 1024L * 1024L -> overFourGbLabel
        fileSize > 0L -> sizeText(fileSize)
        else -> null
    },
    captureText(captureDate),
).joinToString("  ·  ")
