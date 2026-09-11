package com.ztransfer.ui

import com.ztransfer.catalog.CaptureDayRange
import com.ztransfer.catalog.captureDayKey
import com.ztransfer.catalog.compactCaptureDayRangeLabel
import com.ztransfer.ui.screen.FilterCalendar

/** Camera dates stay Gregorian yyyyMMdd values, never epoch/time-zone conversions.
 * The host supplies today's LOCAL Gregorian date only when the original editor asks for it.
 */
internal class NativeFilterCalendar(private val currentDay: () -> Int) : FilterCalendar<Int, CaptureDayRange> {
    override fun today(): Int = currentDay().also { require(validDay(it)) }
    override val Int.year: Int get() = this / 10_000
    override val Int.monthValue: Int get() = this / 100 % 100
    override val Int.dayOfMonth: Int get() = this % 100
    override val CaptureDayRange.start: Int get() = startDayKey
    override val CaptureDayRange.endInclusive: Int get() = endInclusiveDayKey
    override fun Int.isAfter(other: Int): Boolean = this > other
    override fun Int.isBefore(other: Int): Boolean = this < other
    override fun Int.withClampedDate(year: Int, month: Int, day: Int): Int {
        val next = year * 10_000 + month * 100 + day.coerceAtMost(monthLength(year, month))
        require(day >= 1 && validDay(next))
        return next
    }
    override fun monthLength(year: Int, month: Int): Int {
        require(year in 1..9999 && month in 1..12)
        // Reuse the shared capture-date validator instead of maintaining a second leap-year rule.
        return (31 downTo 28).first { validDay(year * 10_000 + month * 100 + it) }
    }
    override fun between(first: Int, second: Int): CaptureDayRange = CaptureDayRange.between(first, second)
    override fun formatDate(date: Int): String = checkNotNull(compactRange(between(date, date)))
    override fun compactRange(range: CaptureDayRange?): String? = compactCaptureDayRangeLabel(range)
    private fun validDay(key: Int): Boolean = captureDayKey(key.toString().padStart(8, '0')) == key
}
