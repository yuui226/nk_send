package com.ztransfer.ui.util

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProgressiveHoldTimingsTest {
    @Test fun gpsPatternIsUnchangedAtEightHundredMilliseconds() {
        assertArrayEquals(longArrayOf(0, 8,112, 8,102, 9,91, 9,81, 10,70,
            10,60, 11,49, 11,39, 12,33, 12,63), progressiveHoldTimings(800))
    }

    @Test fun systemLongPressDurationsKeepTheQuietGapAndExactDeadline() {
        for (duration in listOf(300L, 400L, 500L, 800L, 1000L, 1500L)) {
            val pattern = progressiveHoldTimings(duration)
            assertEquals(duration, pattern.sum())
            assertEquals(0L, pattern.first())
            assertTrue(pattern.drop(1).all { it > 0 })
            assertTrue(pattern.last() >= duration * .07)
        }
    }
}
