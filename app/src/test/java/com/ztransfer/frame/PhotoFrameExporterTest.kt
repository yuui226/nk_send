package com.ztransfer.frame

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoFrameExporterTest {
    @Test
    fun frostedPresetKeepsItsStablePersistenceKey() {
        assertEquals(PhotoFramePreset.FROSTED, PhotoFramePreset.valueOf("FROSTED"))
        assertEquals(PhotoFramePreset.PLAQUE, PhotoFramePreset.valueOf("PLAQUE"))
    }

    @Test
    fun plaquePresetKeepsPhotoFullBleedAndUsesAWidthBasedInfoBand() {
        val landscape = calculatePlaqueFrameLayout(6000, 4000)
        val portrait = calculatePlaqueFrameLayout(4000, 6000)

        listOf(landscape, portrait).forEach { layout ->
            assertEquals(0f, layout.photoLeft, 0.001f)
            assertEquals(0f, layout.photoTop, 0.001f)
            assertEquals(layout.canvasWidth.toFloat(), layout.photoRight, 0.001f)
            assertEquals(layout.metadataTop, layout.photoBottom, 0.001f)
            assertEquals(
                0.12f,
                (layout.canvasHeight - layout.metadataTop) / layout.canvasWidth,
                0.001f,
            )
            assertTrue(maxOf(layout.canvasWidth, layout.canvasHeight) <= 3200)
        }
        assertEquals(3200, landscape.canvasWidth)
        assertEquals(3200, portrait.canvasHeight)
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
    fun visibleTextBoundsAreCenteredWithAndWithoutBranding() {
        val title = FrameTextVisualBounds(top = -30f, bottom = 7f)
        val details = FrameTextVisualBounds(top = -18f, bottom = 4f)
        val branding = FrameTextVisualBounds(top = -11f, bottom = 3f)

        listOf(
            listOf(title, details, branding),
            listOf(title, details),
        ).forEach { rows ->
            val baselines = centeredFrameTextBaselines(
                areaTop = 100f,
                areaBottom = 300f,
                rows = rows,
                preferredGap = 14f,
            )
            val visibleTop = baselines.first() + rows.first().top
            val visibleBottom = baselines.last() + rows.last().bottom

            assertEquals(200f, (visibleTop + visibleBottom) / 2f, 0.001f)
        }
    }

    @Test
    fun plaqueColumnsCenterIndependentlySoLeftBrandingCannotShiftRightDetails() {
        val title = FrameTextVisualBounds(top = -30f, bottom = 7f)
        val subtitle = FrameTextVisualBounds(top = -18f, bottom = 4f)
        val branding = FrameTextVisualBounds(top = -11f, bottom = 3f)
        val rightRows = listOf(title, subtitle)

        val leftBaselines = centeredFrameTextBaselines(
            areaTop = 100f,
            areaBottom = 300f,
            rows = listOf(title, subtitle, branding),
            preferredGap = 14f,
        )
        val rightBaselines = centeredFrameTextBaselines(
            areaTop = 100f,
            areaBottom = 300f,
            rows = rightRows,
            preferredGap = 14f,
        )
        val rightBaselinesWithoutBranding = centeredFrameTextBaselines(
            areaTop = 100f,
            areaBottom = 300f,
            rows = rightRows,
            preferredGap = 14f,
        )

        val leftCenter =
            (leftBaselines.first() + title.top + leftBaselines.last() + branding.bottom) / 2f
        val rightCenter =
            (rightBaselines.first() + title.top + rightBaselines.last() + subtitle.bottom) / 2f
        assertEquals(200f, leftCenter, 0.001f)
        assertEquals(200f, rightCenter, 0.001f)
        assertEquals(rightBaselinesWithoutBranding, rightBaselines)
    }

    @Test
    fun missingMetadataRowsCollapseAndSingleRemainingLineStaysCentered() {
        val row = FrameTextVisualBounds(top = -24f, bottom = 6f)
        val baselines = centeredFrameTextBaselines(
            areaTop = 80f,
            areaBottom = 220f,
            rows = listOf(row),
            preferredGap = 12f,
        )

        assertEquals(159f, baselines.single(), 0.001f)
        assertEquals(150f, (baselines.single() + row.top + baselines.single() + row.bottom) / 2f, 0.001f)
        assertTrue(centeredFrameTextBaselines(0f, 100f, emptyList(), 10f).isEmpty())
    }

    @Test
    fun crampedMetadataAreaReducesOnlyTheGapAndKeepsOrder() {
        val rows = listOf(
            FrameTextVisualBounds(top = -30f, bottom = 10f),
            FrameTextVisualBounds(top = -20f, bottom = 10f),
            FrameTextVisualBounds(top = -10f, bottom = 10f),
        )
        val baselines = centeredFrameTextBaselines(
            areaTop = 0f,
            areaBottom = 100f,
            rows = rows,
            preferredGap = 20f,
        )

        assertEquals(30f, baselines[0], 0.001f)
        assertEquals(65f, baselines[1], 0.001f)
        assertEquals(90f, baselines[2], 0.001f)
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
    fun exifCaptureDateUsesReadableSeparatorsWithoutInventingMissingValues() {
        assertEquals(
            "2025-11-09 16:32:35",
            normalizeCaptureDateTime("2025:11:09 16:32:35"),
        )
        assertEquals("2025-11-09", normalizeCaptureDateTime("2025-11-09"))
        assertEquals(null, normalizeCaptureDateTime("  "))
        assertEquals(null, normalizeCaptureDateTime(null))
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
        assertTrue(isPhotoFrameOutputName("DSC_0123_frame_plaque.jpg"))
        assertTrue(!isPhotoFrameOutputName("DSC_0123.JPG"))
    }
}
