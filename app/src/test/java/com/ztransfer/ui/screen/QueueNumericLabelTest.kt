package com.ztransfer.ui.screen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QueueNumericLabelTest {
    @Test
    fun onlyChangedDecimalPlaceDiffersAcrossSpeedSamples() {
        val before = requireNotNull(queueNumericLabel("42.1 MB/s"))
        val after = requireNotNull(queueNumericLabel("42.3 MB/s"))
        assertEquals(before.digit(1), after.digit(1))
        assertEquals(before.digit(0), after.digit(0))
        assertNotEquals(before.digit(-1), after.digit(-1))
        assertEquals(before.suffix, after.suffix)
    }

    @Test
    fun addingOrRemovingLeadingDigitsKeepsUnitsAndFractionPlaces() {
        val short = requireNotNull(queueNumericLabel("9.2 MB/s"))
        val long = requireNotNull(queueNumericLabel("109.2 MB/s"))
        assertEquals(short.digit(0), long.digit(0))
        assertEquals(short.digit(-1), long.digit(-1))
        assertEquals("", short.digit(1))
        assertEquals("0", long.digit(1))
        assertEquals("1", long.digit(2))
    }

    @Test
    fun countAndInitialZeroHaveNoUnitOrFraction() {
        assertEquals(QueueNumericLabel("0", "", "", ""), queueNumericLabel("0"))
        assertEquals(QueueNumericLabel("120", "", "", ""), queueNumericLabel("120"))
    }

    @Test
    fun unitChangeHasDifferentOuterIdentity() {
        val kb = requireNotNull(queueNumericLabel("1023.9 KB/s"))
        val mb = requireNotNull(queueNumericLabel("1.0 MB/s"))
        assertNotEquals(kb.suffix, mb.suffix)
    }

    @Test
    fun localizedDecimalSeparatorDoesNotBecomePartOfUnit() {
        assertEquals(QueueNumericLabel("42", "3", ",", " MB/s"), queueNumericLabel("42,3 MB/s"))
        assertEquals(QueueNumericLabel("٤٢", "٣", "٫", " MB/s"), queueNumericLabel("٤٢٫٣ MB/s"))
    }

    @Test
    fun missingOrInvalidNumericLabelsUseWholeTextFallback() {
        assertNull(queueNumericLabel(""))
        assertNull(queueNumericLabel("—"))
        assertNull(queueNumericLabel("1.2.3 MB/s"))
        assertNull(queueNumericLabel("1. MB/s"))
    }
}
