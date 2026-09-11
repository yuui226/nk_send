package com.ztransfer.viewmodel

import com.ztransfer.catalog.CaptureDayRange
import com.ztransfer.catalog.compactCaptureDayRangeLabel
import com.ztransfer.catalog.latestCaptureDayKey
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
    internal val captureDayRange = CaptureDayRange.between(start.toDayKey(), endInclusive.toDayKey())

    init {
        require(!start.isAfter(endInclusive)) { "PhotoDateRange start must not be after end" }
    }

    fun containsCaptureDate(captureDate: String?): Boolean =
        captureDayRange.containsCaptureDate(captureDate)

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
    latestCaptureDayKey(captureDates)?.toLocalDate()

/** 主筛选面板使用的两位年份短摘要，保证起止日期格式稳定且适合单行显示。 */
internal fun compactDateRangeLabel(range: PhotoDateRange?): String? {
    return compactCaptureDayRangeLabel(range?.captureDayRange)
}

private fun LocalDate.toDayKey(): Int = year * 10_000 + monthValue * 100 + dayOfMonth

private fun Int.toLocalDate(): LocalDate =
    LocalDate.of(this / 10_000, this / 100 % 100, this % 100)

private fun parseIsoLocalDate(value: String): LocalDate? = try {
    LocalDate.parse(value, DateTimeFormatter.ISO_LOCAL_DATE)
} catch (_: DateTimeParseException) {
    null
}
