package com.ztransfer.frame

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoFrameExporterTest {
    @Test
    fun frostedPresetKeepsItsStablePersistenceKey() {
        assertEquals(PhotoFramePreset.FROSTED, PhotoFramePreset.valueOf("FROSTED"))
    }

    @Test
    fun landscapeAndPortraitUseFourByThreeShareCanvas() {
        val landscape = calculatePhotoFrameLayout(6000, 4000)
        val portrait = calculatePhotoFrameLayout(4000, 6000)

        assertEquals(3200, landscape.canvasWidth)
        assertEquals(2400, landscape.canvasHeight)
        assertEquals(2133, portrait.canvasWidth)
        assertEquals(3200, portrait.canvasHeight)
        assertTrue(landscape.photoLeft > 0f)
        assertTrue(landscape.photoBottom < landscape.metadataTop)
        assertTrue(portrait.photoTop >= 0f)
        assertTrue(portrait.photoBottom < portrait.metadataTop)
    }

    @Test
    fun regularPhotosKeepGalleryLikeMarginsAndBottomWeighting() {
        val landscape = calculatePhotoFrameLayout(6000, 4000)
        val portrait = calculatePhotoFrameLayout(4000, 6000)

        val landscapeSide = landscape.photoLeft / landscape.canvasWidth
        val portraitSide = portrait.photoLeft / portrait.canvasWidth
        val landscapeMetadataBand =
            1f - landscape.metadataTop / landscape.canvasHeight
        val portraitMetadataBand =
            1f - portrait.metadataTop / portrait.canvasHeight

        assertTrue(landscapeSide in 0.06f..0.08f)
        assertTrue(portraitSide in 0.06f..0.08f)
        assertEquals(0.17f, landscapeMetadataBand, 0.001f)
        assertEquals(0.10f, portraitMetadataBand, 0.001f)
    }

    @Test
    fun photoAndFrostedMetadataCardShareTheSameCornerScale() {
        val landscape = calculatePhotoFrameLayout(6000, 4000)
        val portrait = calculatePhotoFrameLayout(4000, 6000)

        assertEquals(
            (landscape.canvasHeight - landscape.metadataTop) * 0.26f,
            photoFrameCornerRadius(landscape),
            0.001f,
        )
        assertEquals(
            (portrait.canvasHeight - portrait.metadataTop) * 0.26f,
            photoFrameCornerRadius(portrait),
            0.001f,
        )
        assertTrue(photoFrameCornerRadius(landscape) > landscape.canvasWidth * 0.02f)
        assertTrue(photoFrameCornerRadius(portrait) > portrait.canvasWidth * 0.02f)
    }

    @Test
    fun disablingBrandingRecentersTwoRowsInsteadOfLeavingAThirdRowGap() {
        val threeRows = photoFrameTextRows(
            hasTitle = true,
            hasDetails = true,
            showBranding = true,
        )
        val twoRows = photoFrameTextRows(
            hasTitle = true,
            hasDetails = true,
            showBranding = false,
        )

        assertEquals(0.84f, threeRows.branding!!, 0.001f)
        assertEquals(null, twoRows.branding)
        assertEquals(0.46f, twoRows.title!!, 0.001f)
        assertEquals(0.70f, twoRows.details!!, 0.001f)
    }

    @Test
    fun missingMetadataRowsCollapseWithoutBlankPlaceholders() {
        assertEquals(
            PhotoFrameTextRows(title = 0.58f, details = null, branding = null),
            photoFrameTextRows(hasTitle = true, hasDetails = false, showBranding = false),
        )
        assertEquals(
            PhotoFrameTextRows(title = null, details = null, branding = 0.58f),
            photoFrameTextRows(hasTitle = false, hasDetails = false, showBranding = true),
        )
    }

    @Test
    fun unusualAspectRatiosGetPurposeBuiltCanvasWithoutCropping() {
        val square = calculatePhotoFrameLayout(4000, 4000)
        val panorama = calculatePhotoFrameLayout(8000, 3000)
        val tall = calculatePhotoFrameLayout(2000, 5000)

        assertEquals(3200 to 3200, square.canvasWidth to square.canvasHeight)
        assertEquals(3200 to 1800, panorama.canvasWidth to panorama.canvasHeight)
        assertEquals(1800 to 3200, tall.canvasWidth to tall.canvasHeight)
        listOf(square, panorama, tall).forEach { layout ->
            assertTrue(layout.photoLeft >= 0f)
            assertTrue(layout.photoTop >= 0f)
            assertTrue(layout.photoRight <= layout.canvasWidth)
            assertTrue(layout.photoBottom < layout.metadataTop)
        }
    }

    @Test
    fun detailLineMatchesCameraWatermarkStyle() {
        val detail = frameDetailLine(
            PhotoFrameMetadata(
                make = "NIKON CORPORATION",
                model = "NIKON Z 5",
                aperture = "f/4.2",
                shutter = "1/125",
                iso = "ISO400",
                focalLength = "26mm",
            )
        )

        assertEquals("26mm  F4.2  1/125s  ISO400", detail)
        assertEquals("Nikon", normalizeCameraMake("NIKON CORPORATION"))
        assertEquals(
            "Z 5",
            normalizeCameraModel("NIKON CORPORATION", "NIKON Z 5"),
        )
    }

    @Test
    fun cameraModelOnlyRemovesARepeatedLeadingBrand() {
        assertEquals("EOS R5", normalizeCameraModel("Canon", "Canon EOS R5"))
        assertEquals("ILCE-7M4", normalizeCameraModel("SONY", "SONY ILCE-7M4"))
        assertEquals("X-T5", normalizeCameraModel("FUJIFILM", "X-T5"))
        assertEquals("", normalizeCameraModel("NIKON", null))
        assertEquals("Z 5", normalizeCameraModel(null, "Z 5"))
    }

    @Test
    fun generatedCopyNeverReusesAnOccupiedName() {
        val occupied = setOf(
            "DSC_0123_frame_mist.jpg",
            "DSC_0123_frame_mist (1).jpg",
        )

        assertEquals(
            "DSC_0123_frame_mist (2).jpg",
            uniqueName("DSC_0123_frame_mist.jpg", occupied),
        )
    }

    @Test
    fun generatedCopyTreatsNamesCaseInsensitively() {
        val occupied = setOf(
            "dsc_0123_FRAME_MIST.JPG",
            "DSC_0123_frame_mist (1).jpg",
        )

        assertEquals(
            "DSC_0123_frame_mist (2).jpg",
            uniqueName("DSC_0123_frame_mist.jpg", occupied),
        )
    }

    @Test
    fun emptyMetadataStillProducesAStableBrandLine() {
        val metadata = PhotoFrameMetadata(
            make = null,
            model = null,
            aperture = null,
            shutter = null,
            iso = null,
            focalLength = null,
        )

        assertEquals("", normalizeCameraMake(metadata.make))
        assertEquals("", frameDetailLine(metadata))
    }

    @Test
    fun isoFormattingNeverDuplicatesThePrefix() {
        assertEquals("ISO400", normalizeIso("400"))
        assertEquals("ISO400", normalizeIso("ISO 400"))
        assertEquals("ISO400", normalizeIso("400, 800"))
        assertEquals(null, normalizeIso(null))
    }

    @Test
    fun slowShutterFormattingDoesNotRoundPointEightSecondsToOneSecond() {
        assertEquals("2s", formatShutter(2.0))
        assertEquals("0.8s", formatShutter(0.8))
        assertEquals("1/3", formatShutter(1.0 / 3.0))
        assertEquals("1/125", formatShutter(1.0 / 125.0))
    }

    @Test
    fun incompleteFrameUsesAHiddenTemporaryName() {
        val name = photoFrameTempName(12345L)

        assertTrue(name.startsWith(PHOTO_FRAME_PART_PREFIX))
        assertTrue(name.endsWith(".jpg"))
        assertTrue(!name.contains("DSC_"))
        assertTrue(isCurrentPhotoFrameTempName(name))
    }

    @Test
    fun generatedFrameNamesAreRecognizedForIndexFiltering() {
        assertTrue(isPhotoFrameOutputName("DSC_0123_frame_mist.jpg"))
        assertTrue(isPhotoFrameOutputName("DSC_0123_frame_glass (2).JPG"))
        assertTrue(isPhotoFrameOutputName("DSC_0123_frame_dark_123456.jpeg"))
        assertTrue(!isPhotoFrameOutputName("DSC_0123.JPG"))
    }
}
