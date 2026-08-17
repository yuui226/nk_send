package com.ztransfer.location

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DebugPhotoLocationSettingsTest {
    @Test
    fun disabledOrOutOfRangeInputIsIgnored() {
        assertNull(
            parseDebugPhotoLocation(
                DebugPhotoLocationInput(false, "39.9", "116.4")
            )
        )
        assertNull(
            parseDebugPhotoLocation(
                DebugPhotoLocationInput(true, "90.1", "116.4")
            )
        )
        assertNull(
            parseDebugPhotoLocation(
                DebugPhotoLocationInput(true, "39.9", "-180.1")
            )
        )
    }

    @Test
    fun validCoordinatesAreNormalized() {
        val parsed = parseDebugPhotoLocation(
            DebugPhotoLocationInput(true, "＋39.916", "－116.397")
        )

        assertEquals(39.916, parsed?.latitude ?: 0.0, 0.0)
        assertEquals(-116.397, parsed?.longitude ?: 0.0, 0.0)
    }
}
