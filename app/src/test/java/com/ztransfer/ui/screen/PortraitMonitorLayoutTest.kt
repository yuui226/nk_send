package com.ztransfer.ui.screen

import org.junit.Assert.*
import org.junit.Test

class PortraitMonitorLayoutTest {
    @Test fun foldableAndPhoneReserveControlsWithoutStretchingTheImage() {
        // Expanded square-ish windows, narrow cover displays, and ordinary phones.
        for ((width, height) in listOf(700 to 780, 390 to 850, 320 to 740, 850 to 900)) {
            for (controls in listOf(300, 380, 460)) {
                for (aspect in listOf(1f, 1.5f, 16f / 9f, 2.66f)) {
                    val (w, h) = portraitMonitorImageSize(width, height - controls, aspect)
                    assertTrue(w <= width)
                    assertTrue(h + controls <= height)
                    assertTrue(kotlin.math.abs(w / aspect - h) <= 0.51f)
                }
            }
        }
    }

    @Test fun tallPhoneKeepsFullWidthAndInvalidAspectIsSafe() {
        assertEquals(390 to 260, portraitMonitorImageSize(390, 500, 1.5f))
        assertEquals(0 to 0, portraitMonitorImageSize(390, 0, 1.5f))
        assertEquals(390 to 260, portraitMonitorImageSize(390, 500, Float.NaN))
    }
}
