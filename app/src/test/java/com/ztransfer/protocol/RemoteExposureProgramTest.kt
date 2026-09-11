package com.ztransfer.protocol

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

class RemoteExposureProgramTest {
    @Test
    fun formatsStandardAndNikonAutoExposurePrograms() {
        assertEquals("M", rcFormat(Lab.PROP_EXPOSURE_PROGRAM, 1L))
        assertEquals("P", rcFormat(Lab.PROP_EXPOSURE_PROGRAM, 2L))
        assertEquals("A", rcFormat(Lab.PROP_EXPOSURE_PROGRAM, 3L))
        assertEquals("S", rcFormat(Lab.PROP_EXPOSURE_PROGRAM, 4L))
        assertEquals("AUTO", rcFormat(Lab.PROP_EXPOSURE_PROGRAM, 0x8010L))
    }

    @Test
    fun keepsUnconfirmedExposureProgramsVisibleAsRawValues() {
        assertEquals("0x8018", rcFormat(Lab.PROP_EXPOSURE_PROGRAM, 0x8018L))
    }

    @Test
    fun androidRendererMatchesTheRemovedDefaultLocaleExpressions() {
        val originalLocale = Locale.getDefault()
        try {
            listOf(Locale.US, Locale.GERMANY).forEach { locale ->
                Locale.setDefault(locale)
                assertEquals(
                    "f/%.1f".format(2.8),
                    rcDetailedFormat(Lab.PROP_F_NUMBER, 280L),
                )
                assertEquals(
                    "%.1fs".format(1.3),
                    rcDetailedFormat(Lab.PROP_NK_SHUTTER, (13L shl 16) or 10L),
                )
                assertEquals(
                    "%.4fs".format(0.125),
                    rcDetailedFormat(Lab.PROP_EXPOSURE_TIME_STD, 1250L),
                )
                assertEquals(
                    "%+.1fEV".format(0.667),
                    rcDetailedFormat(Lab.PROP_EXP_COMPENSATION, 667L),
                )
                assertEquals(
                    "%+.1f".format(0.667),
                    rcFormat(Lab.PROP_EXP_COMPENSATION, 667L),
                )
                assertEquals("640", rcFormat(Lab.PROP_ISO, 640L))
            }
        } finally {
            Locale.setDefault(originalLocale)
        }
    }
}
