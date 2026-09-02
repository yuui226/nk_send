package com.ztransfer.frame

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
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
    fun legacyAddressSlotIsIgnoredWhileOtherLocationFieldsRemainReadable() {
        val encoded =
            "MIST|false|false|true|true|true|true|false|true|true|true|yyyy-MM-dd|HH:mm:ss"

        val restored = decodePhotoFrameMetadataSettings(encoded).getValue(PhotoFramePreset.MIST)

        assertFalse(restored.showAddress)
        assertTrue(restored.showCoordinates)
        assertTrue(restored.showAltitude)
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
        assertEquals(PREVIEW_FAKE_ALTITUDE_METERS, preview.altitudeMeters!!, 0.0)

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

    @Test
    fun previewUsesClearlyFakeValuesForMissingMetadata() {
        val settings = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST).copy(
            showDate = true,
            showTime = true,
            showFocalLength = true,
            showExposure = true,
            showBrand = true,
            showModel = true,
            showLensModel = true,
            showCoordinates = true,
            showAltitude = true,
            datePattern = DEFAULT_PHOTO_FRAME_DATE_PATTERN,
            timePattern = DEFAULT_PHOTO_FRAME_TIME_PATTERN,
        )
        val tomorrowBeforePresentation = LocalDate.now().plusDays(1)
        val preview = PhotoFrameMetadata(null, null, null, null, null, null)
            .withPresentation(settings, preview = true)
        val tomorrowAfterPresentation = LocalDate.now().plusDays(1)

        assertEquals(PREVIEW_FAKE_BRAND, preview.make)
        assertEquals(PREVIEW_FAKE_MODEL, preview.model)
        assertEquals(PREVIEW_FAKE_LENS_MODEL, preview.lensModel)
        assertEquals(PREVIEW_FAKE_FOCAL_LENGTH, preview.focalLength)
        assertEquals(PREVIEW_FAKE_APERTURE, preview.aperture)
        assertEquals(PREVIEW_FAKE_SHUTTER, preview.shutter)
        assertEquals(PREVIEW_FAKE_ISO, preview.iso)
        assertTrue(
            preview.dateTime in setOf(
                "$tomorrowBeforePresentation 25:61:61",
                "$tomorrowAfterPresentation 25:61:61",
            ),
        )
        assertEquals(PREVIEW_FAKE_LATITUDE, preview.latitude!!, 0.00001)
        assertEquals(PREVIEW_FAKE_LONGITUDE, preview.longitude!!, 0.00001)
        assertEquals(PREVIEW_FAKE_ALTITUDE_METERS, preview.altitudeMeters!!, 0.0)
    }

    @Test
    fun previewFakeTimeMatchesEverySelectableFormat() {
        val base = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST).copy(
            showDate = false,
            showTime = true,
        )
        val expectedByPattern = mapOf(
            "HH:mm" to "25:61",
            "HH:mm:ss" to "25:61:61",
            "HH.mm" to "25.61",
            "HH.mm.ss" to "25.61.61",
        )

        expectedByPattern.forEach { (pattern, expected) ->
            assertEquals(
                expected,
                formatPhotoFrameCaptureDateTime(
                    value = "2026-08-17",
                    settings = base.copy(timePattern = pattern),
                    preview = true,
                ),
            )
        }
    }

    @Test
    fun realMetadataOverridesPreviewValuesFieldByField() {
        val settings = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST).copy(
            showDate = true,
            showTime = true,
            showFocalLength = true,
            showExposure = true,
            showBrand = true,
            showModel = true,
            showLensModel = true,
        )
        val source = PhotoFrameMetadata(
            make = "NIKON CORPORATION",
            model = "NIKON Z 8",
            aperture = "f/4.0",
            shutter = null,
            iso = "ISO640",
            focalLength = "85mm",
            lensModel = null,
            dateTime = "2026:08:10 14:25:36",
        )
        val presented = source.withPresentation(settings, preview = true)

        assertEquals("NIKON CORPORATION", presented.make)
        assertEquals("NIKON Z 8", presented.model)
        assertEquals("f/4.0", presented.aperture)
        assertEquals(PREVIEW_FAKE_SHUTTER, presented.shutter)
        assertEquals("ISO640", presented.iso)
        assertEquals("85mm", presented.focalLength)
        assertEquals(PREVIEW_FAKE_LENS_MODEL, presented.lensModel)
        assertEquals("2026-08-10 14:25:36", presented.dateTime)
    }

    @Test
    fun previewOnlyFakeValuesNeverAppearInExportPresentation() {
        val settings = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST).copy(
            showDate = true,
            showTime = true,
            showFocalLength = true,
            showExposure = true,
            showBrand = true,
            showModel = true,
            showLensModel = true,
            showCoordinates = true,
            showAltitude = true,
        )
        val exported = PhotoFrameMetadata(null, null, null, null, null, null)
            .withPresentation(settings, preview = false)

        assertEquals(null, exported.make)
        assertEquals(null, exported.model)
        assertEquals(null, exported.lensModel)
        assertEquals(null, exported.focalLength)
        assertEquals(null, exported.aperture)
        assertEquals(null, exported.shutter)
        assertEquals(null, exported.iso)
        assertEquals(null, exported.dateTime)
        assertEquals(null, exported.latitude)
        assertEquals(null, exported.longitude)
        assertEquals(null, exported.altitudeMeters)
    }
}
