package com.ztransfer.frame

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PhotoFrameMetadataSettingsTest {
    @Test
    fun defaultsPreserveExistingPresetCategories() {
        listOf(
            PhotoFramePreset.MIST,
            PhotoFramePreset.CINEMA,
            PhotoFramePreset.MINIMAL,
            PhotoFramePreset.FROSTED,
            PhotoFramePreset.IMMERSIVE,
        ).forEach { preset ->
            assertEquals(
                PhotoFrameMetadataSettings(
                    showDate = false,
                    showTime = false,
                    showFocalLength = true,
                    showExposure = true,
                    showBrand = true,
                    showModel = true,
                ),
                defaultPhotoFrameMetadataSettings(preset),
            )
        }

        assertTrue(defaultPhotoFrameMetadataSettings(PhotoFramePreset.PLAQUE).showDate)
        assertTrue(defaultPhotoFrameMetadataSettings(PhotoFramePreset.PLAQUE).showTime)
        listOf(
            PhotoFramePreset.BRAND_INSET,
            PhotoFramePreset.BRAND_GALLERY,
            PhotoFramePreset.CLASSIC_SIGNATURE,
        ).forEach { preset ->
            assertFalse(defaultPhotoFrameMetadataSettings(preset).showModel)
        }
        listOf(PhotoFramePreset.GALLERY_MAT, PhotoFramePreset.FILM_EDGE).forEach { preset ->
            val settings = defaultPhotoFrameMetadataSettings(preset)
            assertFalse(settings.showBrand)
            assertFalse(settings.showModel)
            assertFalse(settings.showFocalLength)
            assertFalse(settings.showExposure)
        }
        val filmGallery = defaultPhotoFrameMetadataSettings(PhotoFramePreset.FILM_GALLERY)
        assertTrue(filmGallery.showDate)
        assertTrue(filmGallery.showTime)
        assertFalse(filmGallery.showFocalLength)
        assertFalse(filmGallery.showExposure)
    }

    @Test
    fun codecUsesStableFormatAndDiscardsDefaults() {
        val custom = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST).copy(
            showDate = true,
            showModel = false,
            showLensModel = true,
            datePattern = "yyyy/MM/dd",
        )

        val encoded = encodePhotoFrameMetadataSettings(
            mapOf(
                PhotoFramePreset.PLAQUE to defaultPhotoFrameMetadataSettings(PhotoFramePreset.PLAQUE),
                PhotoFramePreset.MIST to custom,
            ),
        )

        assertEquals(
            "MIST|true|false|true|true|true|false|true|false|false|yyyy/MM/dd|HH:mm:ss",
            encoded,
        )
        assertEquals(mapOf(PhotoFramePreset.MIST to custom), decodePhotoFrameMetadataSettings(encoded))
    }

    @Test
    fun decoderRetainsEverySupportedLegacyShape() {
        val withoutLens = decodePhotoFrameMetadataSettings(
            "MIST|false|false|true|true|true|false|yyyy-MM-dd|HH:mm:ss",
        ).getValue(PhotoFramePreset.MIST)
        assertFalse(withoutLens.showModel)
        assertFalse(withoutLens.showLensModel)

        val withLegacyAddress = decodePhotoFrameMetadataSettings(
            "MIST|false|false|true|true|true|true|false|true|true|true|yyyy-MM-dd|HH:mm:ss",
        ).getValue(PhotoFramePreset.MIST)
        assertFalse(withLegacyAddress.showAddress)
        assertTrue(withLegacyAddress.showCoordinates)
        assertTrue(withLegacyAddress.showAltitude)
    }

    @Test
    fun decoderSkipsInvalidEntriesAndDuplicatePresetValues() {
        val first =
            "MIST|true|false|true|true|true|true|false|false|false|yyyy-MM-dd|HH:mm:ss"
        val duplicate =
            "MIST|false|true|true|true|true|true|false|false|false|yyyy-MM-dd|HH:mm:ss"
        val invalidBoolean =
            "PLAQUE|yes|true|true|true|true|true|false|false|false|yyyy-MM-dd|HH:mm:ss"

        val decoded = decodePhotoFrameMetadataSettings(
            listOf("unknown", invalidBoolean, first, duplicate).joinToString(";"),
        )

        assertEquals(setOf(PhotoFramePreset.MIST), decoded.keys)
        assertTrue(decoded.getValue(PhotoFramePreset.MIST).showDate)
        assertFalse(decoded.getValue(PhotoFramePreset.MIST).showTime)
    }

    @Test
    fun normalizationUsesOnlySupportedPatternsAndDisablesReservedAddress() {
        val normalized = normalizePhotoFrameMetadataSettings(
            defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST).copy(
                showAddress = true,
                datePattern = " MMM d ",
                timePattern = " hh:mm a ",
            ),
        )

        assertFalse(normalized.showAddress)
        assertEquals(DEFAULT_PHOTO_FRAME_DATE_PATTERN, normalized.datePattern)
        assertEquals(DEFAULT_PHOTO_FRAME_TIME_PATTERN, normalized.timePattern)
        assertEquals("yyyy.MM.dd", normalizePhotoFrameDatePattern(" yyyy.MM.dd "))
        assertEquals("HH.mm.ss", normalizePhotoFrameTimePattern(" HH.mm.ss "))
    }

    @Test
    fun localPhotoSettingsRemoveEveryLocationField() {
        val settings = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST).copy(
            showAddress = true,
            showCoordinates = true,
            showAltitude = true,
        )

        val local = settings.withoutLocationFields()

        assertFalse(local.showAddress)
        assertFalse(local.showCoordinates)
        assertFalse(local.showAltitude)
    }

    @Test
    fun fingerprintIgnoresHiddenFormatsButTracksVisibleFormats() {
        val defaults = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST)
        assertNull(photoFrameMetadataSettingsFingerprintToken(PhotoFramePreset.MIST, defaults))
        assertNull(
            photoFrameMetadataSettingsFingerprintToken(
                PhotoFramePreset.MIST,
                defaults.copy(datePattern = "yyyy.MM.dd", timePattern = "HH.mm.ss"),
            ),
        )

        assertEquals(
            "MIST|true|false|true|true|true|true|false|false|false|yyyy.MM.dd|HH:mm:ss",
            photoFrameMetadataSettingsFingerprintToken(
                PhotoFramePreset.MIST,
                defaults.copy(showDate = true, datePattern = "yyyy.MM.dd"),
            ),
        )
    }

    @Test
    fun presentationAppliesVisibilityAndPlatformSuppliedDateTime() {
        val metadata = PhotoFrameMetadata(
            make = " NIKON CORPORATION ",
            model = " NIKON Z 8 ",
            aperture = " F2.8 ",
            shutter = " 1/250 ",
            iso = " ISO100 ",
            focalLength = " 50mm ",
            lensModel = " NIKKOR Z 24-70mm f/2.8 S ",
            dateTime = "2026:08:17 14:32:08",
            latitude = 31.2304,
            longitude = 121.4737,
            altitudeMeters = 520.0,
        )
        val settings = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST).copy(
            showDate = true,
            showBrand = false,
            showModel = true,
            showExposure = false,
            showFocalLength = false,
            showLensModel = true,
            showCoordinates = true,
            showAltitude = true,
        )

        val presented = metadata.withPhotoFrameMetadataPresentation(
            settings = settings,
            preview = false,
            previewAddressFallback = null,
            formattedDateTime = "2026-08-17",
        )

        assertNull(presented.make)
        assertEquals("Z 8", presented.model)
        assertNull(presented.aperture)
        assertNull(presented.shutter)
        assertNull(presented.iso)
        assertNull(presented.focalLength)
        assertEquals("NIKKOR Z 24-70mm f/2.8 S", presented.lensModel)
        assertEquals("2026-08-17", presented.dateTime)
        assertEquals(31.2304, presented.latitude)
        assertEquals(121.4737, presented.longitude)
        assertEquals(520.0, presented.altitudeMeters)
    }

    @Test
    fun presentationUsesPreviewFallbacksButNeverForExport() {
        val settings = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST).copy(
            showLensModel = true,
            showCoordinates = true,
            showAltitude = true,
        )
        val empty = PhotoFrameMetadata(null, null, null, null, null, null)

        val preview = empty.withPhotoFrameMetadataPresentation(
            settings = settings,
            preview = true,
            previewAddressFallback = "A very good place",
            formattedDateTime = null,
        )
        assertEquals(PREVIEW_FAKE_BRAND, preview.make)
        assertEquals(PREVIEW_FAKE_MODEL, preview.model)
        assertEquals(PREVIEW_FAKE_LENS_MODEL, preview.lensModel)
        assertEquals(PREVIEW_FAKE_LATITUDE, preview.latitude)
        assertEquals(PREVIEW_FAKE_LONGITUDE, preview.longitude)
        assertEquals(PREVIEW_FAKE_ALTITUDE_METERS, preview.altitudeMeters)

        val exported = empty.withPhotoFrameMetadataPresentation(
            settings = settings,
            preview = false,
            previewAddressFallback = null,
            formattedDateTime = null,
        )
        assertNull(exported.make)
        assertNull(exported.model)
        assertNull(exported.lensModel)
        assertNull(exported.latitude)
        assertNull(exported.longitude)
        assertNull(exported.altitudeMeters)
    }
}
