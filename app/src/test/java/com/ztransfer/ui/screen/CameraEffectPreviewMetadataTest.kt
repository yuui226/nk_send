package com.ztransfer.ui.screen

import com.ztransfer.viewmodel.PhotoExif
import org.junit.Assert.assertEquals
import org.junit.Test

class CameraEffectPreviewMetadataTest {
    @Test
    fun connectedCameraIdentityReplacesDemoIdentity() {
        val metadata = cameraEffectPreviewMetadata(
            manufacturer = "NIKON CORPORATION",
            model = "NIKON Z 5",
        )

        assertEquals("NIKON CORPORATION", metadata.make)
        assertEquals("NIKON Z 5", metadata.model)
    }

    @Test
    fun missingCameraIdentityStaysEmpty() {
        val metadata = cameraEffectPreviewMetadata(
            manufacturer = " ",
            model = null,
        )

        assertEquals(null, metadata.make)
        assertEquals(null, metadata.model)
    }

    @Test
    fun previewExifUsesEveryRealExposureField() {
        val metadata = cameraEffectPreviewMetadata(
            manufacturer = "NIKON CORPORATION",
            model = "NIKON Z 6_3",
            exif = PhotoExif(
                aperture = "f/4.0",
                shutterSpeed = "1/125",
                iso = "ISO640",
                focalLength = "85mm",
                dateTime = "2026:08:10 14:25:36",
                lensModel = "NIKKOR Z 85mm f/1.8 S",
            ),
        )

        assertEquals("f/4.0", metadata.aperture)
        assertEquals("1/125", metadata.shutter)
        assertEquals("ISO640", metadata.iso)
        assertEquals("85mm", metadata.focalLength)
        assertEquals("NIKKOR Z 85mm f/1.8 S", metadata.lensModel)
        assertEquals("2026-08-10 14:25:36", metadata.dateTime)
    }

    @Test
    fun missingExifFieldsStayEmptyIndividually() {
        val metadata = cameraEffectPreviewMetadata(
            manufacturer = null,
            model = null,
            exif = PhotoExif(
                aperture = "f/5.6",
                shutterSpeed = null,
                iso = " ",
                focalLength = null,
            ),
        )

        assertEquals("f/5.6", metadata.aperture)
        assertEquals(null, metadata.shutter)
        assertEquals(null, metadata.iso)
        assertEquals(null, metadata.focalLength)
        assertEquals(null, metadata.lensModel)
        assertEquals(null, metadata.dateTime)
    }
}
