package com.ztransfer.ui.screen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class QueuePillStateTest {
    @Test
    fun pausedCountDigitTransitionRequestsFreshWidthMeasurement() {
        assertNotEquals(
            queuePillWidthKey(PillMode.PAUSED, speedText = null, count = 9),
            queuePillWidthKey(PillMode.PAUSED, speedText = null, count = 10),
        )
    }

    @Test
    fun equalWidthSpeedValuesShareAStableWidthKey() {
        assertEquals(
            queuePillWidthKey(PillMode.COUNTING, "1.0 MB/s", count = 8),
            queuePillWidthKey(PillMode.COUNTING, "9.9 MB/s", count = 8),
        )
    }

    @Test
    fun speedUnitAndDigitTransitionsRequestFreshWidthMeasurements() {
        val hundredsOfKilobytes = queuePillWidthKey(
            PillMode.COUNTING,
            "999.9 KB/s",
            count = 8,
        )
        assertNotEquals(
            hundredsOfKilobytes,
            queuePillWidthKey(PillMode.COUNTING, "1.0 MB/s", count = 8),
        )
        assertNotEquals(
            queuePillWidthKey(PillMode.COUNTING, "9.9 MB/s", count = 8),
            queuePillWidthKey(PillMode.COUNTING, "10.0 MB/s", count = 8),
        )
    }

    @Test
    fun countDigitAndSpeedVisibilityTransitionsRequestFreshWidths() {
        val base = queuePillWidthKey(PillMode.COUNTING, "1.0 MB/s", count = 99)
        assertNotEquals(
            base,
            queuePillWidthKey(PillMode.COUNTING, "1.0 MB/s", count = 100),
        )
        assertNotEquals(
            base,
            queuePillWidthKey(PillMode.COUNTING, speedText = null, count = 99),
        )
    }
}
