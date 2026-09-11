package com.ztransfer.catalog

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CaptureDatePolicyTest {
    @Test
    fun rangeNormalizesEndpointsAndIncludesBothBoundaryDays() {
        val range = CaptureDayRange.between(20260806, 20260802)

        assertEquals(20260802, range.startDayKey)
        assertEquals(20260806, range.endInclusiveDayKey)
        assertTrue(range.containsCaptureDate("20260802T000000"))
        assertTrue(range.containsCaptureDate("20260806T235959"))
        assertFalse(range.containsCaptureDate("20260801T235959"))
    }

    @Test
    fun captureDayValidationPreservesGregorianLeapYearRules() {
        assertEquals(20240229, captureDayKey("20240229T120000"))
        assertNull(captureDayKey("20260229T120000"))
        assertNull(captureDayKey("20261340T000000"))
        assertNull(captureDayKey("00000101T000000"))
        assertNull(captureDayKey("20260A01T000000"))
        assertNull(captureDayKey("2026080"))
        assertNull(captureDayKey(null))
    }

    @Test
    fun onlyTheFirstEightCharactersDefineTheCaptureDay() {
        assertEquals(20260806, captureDayKey("20260806"))
        assertEquals(20260806, captureDayKey("20260806-not-a-time"))
        assertTrue(CaptureDayRange.between(20260806, 20260806)
            .containsCaptureDate("20260806anything"))
    }

    @Test
    fun latestDayIgnoresMalformedAndMissingValues() {
        assertEquals(
            20260806,
            latestCaptureDayKey(
                sequenceOf(null, "bad", "20260229T120000", "20260805T120000", "20260806T010000"),
            ),
        )
        assertNull(latestCaptureDayKey(sequenceOf(null, "bad")))
    }

    @Test
    fun publicRangeRejectsImpossibleDayKeys() {
        assertFailsWith<IllegalArgumentException> { CaptureDayRange.between(20260229, 20260301) }
        assertFailsWith<IllegalArgumentException> { CaptureDayRange.between(20260801, 20261301) }
    }

    @Test
    fun compactRangeLabelKeepsTwoDigitYearAndEnDash() {
        assertNull(compactCaptureDayRangeLabel(null))
        assertEquals(
            "26/08/06",
            compactCaptureDayRangeLabel(CaptureDayRange.between(20260806, 20260806)),
        )
        assertEquals(
            "26/12/31–27/01/02",
            compactCaptureDayRangeLabel(CaptureDayRange.between(20261231, 20270102)),
        )
    }
}
