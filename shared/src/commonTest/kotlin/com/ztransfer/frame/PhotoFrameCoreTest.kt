package com.ztransfer.frame

import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PhotoFrameCoreTest {
    @Test
    fun persistedPresetsAndWatermarkNormalizationStayStable() {
        assertEquals(PhotoFramePreset.FROSTED, PhotoFramePreset.valueOf("FROSTED"))
        assertEquals(PhotoFramePreset.FILM_EDGE, PhotoFramePreset.valueOf("FILM_EDGE"))
        assertEquals(1, normalizePhotoFrameWatermarkSizePercent(-1))
        assertEquals(300, normalizePhotoFrameWatermarkSizePercent(301))
        assertEquals(72, normalizePhotoFrameWatermarkOpacityPercent(72))
        assertEquals(255, watermarkAlpha(101))
        assertTrue(PhotoFramePreset.BRAND_INSET.isBrandFrame())
        assertTrue(PhotoFramePreset.FILM_GALLERY.isEditorialFrame())
        assertFalse(PhotoFramePreset.MIST.isEditorialFrame())
    }

    @Test
    fun watermarkTextAndPrivateImageHashAreNormalizedWithoutJvmApis() {
        val limited = limitPhotoFrameWatermarkText("a".repeat(23) + "📷tail")
        assertEquals("a".repeat(23) + "📷", limited)
        assertEquals("line one line two", limitPhotoFrameWatermarkText("line one\nline two"))
        assertEquals("ZTransfer", PhotoFrameWatermark(text = "\t").displayText)

        val uppercaseHash = "A1".repeat(32)
        assertEquals(uppercaseHash.lowercase(), validPhotoFrameWatermarkImageHash(uppercaseHash))
        assertEquals(null, validPhotoFrameWatermarkImageHash("../watermark.png"))
        assertEquals(null, validPhotoFrameWatermarkImageHash("a".repeat(63)))
    }

    @Test
    fun regularPlaqueImmersiveAndOriginalLayoutsPreserveExistingGeometry() {
        val landscape = calculatePhotoFrameLayout(6000, 4000)
        val portrait = calculatePhotoFrameLayout(4000, 6000)
        assertEquals(3200 to 2400, landscape.canvasWidth to landscape.canvasHeight)
        assertEquals(2133 to 3200, portrait.canvasWidth to portrait.canvasHeight)
        assertTrue(landscape.photoBottom < landscape.metadataTop)
        assertTrue(portrait.photoBottom < portrait.metadataTop)

        val plaque = calculateOriginalQualityPlaqueLayout(6000, 4000)
        assertEquals(6000 to 4720, plaque.canvasWidth to plaque.canvasHeight)
        assertEquals(6000f, plaque.photoRight - plaque.photoLeft, 0.001f)
        assertEquals(4000f, plaque.photoBottom - plaque.photoTop, 0.001f)

        val immersive = calculateImmersiveFrameLayout(6000, 4000)
        assertEquals(3200 to 2133, immersive.canvasWidth to immersive.canvasHeight)
        assertEquals(immersive.canvasWidth.toFloat(), immersive.photoRight)

        val original = calculateOriginalQualityPhotoFrameLayout(8256, 5504)
        assertEquals(8256f, original.photoRight - original.photoLeft, 0.001f)
        assertEquals(5504f, original.photoBottom - original.photoTop, 0.001f)
    }

    @Test
    fun brandAndEditorialLayoutsKeepEverySourcePixel() {
        listOf(PhotoFramePreset.BRAND_INSET, PhotoFramePreset.BRAND_GALLERY).forEach { preset ->
            val layout = calculateOriginalQualityBrandFrameLayout(6000, 4000, preset)
            assertEquals(6000f, layout.photoRight - layout.photoLeft, 0.001f)
            assertEquals(4000f, layout.photoBottom - layout.photoTop, 0.001f)
            assertTrue(layout.photoBottom < layout.canvasHeight)
        }
        listOf(
            PhotoFramePreset.CLASSIC_SIGNATURE,
            PhotoFramePreset.GALLERY_MAT,
            PhotoFramePreset.COLOR_ARCHIVE,
            PhotoFramePreset.FILM_GALLERY,
            PhotoFramePreset.FILM_EDGE,
        ).forEach { preset ->
            val layout = calculateOriginalQualityEditorialFrameLayout(6000, 4000, preset)
            assertEquals(6000f, layout.photoRight - layout.photoLeft, 0.001f)
            assertEquals(4000f, layout.photoBottom - layout.photoTop, 0.001f)
            assertTrue(layout.photoLeft >= 0f && layout.photoTop >= 0f)
            assertTrue(layout.photoRight <= layout.canvasWidth && layout.photoBottom <= layout.canvasHeight)
        }
    }

    @Test
    fun brandMetadataAndPhotoWatermarkBoundsNeverOverlap() {
        val photo = BrandFrameBounds(0f, 0f, 1000f, 600f)
        val watermark = BrandFrameBounds(260f, 480f, 740f, 570f)
        val metadata = placeBrandMetadataBlock(photo, 580f, 64f, 820f, watermark, 24f)
        assertEquals(456f, metadata.bottom, 0.001f)
        assertFalse(metadata.intersects(watermark))

        val text = PhotoWatermarkTextBounds(-2f, -20f, 98f, 5f)
        val placements = listOf(
            PhotoFrameWatermarkPosition.PHOTO_TOP_LEFT,
            PhotoFrameWatermarkPosition.PHOTO_TOP_CENTER,
            PhotoFrameWatermarkPosition.PHOTO_TOP_RIGHT,
            PhotoFrameWatermarkPosition.PHOTO_CENTER,
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_LEFT,
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER,
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT,
        ).map { calculatePhotoWatermarkPlacement(100f, 50f, 1100f, 650f, text, it) }
        assertEquals(7, placements.distinct().size)
        placements.forEach { placement ->
            assertTrue(placement.originX + text.left >= 124f)
            assertTrue(placement.originX + text.right <= 1076f)
            assertTrue(placement.baseline + text.top >= 74f)
            assertTrue(placement.baseline + text.bottom <= 626f)
        }
    }

    @Test
    fun textRowsStayCenteredAndShrinkOnlyWhenNecessary() {
        val rows = listOf(
            FrameTextVisualBounds(-30f, 7f),
            FrameTextVisualBounds(-18f, 4f),
            FrameTextVisualBounds(-11f, 3f),
        )
        val baselines = centeredFrameTextBaselines(100f, 300f, rows, 14f)
        val visibleTop = baselines.first() + rows.first().top
        val visibleBottom = baselines.last() + rows.last().bottom
        assertEquals(200f, (visibleTop + visibleBottom) / 2f, 0.001f)
        assertEquals(1f, frameTextScaleToFit(200f, rows))
        assertTrue(frameTextScaleToFit(20f, rows) < 1f)
        assertEquals(6f, frameMetadataVerticalPadding(100f), 0.001f)
    }

    @Test
    fun cameraAndMetadataTextRulesRemainPlatformNeutral() {
        val metadata = PhotoFrameMetadata(
            make = "NIKON CORPORATION",
            model = "NIKON Z 5",
            aperture = "f/4.2",
            shutter = "1/125",
            iso = "ISO400",
            focalLength = "26mm",
        )
        assertEquals("NIKON", cameraBrandLabel(metadata.make, metadata.model))
        assertEquals("Z 5", normalizeCameraModel(metadata.make, metadata.model))
        assertEquals("26mm   F4.2   1/125s   ISO400", frameDetailLine(metadata))
        assertEquals("26mm  f/4.2  1/125s  ISO400", immersiveFrameDetailLine(metadata))
        assertEquals("ISO400", normalizeIso("ISO 400, 800"))
        assertEquals("2025-11-09 16:32:35", normalizeCaptureDateTime("2025:11:09 16:32:35"))
    }

    @Test
    fun locationAndExposureFormattingKeepRulesInCommonCode() {
        val metadata = PhotoFrameMetadata(
            make = null,
            model = null,
            aperture = null,
            shutter = null,
            iso = null,
            focalLength = null,
            latitude = 30.123456,
            longitude = 120.987654,
            altitudeMeters = 520.0,
            address = "not rendered",
        )
        assertEquals(
            listOf("30.1235°N, 120.9877°E  520m"),
            frameLocationRows(metadata, ::fixedDecimal),
        )
        assertEquals("f/4.2", formatApertureText(4.2, ::fixedDecimal))
        assertEquals("0.8s", formatShutterText(0.8, ::fixedDecimal))
        assertEquals("1/125", formatShutterText(1.0 / 125.0, ::fixedDecimal))
    }

    private fun fixedDecimal(value: Double, fractionDigits: Int): String {
        val factor = when (fractionDigits) {
            0 -> 1.0
            1 -> 10.0
            4 -> 10_000.0
            else -> error("unsupported precision")
        }
        val rounded = (value * factor).roundToInt() / factor
        if (fractionDigits == 0) return rounded.roundToInt().toString()
        val whole = rounded.toInt()
        val fraction = abs(((rounded - whole) * factor).roundToInt())
        return "$whole.${fraction.toString().padStart(fractionDigits, '0')}"
    }
}
