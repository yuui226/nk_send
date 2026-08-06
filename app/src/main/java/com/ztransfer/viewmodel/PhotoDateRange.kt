package com.ztransfer.viewmodel

import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException

/**
 * 相机拍摄日期筛选。PTP ObjectInfo 给出的日期是相机本地日历时间，不带可靠时区，
 * 因而这里保存纯 [LocalDate]，避免经 epoch/手机时区换算后跨日。
 */
data class PhotoDateRange private constructor(
    val start: LocalDate,
    val endInclusive: LocalDate,
) {
    private val startDayKey = start.toDayKey()
    private val endDayKey = endInclusive.toDayKey()

    init {
        require(!start.isAfter(endInclusive)) { "PhotoDateRange start must not be after end" }
    }

    fun containsCaptureDate(captureDate: String?): Boolean {
        val dayKey = captureDayKey(captureDate) ?: return false
        return dayKey >= startDayKey && dayKey <= endDayKey
    }

    companion object {
        fun between(first: LocalDate, second: LocalDate): PhotoDateRange =
            if (first <= second) PhotoDateRange(first, second) else PhotoDateRange(second, first)

        fun restore(start: String?, endInclusive: String?): PhotoDateRange? {
            val first = start?.let(::parseIsoLocalDate) ?: return null
            val second = endInclusive?.let(::parseIsoLocalDate) ?: return null
            return between(first, second)
        }
    }
}

/** 只为最大值创建一个 LocalDate，避免渐进文件列表每次更新都为全部照片分配日期对象。 */
internal fun latestCaptureLocalDate(captureDates: Sequence<String?>): LocalDate? =
    captureDates.mapNotNull(::captureDayKey).maxOrNull()?.toLocalDate()

/** 主筛选面板使用的两位年份短摘要，保证起止日期格式稳定且适合单行显示。 */
internal fun compactDateRangeLabel(range: PhotoDateRange?): String? {
    range ?: return null
    return if (range.start == range.endInclusive) {
        range.start.formatShortDate()
    } else {
        "${range.start.formatShortDate()}–${range.endInclusive.formatShortDate()}"
    }
}

private fun captureDayKey(captureDate: String?): Int? {
    if (captureDate == null || captureDate.length < 8) return null
    var key = 0
    for (index in 0 until 8) {
        val digit = captureDate[index] - '0'
        if (digit !in 0..9) return null
        key = key * 10 + digit
    }
    val year = key / 10_000
    val month = key / 100 % 100
    val day = key % 100
    if (year !in 1..9999 || month !in 1..12) return null
    val maxDay = when (month) {
        2 -> if (year.isLeapYear()) 29 else 28
        4, 6, 9, 11 -> 30
        else -> 31
    }
    return key.takeIf { day in 1..maxDay }
}

private fun LocalDate.toDayKey(): Int = year * 10_000 + monthValue * 100 + dayOfMonth

private fun Int.toLocalDate(): LocalDate =
    LocalDate.of(this / 10_000, this / 100 % 100, this % 100)

private fun Int.isLeapYear(): Boolean = this % 4 == 0 && (this % 100 != 0 || this % 400 == 0)

private fun LocalDate.formatShortDate(): String =
    "${(year % 100).twoDigits()}/${monthValue.twoDigits()}/${dayOfMonth.twoDigits()}"

private fun Int.twoDigits(): String = toString().padStart(2, '0')

private fun parseIsoLocalDate(value: String): LocalDate? = try {
    LocalDate.parse(value, DateTimeFormatter.ISO_LOCAL_DATE)
} catch (_: DateTimeParseException) {
    null
}
