package com.ztransfer.ui.screen

import com.ztransfer.viewmodel.PhotoDateRange
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.time.YearMonth

/** Exercises the actual adapter through the same generic interface used by the shared editor. */
class AndroidFilterCalendarTest {
    private val calendar: FilterCalendar<LocalDate, PhotoDateRange> = AndroidFilterCalendar

    @Test fun dateAndRangeDispatchStillUsesJavaLocalDate() = with(calendar) {
        val date = LocalDate.of(2024, 2, 29)
        assertEquals(2024, date.year)
        assertEquals(2, date.monthValue)
        assertEquals(29, date.dayOfMonth)
        val range = between(date.plusDays(1), date)
        assertEquals(date, range.start)
        assertEquals(date.plusDays(1), range.endInclusive)
        assertTrue(date.isBefore(date.plusDays(1)))
        assertFalse(date.isAfter(date))
        assertEquals(PhotoDateRange.between(date, date.plusDays(1)), range)
        assertEquals(listOf(2024, 2, 29, date, date.plusDays(1), true, false),
            readThroughGenericCalendar(calendar, date, range))
    }

    @Test fun allMonthEndsAndCenturyLeapCasesMatchOriginalHelper() = with(calendar) {
        for (year in listOf(1, 1899, 1900, 1990, 1999, 2000, 2024, 2025, 2100, 2400, 9999)) {
            for (month in 1..12) {
                val length = YearMonth.of(year, month).lengthOfMonth()
                val source = LocalDate.of(year, 1, 31)
                assertEquals(length, monthLength(year, month))
                assertEquals(LocalDate.of(year, month, length), source.withClampedDate(month = month))
                assertEquals(LocalDate.of(year, month, 1), source.withClampedDate(month = month, day = 1))
            }
        }
        assertEquals(LocalDate.of(2025, 2, 28), LocalDate.of(2024, 2, 29).withClampedDate(year = 2025))
    }

    @Test fun compactLabelsAndClearKeepOriginalSemantics() = with(calendar) {
        val first = LocalDate.of(2026, 8, 31)
        val last = LocalDate.of(2026, 9, 5)
        assertEquals("26/08/31", formatDate(first))
        assertEquals("26/08/31–26/09/05", compactRange(between(last, first)))
        assertEquals("26/09/05", compactRange(between(last, last)))
        assertNull(compactRange(null))
    }

    @Test fun todayRetainsAndroidLocalClockInsteadOfUtcConversion() {
        val before = LocalDate.now()
        val actual = calendar.today()
        val after = LocalDate.now()
        assertTrue(actual in before..after)
    }

    private fun <D : Any, R : Any> readThroughGenericCalendar(calendar: FilterCalendar<D, R>, date: D, range: R): List<Any> = with(calendar) {
        listOf(date.year, date.monthValue, date.dayOfMonth, range.start, range.endInclusive,
            date.isBefore(range.endInclusive), date.isAfter(date))
    }
}
