package com.ztransfer.frame

import kotlin.test.*

class NativePhotoMetadataBridgeTest {
    @Test fun nativeEntryDelegatesExifAndDisplayRules() {
        val formatter = NativePhotoDecimalFormatter { number, digits -> "[$number:$digits]" }
        val values = PhotoFrameExifValues(make = "NIKON", model = "Z8", apertureValue = 4.0,
            shutterSpeedValue = 7.0, focalLength = 85.0, iso = "640", latitudeDms = "33.5",
            latitudeReference = "S", longitudeDms = "151.25", longitudeReference = "E",
            altitudeRational = "617/5", altitudeBelowSeaLevel = true)
        val expected = photoFrameMetadataFromExifValues(values,
            { formatApertureText(it, formatter::fixed) }, { formatShutterText(it, formatter::fixed) },
            { "${formatter.fixed(it, 0)}mm" })
        val actual = NativePhotoMetadataBridge.metadata(values, formatter)
        assertEquals(expected, actual)
        assertEquals(-33.5, actual.latitude)
        assertEquals(-123.4, actual.altitudeMeters)
        assertEquals("ISO640", actual.iso)
        assertNull(actual.address)
    }

    @Test fun platformNumericStringsUseExistingRationalParser() {
        assertEquals(0.008, NativePhotoMetadataBridge.number("1/125"))
        assertEquals(2.8, NativePhotoMetadataBridge.number("2.8"))
        for (value in listOf(null, "", "bad", "1/0")) assertTrue(NativePhotoMetadataBridge.number(value).isNaN())
    }
}
