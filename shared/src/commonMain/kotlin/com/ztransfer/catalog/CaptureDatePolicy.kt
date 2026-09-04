package com.ztransfer.catalog

/** Inclusive range of validated local calendar days encoded as yyyyMMdd integer keys. */
data class CaptureDayRange(
    val startDayKey: Int,
    val endInclusiveDayKey: Int,
) {
    init {
        require(isValidCaptureDayKey(startDayKey)) { "Invalid start day key: $startDayKey" }
        require(isValidCaptureDayKey(endInclusiveDayKey)) {
            "Invalid inclusive end day key: $endInclusiveDayKey"
        }
        require(startDayKey <= endInclusiveDayKey) {
            "CaptureDayRange start must not be after end"
        }
    }

    fun containsCaptureDate(captureDate: String?): Boolean {
        val dayKey = captureDayKey(captureDate) ?: return false
        return dayKey in startDayKey..endInclusiveDayKey
    }

    companion object {
        fun between(firstDayKey: Int, secondDayKey: Int): CaptureDayRange =
            if (firstDayKey <= secondDayKey) {
                CaptureDayRange(firstDayKey, secondDayKey)
            } else {
                CaptureDayRange(secondDayKey, firstDayKey)
            }
    }
}

/**
 * Reads the calendar-day prefix of a PTP capture date without applying a device time zone.
 * Returns null for a missing, short, non-numeric, or impossible Gregorian date.
 */
fun captureDayKey(captureDate: String?): Int? {
    if (captureDate == null || captureDate.length < 8) return null
    var key = 0
    for (index in 0 until 8) {
        val digit = captureDate[index] - '0'
        if (digit !in 0..9) return null
        key = key * 10 + digit
    }
    return key.takeIf(::isValidCaptureDayKey)
}

/** Finds the newest valid day while allocating no date object for each input row. */
fun latestCaptureDayKey(captureDates: Sequence<String?>): Int? =
    captureDates.mapNotNull(::captureDayKey).maxOrNull()

private fun isValidCaptureDayKey(key: Int): Boolean {
    val year = key / 10_000
    val month = key / 100 % 100
    val day = key % 100
    if (year !in 1..9999 || month !in 1..12) return false
    val maxDay = when (month) {
        2 -> if (year.isLeapYear()) 29 else 28
        4, 6, 9, 11 -> 30
        else -> 31
    }
    return day in 1..maxDay
}

private fun Int.isLeapYear(): Boolean = this % 4 == 0 && (this % 100 != 0 || this % 400 == 0)
