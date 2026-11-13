package com.ztransfer.frame

import kotlin.math.roundToInt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoFrameUniformBorderTest {
    private val supportedPresets = setOf(
        PhotoFramePreset.MIST,
        PhotoFramePreset.CINEMA,
        PhotoFramePreset.MINIMAL,
        PhotoFramePreset.FROSTED,
        PhotoFramePreset.BRAND_GALLERY,
        PhotoFramePreset.CLASSIC_SIGNATURE,
    )
    private val informationOff = PhotoFrameMetadataSettings(
        showDate = false,
        showTime = false,
        showFocalLength = false,
        showExposure = false,
        showBrand = false,
        showModel = false,
    )
    private val watermarkOff = PhotoFrameWatermark(enabled = false)

    @Test
    fun onlyFramesWithoutPermanentDecorativeBandsUseUniformMargins() {
        for (preset in PhotoFramePreset.entries) {
            assertEquals(preset.name, preset in supportedPresets,
                usesUniformPhotoFrameBorder(preset, informationOff, watermarkOff))
        }
    }

    @Test
    fun brandInsetRetainsItsAlreadyUniformLegacyGeometry() {
        val preset = PhotoFramePreset.BRAND_INSET
        assertFalse(usesUniformPhotoFrameBorder(preset, informationOff, watermarkOff))
        for ((width, height) in listOf(6000 to 4000, 4000 to 6000, 4033 to 3025, 80 to 120)) {
            val layout = calculateOriginalQualityFrameLayout(width, height, preset)
            assertEquals(layout.photoLeft, layout.photoTop, 0f)
            assertEquals(layout.photoLeft, layout.canvasWidth - layout.photoRight, 0f)
            assertEquals(layout.photoLeft, layout.canvasHeight - layout.photoBottom, 0f)
            assertEquals(width.toFloat(), layout.photoRight - layout.photoLeft, 0f)
            assertEquals(height.toFloat(), layout.photoBottom - layout.photoTop, 0f)
        }
    }

    @Test
    fun onlyInformationDisplayedInTheBandRestoresTheOriginalLayout() {
        val enabledFields = listOf(
            "date" to informationOff.copy(showDate = true),
            "time" to informationOff.copy(showTime = true),
            "focal length" to informationOff.copy(showFocalLength = true),
            "exposure" to informationOff.copy(showExposure = true),
            "brand" to informationOff.copy(showBrand = true),
            "model" to informationOff.copy(showModel = true),
            "lens model" to informationOff.copy(showLensModel = true),
            "coordinates" to informationOff.copy(showCoordinates = true),
            "altitude" to informationOff.copy(showAltitude = true),
            "city" to informationOff.copy(showCity = true),
            "region" to informationOff.copy(showRegion = true),
        )
        for (preset in supportedPresets) {
            for ((field, enabled) in enabledFields) {
                val remainsUniform = preset == PhotoFramePreset.BRAND_GALLERY &&
                    field !in setOf("brand", "model")
                assertEquals("$preset: $field enabled", remainsUniform,
                    usesUniformPhotoFrameBorder(preset, enabled, watermarkOff))
                assertTrue("$preset: $field disabled again",
                    usesUniformPhotoFrameBorder(preset, informationOff, watermarkOff))
            }
        }
    }

    @Test
    fun brandGalleryKeepsPhotoInformationWhileOnlyBrandModelAndBandWatermarksReserveABand() {
        val settings = informationOff.copy(
            showDate = true,
            showTime = true,
            showFocalLength = true,
            showExposure = true,
            showLensModel = true,
            showCoordinates = true,
            showAltitude = true,
            showCity = true,
            showRegion = true,
        )
        val source = PhotoFrameMetadata(
            make = "NIKON",
            model = "NIKON Z 30",
            aperture = "f/2.8",
            shutter = "1/125",
            iso = "ISO400",
            focalLength = "35mm",
            lensModel = "NIKKOR Z 35mm f/1.8 S",
            dateTime = "2026-10-22 12:34:56",
            latitude = 31.2304,
            longitude = 121.4737,
            altitudeMeters = 12.0,
            city = "Shanghai",
            region = "Huangpu",
        )
        assertTrue(settings.requiresCameraMetadata)
        assertTrue(usesUniformPhotoFrameBorder(PhotoFramePreset.BRAND_GALLERY, settings, watermarkOff))
        // Equal borders remove only the unused band. Both preview and export must retain
        // actual metadata for the separately measured text inside the photo.
        for (preview in listOf(false, true)) {
            val presented = source.withPresentation(settings, preview = preview)
            assertEquals(source.copy(make = null, model = null), presented)
        }
        for (showBrand in listOf(false, true)) {
            for (showModel in listOf(false, true)) {
                assertEquals("brand=$showBrand model=$showModel", !showBrand && !showModel,
                    usesUniformPhotoFrameBorder(PhotoFramePreset.BRAND_GALLERY,
                        settings.copy(showBrand = showBrand, showModel = showModel), watermarkOff))
            }
        }
        for (position in PhotoFrameWatermarkPosition.entries) {
            val reservesBand = position in setOf(
                PhotoFrameWatermarkPosition.LEFT,
                PhotoFrameWatermarkPosition.CENTER,
                PhotoFrameWatermarkPosition.RIGHT,
            )
            assertEquals(position.name, !reservesBand, usesUniformPhotoFrameBorder(
                PhotoFramePreset.BRAND_GALLERY, settings, PhotoFrameWatermark(position = position)))
        }
    }

    @Test
    fun retiredAddressFlagAndHiddenFormattingPreferencesDoNotReserveABand() {
        val settings = informationOff.copy(
            showAddress = true,
            brandStyle = PhotoFrameBrandStyle.LOGO,
            datePattern = "MM-dd-yyyy",
            timePattern = "HH.mm.ss",
            backgroundBlurPercent = 20,
            backgroundMaskPercent = 180,
            widthPercent = 145,
        )
        assertFalse(normalizePhotoFrameMetadataSettings(settings).showAddress)
        for (preset in supportedPresets) {
            assertTrue(preset.name, usesUniformPhotoFrameBorder(preset, settings, watermarkOff))
        }
    }

    @Test
    fun textWatermarksFollowEachPresetsActualBandOrPhotoPlacement() {
        val insidePhoto = setOf(
            PhotoFrameWatermarkPosition.PHOTO_TOP_LEFT,
            PhotoFrameWatermarkPosition.PHOTO_TOP_CENTER,
            PhotoFrameWatermarkPosition.PHOTO_TOP_RIGHT,
            PhotoFrameWatermarkPosition.PHOTO_CENTER,
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_LEFT,
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER,
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT,
        )
        for (preset in supportedPresets) {
            for (position in PhotoFrameWatermarkPosition.entries) {
                // These two styles render AUTO inside the photo.
                val expected = position in insidePhoto ||
                    (position == PhotoFrameWatermarkPosition.AUTO && preset in setOf(
                        PhotoFramePreset.BRAND_GALLERY, PhotoFramePreset.CLASSIC_SIGNATURE))
                val watermark = PhotoFrameWatermark(enabled = true, position = position)
                assertEquals("$preset: text $position", expected,
                    usesUniformPhotoFrameBorder(preset, informationOff, watermark))
                assertTrue("$preset: disabled text $position",
                    usesUniformPhotoFrameBorder(preset, informationOff, watermark.copy(enabled = false)))
            }
        }
    }

    @Test
    fun imageWatermarksNeverOccupyTheInformationBandOfEligibleFrames() {
        for (preset in supportedPresets) {
            for (position in PhotoFrameWatermarkPosition.entries) {
                val watermark = PhotoFrameWatermark(
                    enabled = true,
                    content = PhotoFrameWatermarkContent.IMAGE,
                    imageHash = "a".repeat(64),
                    position = position,
                )
                assertTrue("$preset: image $position",
                    usesUniformPhotoFrameBorder(preset, informationOff, watermark))
            }
        }
    }

    @Test
    fun everyWidthDetentExpandsAllFourSidesWithoutResamplingOrCroppingThePhoto() {
        val sourceSizes = listOf(
            6000 to 4000,
            4000 to 6000,
            4000 to 4000,
            12000 to 3000,
            3000 to 12000,
            4033 to 3025,
            80 to 120,
        )
        for (preset in supportedPresets) {
            for ((width, height) in sourceSizes) {
                var previousMargin = 0f
                for (percent in MIN_PHOTO_FRAME_WIDTH_PERCENT..MAX_PHOTO_FRAME_WIDTH_PERCENT step PHOTO_FRAME_WIDTH_STEP) {
                    val layout = calculateUniformPhotoFrameLayout(width, height, preset, percent)
                    val label = "$preset: ${width}x$height at $percent"
                    assertEquals(label, width.toFloat(), layout.photoRight - layout.photoLeft, 0f)
                    assertEquals(label, height.toFloat(), layout.photoBottom - layout.photoTop, 0f)
                    assertEquals(label, layout.photoLeft, layout.photoTop, 0f)
                    assertEquals(label, layout.photoLeft, layout.canvasWidth - layout.photoRight, 0f)
                    assertEquals(label, layout.photoLeft, layout.canvasHeight - layout.photoBottom, 0f)
                    assertTrue(label, layout.photoLeft > 0f)
                    assertTrue(label, layout.photoLeft >= previousMargin)
                    previousMargin = layout.photoLeft
                }
            }
        }
    }

    @Test
    fun previewScalesTheExportCompositionAndKeepsThePhotoAspectRatio() {
        for (preset in supportedPresets) {
            for ((width, height) in listOf(6000 to 4000, 4000 to 6000, 4033 to 3025, 80 to 120)) {
                for (percent in listOf(60, 100, 200)) {
                    val original = calculateUniformPhotoFrameLayout(width, height, preset, percent)
                    val preview = original.fitPreview(1920, allowUpscale = true)
                    val scale = 1920f / maxOf(original.canvasWidth, original.canvasHeight)
                    val label = "$preset: ${width}x$height at $percent"
                    assertEquals(label, 1920, maxOf(preview.canvasWidth, preview.canvasHeight))
                    assertEquals(label, original.photoLeft * scale, preview.photoLeft, 0.0001f)
                    assertEquals(label, original.photoTop * scale, preview.photoTop, 0.0001f)
                    assertEquals(label, original.photoRight * scale, preview.photoRight, 0.0001f)
                    assertEquals(label, original.photoBottom * scale, preview.photoBottom, 0.0001f)
                    assertEquals(label, width.toFloat() / height,
                        (preview.photoRight - preview.photoLeft) / (preview.photoBottom - preview.photoTop), 0.0001f)
                    assertEquals(label, preview.photoLeft, preview.photoTop, 0f)
                    // Integer preview canvas dimensions can round one outer edge by half a pixel.
                    assertEquals(label, preview.photoLeft, preview.canvasWidth - preview.photoRight, 0.501f)
                    assertEquals(label, preview.photoTop, preview.canvasHeight - preview.photoBottom, 0.501f)
                    assertEquals(label, original.designWidth * scale, preview.designWidth, 0.0001f)
                    assertEquals(label, original.designHeight * scale, preview.designHeight, 0.0001f)
                    assertEquals(label, original.designMetadataTop * scale, preview.designMetadataTop, 0.0001f)
                    assertSame(original.textLayout, preview.textLayout)
                    assertSame(original.photoTextLayout, preview.photoTextLayout)
                    assertSame(original, original.fitPreview(null))
                }
            }
        }
    }

    @Test
    fun changingMarginWidthPreservesTemplateStylingAndProvidesSafeEmptyTextPlans() {
        for (preset in supportedPresets) {
            val narrow = calculateUniformPhotoFrameLayout(6000, 4000, preset, 60)
            val wide = calculateUniformPhotoFrameLayout(6000, 4000, preset, 200)
            assertTrue(preset.name, wide.photoLeft > narrow.photoLeft)
            assertEquals(narrow.designWidth, wide.designWidth, 0f)
            assertEquals(narrow.designHeight, wide.designHeight, 0f)
            assertEquals(narrow.designMetadataTop, wide.designMetadataTop, 0f)
            assertEquals(narrow.textLayoutScale, wide.textLayoutScale, 0f)
            assertEquals(photoFrameCornerRadius(narrow), photoFrameCornerRadius(wide), 0f)
            for (layout in listOf(narrow, wide)) {
                assertNotNull(preset.name, layout.textLayout)
                assertTrue(preset.name, requireNotNull(layout.textLayout).items.isEmpty())
                if (preset == PhotoFramePreset.BRAND_GALLERY) {
                    assertNotNull(preset.name, layout.photoTextLayout)
                    assertTrue(preset.name, requireNotNull(layout.photoTextLayout).items.isEmpty())
                } else {
                    assertNull(preset.name, layout.photoTextLayout)
                }
            }
        }
    }

    @Test
    fun outOfRangeWidthValuesUseTheSameBoundsAsPersistedSettings() {
        for (preset in supportedPresets) {
            val narrow = calculateUniformPhotoFrameLayout(6000, 4000, preset, 60)
            val wide = calculateUniformPhotoFrameLayout(6000, 4000, preset, 200)
            assertEquals(narrow, calculateUniformPhotoFrameLayout(6000, 4000, preset, Int.MIN_VALUE))
            assertEquals(wide, calculateUniformPhotoFrameLayout(6000, 4000, preset, Int.MAX_VALUE))
        }
    }

    @Test
    fun independentlyDownsampledPreviewsMatchOriginalLayoutsAcrossLegacyAspectThresholds() {
        val thresholdSizes = listOf(1.9, 1.1, 0.9, 0.72, 0.56).flatMap { aspect ->
            val widthAtThreshold = (aspect * 6000).roundToInt()
            listOf(-1, 0, 1).map { offset -> (widthAtThreshold + offset) to 6000 }
        }
        val sourceSizes = (thresholdSizes + listOf(
            6597 to 6000, // Reported discontinuity: its independent FHD input is 1920 x 1746.
            6000 to 4000,
            4000 to 6000,
            4000 to 4000,
            12000 to 3000,
            3000 to 12000,
            4033 to 3025,
            3025 to 4033,
            6001 to 4001,
            4001 to 6001,
        )).distinct()
        for ((width, height) in sourceSizes) {
            // Simulate a separately decoded preview. Rounding its dimensions may cross an
            // old aspect-ratio threshold; do not reuse the original frame's computed layout.
            val sourceScale = 1920.0 / maxOf(width, height)
            val previewWidth = (width * sourceScale).roundToInt().coerceAtLeast(1)
            val previewHeight = (height * sourceScale).roundToInt().coerceAtLeast(1)
            for (preset in supportedPresets) {
                for (percent in listOf(60, 100, 200)) {
                    val original = calculateUniformPhotoFrameLayout(width, height, preset, percent)
                        .fitPreview(1920, allowUpscale = true)
                    val preview = calculateUniformPhotoFrameLayout(previewWidth, previewHeight, preset, percent)
                        .fitPreview(1920, allowUpscale = true)
                    val label = "$preset: ${width}x$height -> ${previewWidth}x$previewHeight at $percent"
                    // Photo edges and canvas dimensions stay within one output pixel. The
                    // right/bottom margins subtract independently rounded edges, allowing two.
                    // Virtual design extents can exceed the canvas; check their decoration
                    // sizes separately rather than treating them as visible photo boundaries.
                    fun checkMetric(metric: String, tolerance: Float, read: (PhotoFrameLayout) -> Float) {
                        assertEquals("$label: $metric", read(original), read(preview), tolerance)
                    }
                    checkMetric("canvas width", 1f) { it.canvasWidth.toFloat() }
                    checkMetric("canvas height", 1f) { it.canvasHeight.toFloat() }
                    checkMetric("left margin", 1f) { it.photoLeft }
                    checkMetric("top margin", 1f) { it.photoTop }
                    checkMetric("right margin", 2f) { it.canvasWidth - it.photoRight }
                    checkMetric("bottom margin", 2f) { it.canvasHeight - it.photoBottom }
                    checkMetric("photo right", 1f) { it.photoRight }
                    checkMetric("photo bottom", 1f) { it.photoBottom }
                    checkMetric("metadata top", 1f) { it.metadataTop }
                    checkMetric("design width", 3f) { it.designWidth }
                    checkMetric("design height", 3f) { it.designHeight }
                    checkMetric("design metadata top", 3f) { it.designMetadataTop }
                    checkMetric("watermark size reference", 2f) { minOf(it.designWidth, it.designHeight) }
                    checkMetric("corner radius", 0.1f, ::photoFrameCornerRadius)
                }
            }
        }
    }

    @Test
    fun croppingOnlyTheHeightDoesNotChangeUniformMarginOrCornerSize() {
        for (preset in supportedPresets) {
            for (percent in listOf(60, 100, 200)) {
                val original = calculateUniformPhotoFrameLayout(6000, 4000, preset, percent)
                for (height in listOf(1500, 3157, 4001, 5454, 5455, 6000, 6666, 6667, 8333, 10714, 12000)) {
                    val cropped = calculateUniformPhotoFrameLayout(6000, height, preset, percent)
                    val label = "$preset: 6000x4000 -> 6000x$height at $percent"
                    assertEquals("$label: canvas width", original.canvasWidth, cropped.canvasWidth)
                    assertEquals("$label: left margin", original.photoLeft, cropped.photoLeft, 0f)
                    assertEquals("$label: top margin", original.photoTop, cropped.photoTop, 0f)
                    assertEquals("$label: right margin",
                        original.canvasWidth - original.photoRight, cropped.canvasWidth - cropped.photoRight, 0f)
                    assertEquals("$label: bottom margin",
                        original.canvasHeight - original.photoBottom, cropped.canvasHeight - cropped.photoBottom, 0f)
                    assertEquals("$label: photo width",
                        original.photoRight - original.photoLeft, cropped.photoRight - cropped.photoLeft, 0f)
                    assertEquals("$label: design width", original.designWidth, cropped.designWidth, 0f)
                    assertEquals("$label: corner radius", photoFrameCornerRadius(original),
                        photoFrameCornerRadius(cropped), 0.002f)
                }
            }
        }
    }
}
