package com.ztransfer.frame

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

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
            assertFalse(settings.showLensModel)
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
            assertFalse(settings.showLensModel)
        }

        val classic = defaultPhotoFrameMetadataSettings(PhotoFramePreset.CLASSIC_SIGNATURE)
        assertTrue(classic.showBrand)
        assertFalse(classic.showModel)
        assertTrue(classic.showFocalLength)
        assertTrue(classic.showExposure)

        val filmGallery = defaultPhotoFrameMetadataSettings(PhotoFramePreset.FILM_GALLERY)
        assertTrue(filmGallery.showBrand)
        assertTrue(filmGallery.showModel)
        assertTrue(filmGallery.showDate)
        assertTrue(filmGallery.showTime)
        assertFalse(filmGallery.showFocalLength)
        assertFalse(filmGallery.showExposure)

        val colorArchive = defaultPhotoFrameMetadataSettings(PhotoFramePreset.COLOR_ARCHIVE)
        assertTrue(colorArchive.showBrand)
        assertTrue(colorArchive.showModel)
        assertTrue(colorArchive.showFocalLength)
        assertTrue(colorArchive.showExposure)
        assertFalse(colorArchive.showLensModel)
        assertFalse(colorArchive.showDate)
        assertFalse(colorArchive.showTime)

        listOf(PhotoFramePreset.GALLERY_MAT, PhotoFramePreset.FILM_EDGE).forEach { preset ->
            val settings = defaultPhotoFrameMetadataSettings(preset)
            assertFalse(settings.showDate)
            assertFalse(settings.showTime)
            assertFalse(settings.showFocalLength)
            assertFalse(settings.showExposure)
            assertFalse(settings.showBrand)
            assertFalse(settings.showModel)
            assertFalse(settings.showLensModel)
        }
    }

    @Test
    fun settingsRoundTripByStablePresetIdAndDiscardDefaults() {
        val mist = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST).copy(
            showModel = false,
            showLensModel = true,
            showDate = true,
            datePattern = "yyyy/MM/dd",
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
    fun legacySettingsDecodeWithLensModelDisabled() {
        val encoded =
            "MIST|false|false|true|true|true|false|yyyy-MM-dd|HH:mm:ss"

        val restored = decodePhotoFrameMetadataSettings(encoded).getValue(PhotoFramePreset.MIST)

        assertFalse(restored.showModel)
        assertFalse(restored.showLensModel)
    }

    @Test
    fun unsupportedOrReverseDatePatternsFallBackToNumericDefaults() {
        assertEquals(DEFAULT_PHOTO_FRAME_DATE_PATTERN, normalizePhotoFrameDatePattern("MMM d"))
        assertFalse(PHOTO_FRAME_DATE_PATTERNS.any { it.startsWith("dd") })
        assertEquals(DEFAULT_PHOTO_FRAME_TIME_PATTERN, normalizePhotoFrameTimePattern("hh:mm a"))
        assertEquals("yyyy.MM.dd", normalizePhotoFrameDatePattern("yyyy.MM.dd"))
        assertEquals("HH.mm.ss", normalizePhotoFrameTimePattern("HH.mm.ss"))
    }

    @Test
    fun dateAndTimeCanBeShownAndFormattedIndependently() {
        val base = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST)
        assertEquals(
            "08-17-2026",
            formatPhotoFrameCaptureDateTime(
                "2026-08-17 14:32:08",
                base.copy(showDate = true, showTime = false, datePattern = "MM-dd-yyyy"),
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
            lensModel = "NIKKOR Z 24-70mm f/2.8 S",
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
                showLensModel = false,
            )
        )

        assertNull(visible.make)
        assertEquals("Z 8", visible.model)
        assertNull(visible.aperture)
        assertNull(visible.shutter)
        assertNull(visible.iso)
        assertNull(visible.focalLength)
        assertNull(visible.lensModel)
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
            lensModel = "NIKKOR Z 24-70mm f/2.8 S",
            dateTime = "2026-08-17 14:32:08",
        )

        PhotoFramePreset.entries.forEach { preset ->
            repeat(128) { mask ->
                val settings = defaultPhotoFrameMetadataSettings(preset).copy(
                    showDate = mask and 1 != 0,
                    showTime = mask and 2 != 0,
                    showFocalLength = mask and 4 != 0,
                    showExposure = mask and 8 != 0,
                    showBrand = mask and 16 != 0,
                    showModel = mask and 32 != 0,
                    showLensModel = mask and 64 != 0,
                )
                val visible = source.withPresentation(settings)

                assertEquals(settings.showBrand, visible.make != null)
                assertEquals(settings.showModel, visible.model != null)
                assertEquals(settings.showFocalLength, visible.focalLength != null)
                assertEquals(settings.showLensModel, visible.lensModel != null)
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
            datePattern = "yyyy.MM.dd",
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

    @Test
    fun gpsFieldsUsePreviewPlaceholdersButAddressIsReservedForFuturePolicy() {
        val settings = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST).copy(
            showAddress = true,
            showCoordinates = true,
            showAltitude = true,
        )
        val empty = PhotoFrameMetadata(null, null, null, null, null, null)
        val preview = empty.withPresentation(settings, preview = true, previewLocale = Locale.SIMPLIFIED_CHINESE)
        assertNull(preview.address)
        assertEquals(66.6666, preview.latitude!!, 0.00001)
        assertEquals(66.6666, preview.longitude!!, 0.00001)
        assertEquals(520.0, preview.altitudeMeters!!, 0.0)

        val exported = empty.withPresentation(settings)
        assertNull(exported.address)
        assertNull(exported.latitude)
        assertNull(exported.longitude)
        assertNull(exported.altitudeMeters)

        val actual = empty.copy(
            latitude = 31.2304,
            longitude = 121.4737,
            altitudeMeters = 520.0,
            address = "上海市黄浦区",
        ).withPresentation(settings)
        assertNull(actual.address)
        assertEquals(31.2304, actual.latitude!!, 0.00001)
        assertEquals(121.4737, actual.longitude!!, 0.00001)
        assertEquals(520.0, actual.altitudeMeters!!, 0.0)

        assertNull(empty.copy(altitudeMeters = 0.0).withPresentation(settings).altitudeMeters)

        val zeroCoordinates = actual.copy(latitude = 0.0, longitude = 0.0)
            .withPresentation(settings)
        assertNull(zeroCoordinates.latitude)
        assertNull(zeroCoordinates.longitude)

        val invalidCoordinates = actual.copy(latitude = Double.NaN, longitude = 181.0)
            .withPresentation(settings)
        assertNull(invalidCoordinates.latitude)
        assertNull(invalidCoordinates.longitude)
    }
}
