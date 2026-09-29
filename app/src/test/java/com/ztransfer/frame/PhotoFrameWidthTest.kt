package com.ztransfer.frame

import org.junit.Assert.*
import org.junit.Test

class PhotoFrameWidthTest {

    @Test fun expansionPreservesEverySourcePixelAndNeverReducesAvailableMargins() {
        for ((w, h) in listOf(6000 to 4000, 4000 to 6000, 4000 to 4000, 6000 to 1000, 1000 to 6000, 80 to 120)) {
            for (preset in PhotoFramePreset.entries) {
                val original = calculateOriginalQualityFrameLayout(w, h, preset)
                assertSame(original, original.withFrameWidth(preset, 100))
                for (percent in 100..200 step 10) {
                    val layout = original.withFrameWidth(preset, percent)
                    assertEquals("$preset $percent", w.toFloat(), layout.photoRight - layout.photoLeft, 0.01f)
                    assertEquals(h.toFloat(), layout.photoBottom - layout.photoTop, 0.01f)
                    assertTrue(layout.photoLeft >= original.photoLeft)
                    assertTrue(layout.photoTop >= original.photoTop)
                    assertTrue(layout.canvasWidth - layout.photoRight >= original.canvasWidth - original.photoRight - 1f)
                    assertTrue(layout.canvasHeight - layout.photoBottom >= original.canvasHeight - original.photoBottom - 1f)
                    assertEquals(original.canvasHeight - original.photoBottom,
                        layout.canvasHeight - layout.photoBottom - layout.addedBottomMargin, 0.01f)
                    assertEquals(original.designWidth, layout.designWidth, 0f)
                    assertEquals(original.designHeight, layout.designHeight, 0f)
                    if (preset == PhotoFramePreset.GALLERY_MAT) assertEquals(layout.canvasWidth, layout.canvasHeight)
                    if (preset == PhotoFramePreset.IMMERSIVE) assertSame(original, layout)
                    if (preset == PhotoFramePreset.PLAQUE) {
                        assertEquals(original.canvasWidth, layout.canvasWidth)
                        assertEquals(0f, layout.photoTop, 0f)
                    }
                    val preview = layout.fitPreview(1200)
                    assertTrue(maxOf(preview.canvasWidth, preview.canvasHeight) <= 1200)
                    assertEquals(w.toFloat() / h, (preview.photoRight - preview.photoLeft) / (preview.photoBottom - preview.photoTop), 0.0001f)
                }
            }
        }
    }

    @Test fun widthSurvivesPerPresetPersistenceAndChangesOutputIdentity() {
        for (preset in PhotoFramePreset.entries) {
            val baseline = defaultPhotoFrameMetadataSettings(preset)
            for (percent in listOf(110, 150, 200)) {
                val settings = baseline.copy(widthPercent = percent, showCity = true, brandStyle = PhotoFrameBrandStyle.LOGO)
                assertEquals(settings, decodePhotoFrameMetadataSettings(encodePhotoFrameMetadataSettings(mapOf(preset to settings)))[preset])
                if (preset != PhotoFramePreset.IMMERSIVE) {
                    assertNotEquals(photoFrameMetadataSettingsFingerprintToken(preset, baseline),
                        photoFrameMetadataSettingsFingerprintToken(preset, baseline.copy(widthPercent = percent)))
                } else {
                    assertEquals(photoFrameMetadataSettingsFingerprintToken(preset, baseline),
                        photoFrameMetadataSettingsFingerprintToken(preset, baseline.copy(widthPercent = percent)))
                }
            }
        }
        assertEquals(100, normalizePhotoFrameWidthPercent(Int.MIN_VALUE))
        assertEquals(200, normalizePhotoFrameWidthPercent(Int.MAX_VALUE))
        assertEquals(150, normalizePhotoFrameWidthPercent(147))
    }
}
