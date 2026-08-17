package com.ztransfer.frame

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoFrameMetadataSettingsTest {
    @Test
    fun defaultsPreserveEachExistingFrameStyle() {
        val standard = listOf(
            PhotoFramePreset.MIST,
            PhotoFramePreset.CINEMA,
            PhotoFramePreset.MINIMAL,
            PhotoFramePreset.FROSTED,
            PhotoFramePreset.IMMERSIVE,
        )
        standard.forEach { preset ->
            val settings = defaultPhotoFrameMetadataSettings(preset)
            assertFalse(settings.showDate)
            assertFalse(settings.showTime)
            assertTrue(settings.showFocalLength)
            assertTrue(settings.showExposure)
            assertTrue(settings.showBrand)
            assertTrue(settings.showModel)
        }

        val plaque = defaultPhotoFrameMetadataSettings(PhotoFramePreset.PLAQUE)
        assertTrue(plaque.showDate)
        assertTrue(plaque.showTime)

        listOf(PhotoFramePreset.BRAND_INSET, PhotoFramePreset.BRAND_GALLERY).forEach { preset ->
            val settings = defaultPhotoFrameMetadataSettings(preset)
            assertTrue(settings.showBrand)
            assertFalse(settings.showModel)
            assertTrue(settings.showFocalLength)
            assertTrue(settings.showExposure)
            assertFalse(settings.showDate)
            assertFalse(settings.showTime)
        }
    }

    @Test
    fun settingsRoundTripByStablePresetIdAndDiscardDefaults() {
        val mist = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST).copy(
            showModel = false,
            showDate = true,
            datePattern = "dd/MM/yyyy",
        )
        val encoded = encodePhotoFrameMetadataSettings(
            mapOf(
                PhotoFramePreset.MIST to mist,
                PhotoFramePreset.PLAQUE to defaultPhotoFrameMetadataSettings(
                    PhotoFramePreset.PLAQUE,
                ),
            )
        )

        assertTrue(encoded.startsWith("MIST|"))
        assertEquals(mapOf(PhotoFramePreset.MIST to mist), decodePhotoFrameMetadataSettings(encoded))
    }

    @Test
    fun invalidOrLanguageBearingPatternsFallBackToNumericDefaults() {
        assertFalse(isValidPhotoFrameDatePattern("yyyy年MM月dd日"))
        assertEquals(DEFAULT_PHOTO_FRAME_DATE_PATTERN, normalizePhotoFrameDatePattern("MMM d"))
        assertEquals(DEFAULT_PHOTO_FRAME_TIME_PATTERN, normalizePhotoFrameTimePattern("hh:mm a"))
        assertTrue(isValidPhotoFrameDatePattern("dd.MM.yyyy"))
        assertEquals("HH.mm.ss", normalizePhotoFrameTimePattern("HH.mm.ss"))
    }

    @Test
    fun dateAndTimeCanBeShownAndFormattedIndependently() {
        val base = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST)
        assertEquals(
            "17/08/2026",
            formatPhotoFrameCaptureDateTime(
                "2026-08-17 14:32:08",
                base.copy(showDate = true, showTime = false, datePattern = "dd/MM/yyyy"),
            ),
        )
        assertEquals(
            "14:32",
            formatPhotoFrameCaptureDateTime(
                "2026-08-17 14:32:08",
                base.copy(showDate = false, showTime = true, timePattern = "HH:mm"),
            ),
        )
        assertNull(
            formatPhotoFrameCaptureDateTime(
                "2026-08-17",
                base.copy(showDate = false, showTime = true),
            ),
        )
    }

    @Test
    fun hiddenFieldsAreRemovedWithoutPlaceholdersOrBrandLeakage() {
        val metadata = PhotoFrameMetadata(
            make = "NIKON CORPORATION",
            model = "NIKON Z 8",
            aperture = "F2.8",
            shutter = "1/250",
            iso = "ISO100",
            focalLength = "50mm",
            dateTime = "2026-08-17 14:32:08",
        )
        val visible = metadata.withPresentation(
            defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST).copy(
                showDate = false,
                showTime = false,
                showFocalLength = false,
                showExposure = false,
                showBrand = false,
                showModel = true,
            )
        )

        assertNull(visible.make)
        assertEquals("Z 8", visible.model)
        assertNull(visible.aperture)
        assertNull(visible.shutter)
        assertNull(visible.iso)
        assertNull(visible.focalLength)
        assertNull(visible.dateTime)
    }

    @Test
    fun everyVisibilityCombinationProducesOnlyTheRequestedFields() {
        val source = PhotoFrameMetadata(
            make = "NIKON CORPORATION",
            model = "NIKON Z 8",
            aperture = "F2.8",
            shutter = "1/250",
            iso = "ISO100",
            focalLength = "50mm",
            dateTime = "2026-08-17 14:32:08",
        )

        PhotoFramePreset.entries.forEach { preset ->
            repeat(64) { mask ->
                val settings = defaultPhotoFrameMetadataSettings(preset).copy(
                    showDate = mask and 1 != 0,
                    showTime = mask and 2 != 0,
                    showFocalLength = mask and 4 != 0,
                    showExposure = mask and 8 != 0,
                    showBrand = mask and 16 != 0,
                    showModel = mask and 32 != 0,
                )
                val visible = source.withPresentation(settings)

                assertEquals(settings.showBrand, visible.make != null)
                assertEquals(settings.showModel, visible.model != null)
                assertEquals(settings.showFocalLength, visible.focalLength != null)
                assertEquals(settings.showExposure, visible.aperture != null)
                assertEquals(settings.showExposure, visible.shutter != null)
                assertEquals(settings.showExposure, visible.iso != null)
                assertEquals(settings.showDate || settings.showTime, visible.dateTime != null)
            }
        }
    }

    @Test
    fun nonDefaultVisibilityChangesOutputIdentityButHiddenFrameSettingsDoNot() {
        val watermark = PhotoFrameWatermark()
        val custom = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST).copy(
            showModel = false,
        )
        val defaultName = photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST, watermark)
        val customName = photoFrameOutputName(
            "DSC.JPG",
            PhotoFramePreset.MIST,
            watermark,
            metadataSettings = custom,
        )
        assertTrue(defaultName != customName)

        val watermarkOnlyDefault = photoFrameOutputName(
            "DSC.JPG",
            PhotoFramePreset.MIST,
            watermark,
            borderEnabled = false,
        )
        val watermarkOnlyCustom = photoFrameOutputName(
            "DSC.JPG",
            PhotoFramePreset.MIST,
            watermark,
            borderEnabled = false,
            metadataSettings = custom,
        )
        assertEquals(watermarkOnlyDefault, watermarkOnlyCustom)
    }

    @Test
    fun hiddenDateAndTimeFormatsDoNotCreateDuplicateOutputIdentities() {
        val defaults = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST)
        val hiddenCustomFormats = defaults.copy(
            datePattern = "dd.MM.yyyy",
            timePattern = "HH.mm.ss",
        )

        assertEquals(
            photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST),
            photoFrameOutputName(
                "DSC.JPG",
                PhotoFramePreset.MIST,
                metadataSettings = hiddenCustomFormats,
            ),
        )
    }
}
