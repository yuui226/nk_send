package com.ztransfer.frame

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoFrameExporterTest {
    @Test
    fun localPhotoOutputRecognizesStandardAndRestrictedImageDirectories() {
        assertTrue(isStandardImageRelativePath("DCIM/Camera/"))
        assertTrue(isStandardImageRelativePath("pictures/Screenshots"))
        assertTrue(!isStandardImageRelativePath("Download/ZTransfer"))
        assertTrue(!isStandardImageRelativePath("CameraImports"))

        assertTrue(canCreateDerivedImageInOriginalPath("DCIM/Camera", false, 29))
        assertTrue(!canCreateDerivedImageInOriginalPath("Download/ZTransfer", true, 29))
        assertTrue(!canCreateDerivedImageInOriginalPath("Download/ZTransfer", false, 30))
        assertTrue(canCreateDerivedImageInOriginalPath("Download/ZTransfer", true, 30))
        assertEquals("Pictures/ZTransfer", LOCAL_PHOTO_FALLBACK_RELATIVE_PATH)
    }

    @Test
    fun localPhotoOutputNeverUsesTheSyntheticExternalVolumeForInsertion() {
        val writable = setOf("external_primary", "1234-5678")

        assertEquals(
            "external_primary",
            resolveWritableMediaVolume("external", "external_primary", writable),
        )
        assertEquals(
            "1234-5678",
            resolveWritableMediaVolume("1234-5678", "external", writable),
        )
        assertNull(resolveWritableMediaVolume("external", "external", writable))
        assertEquals("external_primary", defaultWritableMediaVolume(writable))
        assertEquals("1234-5678", defaultWritableMediaVolume(setOf("1234-5678")))
    }

    @Test
    fun supportedFrameSourcesIncludeJpegAndPngOnly() {
        assertTrue(isSupportedPhotoFrameSourceExtension(".jpg"))
        assertTrue(isSupportedPhotoFrameSourceExtension("JPEG"))
        assertTrue(isSupportedPhotoFrameSourceExtension(".png"))
        assertTrue(isSupportedPhotoFrameSourceExtension("PNG"))
        assertTrue(!isSupportedPhotoFrameSourceExtension(".nef"))
        assertTrue(!isSupportedPhotoFrameSourceExtension(".mp4"))
    }

    @Test
    fun frostedPresetKeepsItsStablePersistenceKey() {
        assertEquals(PhotoFramePreset.FROSTED, PhotoFramePreset.valueOf("FROSTED"))
        assertEquals(PhotoFramePreset.PLAQUE, PhotoFramePreset.valueOf("PLAQUE"))
        assertEquals(PhotoFramePreset.IMMERSIVE, PhotoFramePreset.valueOf("IMMERSIVE"))
    }

    @Test
    fun immersivePresetKeepsTheOriginalAspectRatioWithoutAddingABorder() {
        val landscape = calculateImmersiveFrameLayout(6000, 4000)
        val portrait = calculateImmersiveFrameLayout(4000, 6000)
        val alreadySmall = calculateImmersiveFrameLayout(1200, 800)

        assertEquals(3200 to 2133, landscape.canvasWidth to landscape.canvasHeight)
        assertEquals(2133 to 3200, portrait.canvasWidth to portrait.canvasHeight)
        assertEquals(1200 to 800, alreadySmall.canvasWidth to alreadySmall.canvasHeight)
        listOf(landscape, portrait, alreadySmall).forEach { layout ->
            assertEquals(0f, layout.photoLeft, 0.001f)
            assertEquals(0f, layout.photoTop, 0.001f)
            assertEquals(layout.canvasWidth.toFloat(), layout.photoRight, 0.001f)
            assertEquals(layout.canvasHeight.toFloat(), layout.photoBottom, 0.001f)
            assertEquals(layout.photoBottom, layout.metadataTop, 0.001f)
        }
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
    fun visibleTextBoundsAreCenteredWithAndWithoutWatermark() {
        val title = FrameTextVisualBounds(top = -30f, bottom = 7f)
        val details = FrameTextVisualBounds(top = -18f, bottom = 4f)
        val watermark = FrameTextVisualBounds(top = -11f, bottom = 3f)

        listOf(
            listOf(title, details, watermark),
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
    fun plaqueWatermarkUsesItsOwnRowBelowBothMetadataColumns() {
        val primary = FrameTextVisualBounds(top = -30f, bottom = 7f)
        val secondary = FrameTextVisualBounds(top = -18f, bottom = 4f)
        val watermark = FrameTextVisualBounds(top = -16f, bottom = 4f)
        val rows = listOf(primary, secondary, watermark)
        val baselines = centeredFrameTextBaselines(100f, 300f, rows, preferredGap = 14f)

        val secondaryBottom = baselines[1] + secondary.bottom
        val watermarkTop = baselines[2] + watermark.top
        assertTrue(secondaryBottom < watermarkTop)
        assertEquals(
            200f,
            (baselines.first() + primary.top + baselines.last() + watermark.bottom) / 2f,
            0.001f,
        )
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
    fun oversizedWatermarkRowsAreScaledBeforeBaselineLayout() {
        val rows = listOf(
            FrameTextVisualBounds(top = -60f, bottom = 10f),
            FrameTextVisualBounds(top = -45f, bottom = 10f),
            FrameTextVisualBounds(top = -100f, bottom = 20f),
        )
        val scale = frameTextScaleToFit(areaHeight = 100f, rows = rows)
        val fitted = rows.map { row ->
            FrameTextVisualBounds(row.top * scale, row.bottom * scale)
        }
        val baselines = centeredFrameTextBaselines(0f, 100f, fitted, preferredGap = 12f)

        fitted.zipWithNext().indices.forEach { index ->
            val currentBottom = baselines[index] + fitted[index].bottom
            val nextTop = baselines[index + 1] + fitted[index + 1].top
            assertTrue(currentBottom <= nextTop)
        }
        assertTrue(baselines.last() + fitted.last().bottom <= 100f)
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
    fun detailLineKeepsComfortableSpacingBetweenCameraParameters() {
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

        assertEquals("26mm   F4.2   1/125s   ISO400", detail)
        assertEquals("Nikon", normalizeCameraMake("NIKON CORPORATION"))
        assertEquals(
            "Z 5",
            normalizeCameraModel("NIKON CORPORATION", "NIKON Z 5"),
        )
        assertEquals(
            "26mm  f/4.2  1/125s  ISO400",
            immersiveFrameDetailLine(
                PhotoFrameMetadata(
                    make = "NIKON CORPORATION",
                    model = "NIKON Z 5",
                    aperture = "f/4.2",
                    shutter = "1/125",
                    iso = "ISO400",
                    focalLength = "26mm",
                ),
            ),
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
        assertTrue(isPhotoFrameOutputName("DSC_0123_watermark_w123456789abc.jpg"))
        assertTrue(!isPhotoFrameOutputName("DSC_0123.JPG"))
    }

    @Test
    fun existingFrameLookupMatchesOnlyTheSameSourceAndPreset() {
        val mistName = photoFrameOutputName("DSC_0123.JPG", PhotoFramePreset.MIST)
        val mistStem = mistName.substringBeforeLast('.')
        val plaqueName = photoFrameOutputName("DSC_0123 (1).JPG", PhotoFramePreset.PLAQUE)
        val plaqueStem = plaqueName.substringBeforeLast('.')

        assertTrue(mistName.matches(Regex("DSC_0123_frame_mist_w[0-9a-f]{12}\\.jpg")))
        assertTrue(
            isPhotoFrameOutputFor(
                "$mistStem (2).JPG",
                "DSC_0123.JPG",
                PhotoFramePreset.MIST,
            ),
        )
        assertTrue(
            isPhotoFrameOutputFor(
                "${plaqueStem}_123456.jpg",
                "DSC_0123 (1).JPG",
                PhotoFramePreset.PLAQUE,
            ),
        )
        assertTrue(
            !isPhotoFrameOutputFor(
                photoFrameOutputName("DSC_0123.JPG", PhotoFramePreset.CINEMA),
                "DSC_0123.JPG",
                PhotoFramePreset.MIST,
            ),
        )
        assertTrue(
            !isPhotoFrameOutputFor(
                photoFrameOutputName("DSC_9999.JPG", PhotoFramePreset.MIST),
                "DSC_0123.JPG",
                PhotoFramePreset.MIST,
            ),
        )
        assertTrue(
            !isPhotoFrameOutputFor(
                "DSC_0123_frame_mist.jpg",
                "DSC_0123.JPG",
                PhotoFramePreset.MIST,
            ),
        )
    }

    @Test
    fun watermarkOnlyOutputHasItsOwnStableIdentityIndependentOfHiddenFrameStyle() {
        val watermark = PhotoFrameWatermark(
            text = "Studio",
            position = PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT,
        )
        val mist = photoFrameOutputName(
            "DSC.JPG",
            PhotoFramePreset.MIST,
            watermark,
            borderEnabled = false,
        )
        val plaque = photoFrameOutputName(
            "DSC.JPG",
            PhotoFramePreset.PLAQUE,
            watermark,
            borderEnabled = false,
        )

        assertEquals(mist, plaque)
        assertTrue(mist.matches(Regex("DSC_watermark_w[0-9a-f]{12}\\.jpg")))
        assertTrue(isPhotoFrameOutputName(mist))
        assertTrue(
            isPhotoFrameOutputFor(
                mist,
                "DSC.JPG",
                PhotoFramePreset.MIST,
                watermark,
                borderEnabled = false,
            ),
        )
        assertTrue(
            !isPhotoFrameOutputFor(
                mist,
                "DSC.JPG",
                PhotoFramePreset.MIST,
                watermark,
                borderEnabled = true,
            ),
        )
    }

    @Test
    fun customWatermarkGetsAStablePrivateOutputIdentity() {
        val first = PhotoFrameWatermark(text = "Studio A")
        val same = PhotoFrameWatermark(text = " Studio A ")
        val second = PhotoFrameWatermark(text = "Studio B")
        val firstName = photoFrameOutputName("DSC_0123.JPG", PhotoFramePreset.MIST, first)

        assertEquals(firstName, photoFrameOutputName("DSC_0123.JPG", PhotoFramePreset.MIST, same))
        assertTrue(firstName != photoFrameOutputName("DSC_0123.JPG", PhotoFramePreset.MIST, second))
        assertTrue(firstName.matches(Regex("DSC_0123_frame_mist_w[0-9a-f]{12}\\.jpg")))
        assertTrue(!firstName.contains("Studio", ignoreCase = true))
        assertTrue(isPhotoFrameOutputName(firstName))
        assertTrue(isPhotoFrameOutputFor(firstName, "DSC_0123.JPG", PhotoFramePreset.MIST, first))
        assertTrue(!isPhotoFrameOutputFor(firstName, "DSC_0123.JPG", PhotoFramePreset.MIST, second))
    }

    @Test
    fun visuallyEquivalentAutoAndExplicitPositionsShareAnOutputIdentity() {
        assertEquals(
            photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST),
            photoFrameOutputName(
                "DSC.JPG",
                PhotoFramePreset.MIST,
                PhotoFrameWatermark(position = PhotoFrameWatermarkPosition.CENTER),
            ),
        )
        assertEquals(
            photoFrameOutputName("DSC.JPG", PhotoFramePreset.PLAQUE),
            photoFrameOutputName(
                "DSC.JPG",
                PhotoFramePreset.PLAQUE,
                PhotoFrameWatermark(position = PhotoFrameWatermarkPosition.LEFT),
            ),
        )
    }

    @Test
    fun watermarkOnlyIdentityNormalizesBorderPositionsAndIgnoresHiddenPreset() {
        val automatic = PhotoFrameWatermark(position = PhotoFrameWatermarkPosition.AUTO)
        val explicit = PhotoFrameWatermark(
            position = PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT,
        )

        assertEquals(
            photoFrameOutputName(
                "DSC.JPG",
                PhotoFramePreset.MIST,
                automatic,
                borderEnabled = false,
            ),
            photoFrameOutputName(
                "DSC.JPG",
                PhotoFramePreset.PLAQUE,
                explicit,
                borderEnabled = false,
            ),
        )
    }

    @Test
    fun watermarkColorChangesTheVersionedOutputIdentity() {
        val adaptive = PhotoFrameWatermark(color = PhotoFrameWatermarkColor.ADAPTIVE)
        val gold = PhotoFrameWatermark(color = PhotoFrameWatermarkColor.GOLD)
        val adaptiveName = photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST, adaptive)

        assertTrue(adaptiveName.matches(Regex("DSC_frame_mist_w[0-9a-f]{12}\\.jpg")))
        assertEquals(adaptiveName, photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST, adaptive))
        assertTrue(
            photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST, gold) !=
                adaptiveName,
        )
    }

    @Test
    fun photoWatermarkPositionsStayInsideTheFourPercentSafeAreaAndRemainDistinct() {
        val photoLeft = 100f
        val photoTop = 50f
        val photoRight = 1100f
        val photoBottom = 650f
        val bounds = PhotoWatermarkTextBounds(
            left = -2f,
            top = -20f,
            right = 98f,
            bottom = 5f,
        )
        val photoPositions = listOf(
            PhotoFrameWatermarkPosition.PHOTO_TOP_LEFT,
            PhotoFrameWatermarkPosition.PHOTO_TOP_CENTER,
            PhotoFrameWatermarkPosition.PHOTO_TOP_RIGHT,
            PhotoFrameWatermarkPosition.PHOTO_CENTER,
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_LEFT,
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER,
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT,
        )

        val placements = photoPositions.map { position ->
            calculatePhotoWatermarkPlacement(
                photoLeft = photoLeft,
                photoTop = photoTop,
                photoRight = photoRight,
                photoBottom = photoBottom,
                textBounds = bounds,
                position = position,
            )
        }
        val safeInset = 24f // 4% of the 600 px short edge.
        placements.forEach { placement ->
            assertTrue(placement.originX + bounds.left >= photoLeft + safeInset)
            assertTrue(placement.originX + bounds.right <= photoRight - safeInset)
            assertTrue(placement.baseline + bounds.top >= photoTop + safeInset)
            assertTrue(placement.baseline + bounds.bottom <= photoBottom - safeInset)
        }
        assertEquals(7, placements.distinct().size)

        val center = placements[3]
        assertEquals(
            (photoLeft + photoRight) / 2f,
            center.originX + (bounds.left + bounds.right) / 2f,
            0.001f,
        )
        assertEquals(
            (photoTop + photoBottom) / 2f,
            center.baseline + (bounds.top + bounds.bottom) / 2f,
            0.001f,
        )
    }

    @Test
    fun watermarkOpacityMapsToAnUnambiguousFinalAlpha() {
        assertEquals(3, watermarkAlpha(1))
        assertEquals(102, watermarkAlpha(40))
        assertEquals(184, watermarkAlpha(72))
        assertEquals(255, watermarkAlpha(100))
        assertEquals(3, watermarkAlpha(-1))
        assertEquals(255, watermarkAlpha(101))
    }

    @Test
    fun watermarkSizeScaleStartsAtTheFormerFiftyPercentAndExtendsToThreeHundred() {
        assertEquals(0.0105f * 50f / 58f, photoFrameWatermarkTextSizeFraction(1), 0.000001f)
        assertEquals(0.0105f, photoFrameWatermarkTextSizeFraction(9), 0.000001f)
        assertEquals(0.0135f, photoFrameWatermarkTextSizeFraction(26), 0.000001f)
        assertEquals(0.018f, photoFrameWatermarkTextSizeFraction(51), 0.000001f)
        assertEquals(0.036f, photoFrameWatermarkTextSizeFraction(151), 0.000001f)
        assertEquals(0.018f * 3.49f, photoFrameWatermarkTextSizeFraction(300), 0.000001f)
        assertEquals(
            0.035f + (0.052f - 0.035f) * 3f / 22f,
            photoFrameWatermarkImageSizeFraction(1),
            0.000001f,
        )
        assertEquals(0.052f, photoFrameWatermarkImageSizeFraction(20), 0.000001f)
        assertEquals(0.075f, photoFrameWatermarkImageSizeFraction(51), 0.000001f)
        assertEquals(0.15f, photoFrameWatermarkImageSizeFraction(151), 0.000001f)
        assertEquals(0.075f * 3.49f, photoFrameWatermarkImageSizeFraction(300), 0.000001f)
    }

    @Test
    fun watermarkV2AlwaysUsesAStableVersionedIdentity() {
        val baseline = PhotoFrameWatermark(text = "Studio A")
        val baselineName = photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST, baseline)
        val defaultName = photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST)

        assertTrue(baselineName.matches(Regex("DSC_frame_mist_w[0-9a-f]{12}\\.jpg")))
        assertTrue(defaultName.matches(Regex("DSC_frame_mist_w[0-9a-f]{12}\\.jpg")))
        assertEquals(baselineName, photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST, baseline))
        assertTrue(defaultName != "DSC_frame_mist.jpg")

        val subtle = baseline.copy(opacityPercent = 40)
        val maximumSize = baseline.copy(sizePercent = 300)
        val outlined = baseline.copy(effect = PhotoFrameWatermarkEffect.OUTLINE)
        val onPhoto = baseline.copy(position = PhotoFrameWatermarkPosition.PHOTO_TOP_LEFT)
        assertTrue(photoFrameWatermarkFingerprint(subtle, PhotoFramePreset.MIST) !=
            photoFrameWatermarkFingerprint(baseline, PhotoFramePreset.MIST))
        assertTrue(photoFrameWatermarkFingerprint(maximumSize, PhotoFramePreset.MIST) !=
            photoFrameWatermarkFingerprint(baseline, PhotoFramePreset.MIST))
        assertTrue(photoFrameWatermarkFingerprint(outlined, PhotoFramePreset.MIST) !=
            photoFrameWatermarkFingerprint(baseline, PhotoFramePreset.MIST))
        assertTrue(photoFrameWatermarkFingerprint(onPhoto, PhotoFramePreset.MIST) !=
            photoFrameWatermarkFingerprint(baseline, PhotoFramePreset.MIST))
    }

    @Test
    fun immersiveInlineAutoWatermarkDiffersFromASeparateCenteredRow() {
        val automatic = PhotoFrameWatermark(position = PhotoFrameWatermarkPosition.AUTO)
        val centered = automatic.copy(position = PhotoFrameWatermarkPosition.CENTER)

        assertTrue(
            photoFrameWatermarkFingerprint(automatic, PhotoFramePreset.IMMERSIVE) !=
                photoFrameWatermarkFingerprint(centered, PhotoFramePreset.IMMERSIVE),
        )
    }

    @Test
    fun imageWatermarkIdentityUsesItsPrivateContentHashOnly() {
        val firstHash = "a".repeat(64)
        val secondHash = "b".repeat(64)
        val first = PhotoFrameWatermark(
            content = PhotoFrameWatermarkContent.IMAGE,
            imageHash = firstHash,
            position = PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT,
        )
        val samePixelsWithHiddenTextControlsChanged = first.copy(
            text = "Not rendered",
            font = PhotoFrameWatermarkFont.BOLD,
            color = PhotoFrameWatermarkColor.GOLD,
            effect = PhotoFrameWatermarkEffect.OUTLINE,
        )
        val second = first.copy(imageHash = secondHash)

        assertEquals(
            photoFrameWatermarkFingerprint(first, PhotoFramePreset.MIST),
            photoFrameWatermarkFingerprint(samePixelsWithHiddenTextControlsChanged, PhotoFramePreset.MIST),
        )
        assertTrue(
            photoFrameWatermarkFingerprint(first, PhotoFramePreset.MIST) !=
                photoFrameWatermarkFingerprint(second, PhotoFramePreset.MIST),
        )
    }

    @Test
    fun watermarkImageHashValidationRejectsPathsAndNormalizesCase() {
        val uppercaseHash = "A1".repeat(32)

        assertEquals(uppercaseHash.lowercase(), validPhotoFrameWatermarkImageHash(uppercaseHash))
        assertEquals(null, validPhotoFrameWatermarkImageHash("../watermark.png"))
        assertEquals(null, validPhotoFrameWatermarkImageHash("a".repeat(63)))
        assertEquals(null, validPhotoFrameWatermarkImageHash(null))
    }

    @Test
    fun watermarkLimitNeverSplitsAnEmojiSurrogatePair() {
        val value = "a".repeat(23) + "📷" + "tail"
        val limited = limitPhotoFrameWatermarkText(value)

        assertEquals(24, limited.codePointCount(0, limited.length))
        assertTrue(limited.endsWith("📷"))
        assertEquals("line one line two", limitPhotoFrameWatermarkText("line one\nline two"))
    }
}
