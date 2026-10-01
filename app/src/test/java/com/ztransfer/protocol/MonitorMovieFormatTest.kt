package com.ztransfer.protocol

import org.junit.Assert.*
import org.junit.Test

class MonitorMovieFormatTest {
    @Test fun z30CapturedConfigurationAndEnumeratedValues() {
        assertEquals("1080 60p", monitorMovieFormatLabel(8, 540436593853071360L))
        assertEquals("4K 30p", monitorMovieFormatLabel(8, 1080873187700244480L))
        assertEquals("1080 120p", monitorMovieFormatLabel(8, 540436593857003520L))
        assertNull(monitorMovieFormatLabel(8, 540436593851105576L)) // unverified slow-motion flags
    }
    @Test fun unknownLayoutsDoNotBecomeCameraSettings() {
        assertNull(monitorMovieFormatLabel(2, 0))
        assertNull(monitorMovieFormatLabel(8, 0))
        assertNull(monitorMovieFormatLabel(8, -1))
    }
}
