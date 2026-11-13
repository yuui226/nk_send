package com.ztransfer.ui.screen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class PhotoColorAdjustmentOptionsTest {
    @Test fun regularValuesRetainTheSameDetentsAndReuseTheList() {
        val options = photoColorAdjustmentOptions(0)
        assertEquals((100 downTo -100 step 5).toList(), options)
        for (value in options) assertSame(options, photoColorAdjustmentOptions(value))
    }

    @Test fun restoredValuesAreVisibleWithoutChangingTheirValueOrTheNormalSteps() {
        for (value in listOf(-99, -7, -1, 1, 9, 99)) {
            val options = photoColorAdjustmentOptions(value)
            assertEquals(42, options.size)
            assertEquals(options.distinct().sortedDescending(), options)
            assertEquals(value, options[options.indexOf(value)])
            assertEquals((100 downTo -100 step 5).toList(), options.filterNot { it == value })
        }
    }
}
