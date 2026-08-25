package com.ztransfer.viewmodel

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ExposureCompensationTest {
    @Test
    fun zeroCompensationIsHidden() {
        assertNull(formatExposureCompensation(null))
        assertNull(formatExposureCompensation(0f))
        assertNull(formatExposureCompensation(-0.01f))
    }

    @Test
    fun nonZeroCompensationKeepsItsDirectionAndEvUnit() {
        assertEquals("+0.7 EV", formatExposureCompensation(2f / 3f))
        assertEquals("-1.3 EV", formatExposureCompensation(-4f / 3f))
    }
}
