package com.ztransfer.frame

import org.junit.Assert.*
import org.junit.Test

class PhotoFrameWidthTest {

    @Test fun smallSourcePreviewKeepsTheRequestedTextResolutionWithoutChangingExportGeometry() {
        val original = calculateOriginalQualityFrameLayout(80, 120, PhotoFramePreset.MINIMAL)
        val preview = original.fitPreview(1920, allowUpscale = true)
        assertEquals(1920, maxOf(preview.canvasWidth, preview.canvasHeight))
        assertEquals(80f / 120f, (preview.photoRight - preview.photoLeft) / (preview.photoBottom - preview.photoTop), 0.0001f)
        assertSame(original, original.fitPreview(null, allowUpscale = true))
        assertEquals(80f, original.photoRight - original.photoLeft, 0f)
    }

    @Test fun widthSurvivesPerPresetPersistenceAndChangesOutputIdentity() {
        for (preset in PhotoFramePreset.entries) {
            val baseline = defaultPhotoFrameMetadataSettings(preset)
            for (percent in listOf(60, 70, 80, 90, 110, 150, 200)) {
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
        assertEquals(60, normalizePhotoFrameWidthPercent(Int.MIN_VALUE))
        assertEquals(200, normalizePhotoFrameWidthPercent(Int.MAX_VALUE))
        assertEquals(145, normalizePhotoFrameWidthPercent(147))
        assertEquals(150, normalizePhotoFrameWidthPercent(148))
        for (percent in 60..200 step 5) {
            assertEquals(percent, normalizePhotoFrameWidthPercent(percent))
        }
    }
}
