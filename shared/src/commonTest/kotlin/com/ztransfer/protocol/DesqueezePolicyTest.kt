package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class DesqueezePolicyTest {
    @Test
    fun cyclesThroughTheProductValuesAndReturnsToIconState() {
        assertEquals(1.33f, DesqueezePolicy.next(1f))
        assertEquals(1.5f, DesqueezePolicy.next(1.33f))
        assertEquals(1f, DesqueezePolicy.next(2f))
        assertEquals(1.33f, DesqueezePolicy.next(1.31f))
    }

    @Test
    fun normalizesLabelsAndAspectRatioWithoutExposingTimesSign() {
        assertNull(DesqueezePolicy.displayLabel(1f))
        assertEquals("1.3", DesqueezePolicy.displayLabel(1.33f))
        assertEquals("1.5", DesqueezePolicy.displayLabel(1.5f))
        assertEquals(2.66f, DesqueezePolicy.scaledAspectRatio(2f, 1.33f))
    }
}
