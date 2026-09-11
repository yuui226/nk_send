package com.ztransfer.ui

import com.ztransfer.catalog.CaptureDayRange
import com.ztransfer.ui.screen.FilterCalendar
import com.ztransfer.ui.screen.FilterTextKey
import kotlin.test.*

class NativeFilterCalendarTest {
    private val calendar: FilterCalendar<Int, CaptureDayRange> = NativeFilterCalendar { 20260905 }

    @Test fun dateAccessAndOrderingUseCameraDayWithoutTimeZones() = with(calendar) {
        assertEquals(20260905, today())
        assertEquals(2024, 20240229.year)
        assertEquals(2, 20240229.monthValue)
        assertEquals(29, 20240229.dayOfMonth)
        assertTrue(20250101.isAfter(20241231))
        assertTrue(20241231.isBefore(20250101))
        assertFalse(20250101.isAfter(20250101))
        val range = between(20260905, 20260831)
        assertEquals(20260831, range.start)
        assertEquals(20260905, range.endInclusive)
    }

    @Test fun wheelCommitsClampDayAndPreserveOtherFields() = with(calendar) {
        assertEquals(20240229, 20240131.withClampedDate(month = 2))
        assertEquals(20250228, 20240229.withClampedDate(year = 2025))
        assertEquals(19000228, 20000229.withClampedDate(year = 1900))
        assertEquals(21000228, 20000229.withClampedDate(year = 2100))
        assertEquals(24000229, 20000229.withClampedDate(year = 2400))
        assertEquals(20260430, 20260331.withClampedDate(month = 4))
        assertEquals(20260301, 20260331.withClampedDate(day = 1))
    }

    @Test fun compactLabelsAndUnknownDatesRetainSharedRules() = with(calendar) {
        assertEquals("24/02/29", formatDate(20240229))
        assertEquals("26/08/31–26/09/05", compactRange(between(20260905, 20260831)))
        assertEquals("26/09/05", compactRange(between(20260905, 20260905)))
        assertNull(compactRange(null))
        assertFalse(between(20260901, 20260905).containsCaptureDate(null))
        assertTrue(between(20260901, 20260905).containsCaptureDate("20260905T235959"))
    }

    @Test fun invalidHostOrWheelValuesDoNotBecomeInventedDates(): Unit = with(calendar) {
        assertFailsWith<IllegalArgumentException> { NativeFilterCalendar { 20260229 }.today() }
        assertFailsWith<IllegalArgumentException> { monthLength(2026, 13) }
        assertFailsWith<IllegalArgumentException> { monthLength(0, 1) }
        assertFailsWith<IllegalArgumentException> { 20260131.withClampedDate(day = 0) }
        assertFailsWith<IllegalArgumentException> { between(20260229, 20260905) }
    }

    @Test fun todayIsSuppliedLazilyRatherThanFrozenAtPageCreation() {
        var day = 20261231
        val value = NativeFilterCalendar { day }
        assertEquals(day, value.today())
        day = 20270101
        assertEquals(day, value.today())
    }

    @Test fun originalLanguageFallbackAndSlotPlaceholdersAreRetained() {
        assertEquals("Card 2", NativeFilterTextCatalog.forLanguage("en-US").value(FilterTextKey.filter_storage_slot, 2))
        val simplified = NativeFilterTextCatalog.forLanguage("zh-Hans")
        val traditional = NativeFilterTextCatalog.forLanguage("zh-Hant")
        assertEquals(simplified.value(FilterTextKey.filter_title), NativeFilterTextCatalog.forLanguage("zh-CN").value(FilterTextKey.filter_title))
        assertEquals(traditional.value(FilterTextKey.filter_title), NativeFilterTextCatalog.forLanguage("zh-HK").value(FilterTextKey.filter_title))
        assertEquals(simplified.value(FilterTextKey.filter_title), NativeFilterTextCatalog.forLanguage("zh-Hans-HK").value(FilterTextKey.filter_title))
        assertEquals("Card 1", NativeFilterTextCatalog.forLanguage("fr-FR").value(FilterTextKey.filter_storage_slot, 1))
    }
}
