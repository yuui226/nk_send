package com.ztransfer.frame

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class PhotoFrameExifPolicyTest {
    @Test
    fun normalizesCompleteExifValuesWithRawGpsFallback() {
        val metadata = photoFrameMetadataFromExifValues(
            values = PhotoFrameExifValues(
                make = "NIKON CORPORATION",
                model = "NIKON Z 8",
                fNumber = 4.0,
                exposureTimeSeconds = 1.0 / 125.0,
                iso = "640",
                focalLength = 85.0,
                lensModel = "  NIKKOR Z 85mm f/1.8 S  ",
                dateTimeOriginal = "2026:08:10 14:25:36",
                decodedLatitude = 0.0,
                decodedLongitude = 0.0,
                latitudeDms = "33/1,52/1,8/1",
                latitudeReference = "S",
                longitudeDms = "151/1,12/1,33/1",
                longitudeReference = "W",
                altitudeRational = "617/5",
                altitudeBelowSeaLevel = true,
            ),
            formatAperture = { "f/$it" },
            formatShutter = { "s/$it" },
            formatFocalLength = { "${it.toInt()}mm" },
        )

        assertEquals("NIKON CORPORATION", metadata.make)
        assertEquals("NIKON Z 8", metadata.model)
        assertEquals("f/4.0", metadata.aperture)
        assertEquals("s/0.008", metadata.shutter)
        assertEquals("ISO640", metadata.iso)
        assertEquals("85mm", metadata.focalLength)
        assertEquals("NIKKOR Z 85mm f/1.8 S", metadata.lensModel)
        assertEquals("2026-08-10 14:25:36", metadata.dateTime)
        assertEquals(-(33.0 + 52.0 / 60.0 + 8.0 / 3600.0), metadata.latitude)
        assertEquals(-(151.0 + 12.0 / 60.0 + 33.0 / 3600.0), metadata.longitude)
        assertEquals(-123.4, metadata.altitudeMeters)
        assertNull(metadata.address)
    }

    @Test
    fun appliesApexFallbacksAndRejectsInvalidLocationValues() {
        val metadata = photoFrameMetadataFromExifValues(
            values = PhotoFrameExifValues(
                apertureValue = 4.0,
                shutterSpeedValue = 7.0,
                decodedLatitude = 91.0,
                decodedLongitude = Double.POSITIVE_INFINITY,
                latitudeDms = "1/0,2/1,3/1",
                longitudeDms = "bad",
                decodedAltitudeMeters = 0.0,
                altitudeRational = "1/0",
            ),
            formatAperture = Double::toString,
            formatShutter = Double::toString,
            formatFocalLength = Double::toString,
        )

        assertEquals("4.0", metadata.aperture)
        assertEquals((1.0 / 128.0).toString(), metadata.shutter)
        assertNull(metadata.latitude)
        assertNull(metadata.longitude)
        assertNull(metadata.altitudeMeters)
    }
}
