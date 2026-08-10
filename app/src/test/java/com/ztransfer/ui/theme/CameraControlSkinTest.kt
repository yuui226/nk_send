package com.ztransfer.ui.theme

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraControlSkinTest {

    @Test
    fun cameraControlSkinOnlyOverridesButtonMaterialTokens() {
        assertOnlyButtonTokensChanged(DarkAppColors, skinAppColors(SkinPreset.CAMERA_CONTROLS, dark = true))
        assertOnlyButtonTokensChanged(LightAppColors, skinAppColors(SkinPreset.CAMERA_CONTROLS, dark = false))
    }

    @Test
    fun cameraControlCapsStayOpaqueAndDarkInBothColorModes() {
        listOf(DarkCameraControlColors, LightCameraControlColors).forEach { colors ->
            assertTrue(colors.buttonSurface.alpha >= 0.99f)
            assertTrue(colors.buttonSurface.red < 0.15f)
            assertTrue(colors.buttonSurface.green < 0.15f)
            assertTrue(colors.buttonSurface.blue < 0.15f)
        }
    }

    private fun assertOnlyButtonTokensChanged(base: AppColors, actual: AppColors) {
        assertEquals(
            base,
            actual.copy(
                buttonSurface = base.buttonSurface,
                buttonHighlightTop = base.buttonHighlightTop,
                buttonHighlightBottom = base.buttonHighlightBottom,
                buttonSheen = base.buttonSheen,
            ),
        )
    }
}
