package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class RemoteExposureProgramTest {
    @Test
    fun formatsStandardAndNikonAutoAndUserExposurePrograms() {
        assertEquals("M", rcFormat(Lab.PROP_EXPOSURE_PROGRAM, 1L))
        assertEquals("P", rcFormat(Lab.PROP_EXPOSURE_PROGRAM, 2L))
        assertEquals("A", rcFormat(Lab.PROP_EXPOSURE_PROGRAM, 3L))
        assertEquals("S", rcFormat(Lab.PROP_EXPOSURE_PROGRAM, 4L))
        assertEquals("AUTO", rcFormat(Lab.PROP_EXPOSURE_PROGRAM, 0x8010L))
        assertEquals("U1", rcFormat(Lab.PROP_EXPOSURE_PROGRAM, 0x8050L))
        assertEquals("U2", rcFormat(Lab.PROP_EXPOSURE_PROGRAM, 0x8051L))
        assertEquals("U3", rcFormat(Lab.PROP_EXPOSURE_PROGRAM, 0x8052L))
    }

    @Test
    fun keepsUnconfirmedExposureProgramsVisibleAsRawValues() {
        assertEquals("0x8018", rcFormat(Lab.PROP_EXPOSURE_PROGRAM, 0x8018L))
    }
}
