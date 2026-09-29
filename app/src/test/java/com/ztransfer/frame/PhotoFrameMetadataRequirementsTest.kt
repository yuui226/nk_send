package com.ztransfer.frame

import org.junit.Assert.*
import org.junit.Test

class PhotoFrameMetadataRequirementsTest {
    @Test fun decorationSkipsHeadersButEachVisibleFieldRequestsThem() {
        val blank = PhotoFrameMetadataSettings(false, false, false, false, false, false)
        assertFalse(blank.requiresCameraMetadata)
        val fields = listOf(blank.copy(showDate = true), blank.copy(showTime = true),
            blank.copy(showFocalLength = true), blank.copy(showExposure = true),
            blank.copy(showBrand = true), blank.copy(showModel = true),
            blank.copy(showLensModel = true), blank.copy(showCoordinates = true),
            blank.copy(showAltitude = true), blank.copy(showCity = true), blank.copy(showRegion = true))
        fields.forEach { assertTrue(it.requiresCameraMetadata) }
        assertTrue(blank.copy(showBrand = true, brandStyle = PhotoFrameBrandStyle.LOGO).requiresCameraMetadata)
    }
}
