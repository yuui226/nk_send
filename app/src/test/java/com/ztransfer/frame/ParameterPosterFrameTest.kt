package com.ztransfer.frame

import org.junit.Assert.*
import org.junit.Test

class ParameterPosterFrameTest {
    @Test fun portraitUsesSidePanelAndLandscapeUsesBottomBandWithoutCropping() {
        for ((w, h) in listOf(4000 to 6000, 6000 to 4000, 4000 to 4000, 8000 to 2000, 2000 to 8000)) {
            val original = calculateOriginalQualityEditorialFrameLayout(w, h, PhotoFramePreset.PARAMETER_POSTER)
            assertEquals(w.toFloat(), original.photoRight - original.photoLeft, 0.001f)
            assertEquals(h.toFloat(), original.photoBottom - original.photoTop, 0.001f)
            assertTrue(original.canvasWidth > original.photoRight)
            assertTrue(original.canvasHeight > original.photoBottom)
            if (h > w) assertTrue(original.photoLeft > w)
            else assertTrue(original.canvasHeight - original.photoBottom > w * 0.4f)
            val preview = calculateEditorialFrameLayout(w, h, PhotoFramePreset.PARAMETER_POSTER, 1200)
            val scale = 1200f / maxOf(original.canvasWidth, original.canvasHeight)
            assertEquals(original.photoLeft * scale, preview.photoLeft, 0.001f)
            assertEquals(original.photoBottom * scale, preview.photoBottom, 0.001f)
        }
    }

    @Test fun defaultsKeepReferenceHierarchyAndAllowAllMetadataSwitches() {
        val settings = defaultPhotoFrameMetadataSettings(PhotoFramePreset.PARAMETER_POSTER)
        assertTrue(settings.showBrand && settings.showModel && settings.showExposure && settings.showFocalLength)
        assertFalse(settings.showLensModel || settings.showCity || settings.showRegion || settings.showCoordinates)
        val custom = settings.copy(showCity = true, showRegion = true, showCoordinates = true, showAltitude = true, showLensModel = true)
        val encoded = encodePhotoFrameMetadataSettings(mapOf(PhotoFramePreset.PARAMETER_POSTER to custom))
        assertEquals(custom, decodePhotoFrameMetadataSettings(encoded)[PhotoFramePreset.PARAMETER_POSTER])
    }
}
