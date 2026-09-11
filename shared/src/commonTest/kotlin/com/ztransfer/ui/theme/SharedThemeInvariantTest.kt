package com.ztransfer.ui.theme

import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import kotlin.test.*

class SharedThemeInvariantTest {
    @Test fun persistedSkinNamesAndDisplayOrderDoNotChange() {
        assertEquals(listOf("FROSTED_GLASS", "TITANIUM", "WOOD", "CAMERA_CONTROLS"), SkinPreset.entries.map { it.name })
        assertEquals(listOf(SkinPreset.FROSTED_GLASS, SkinPreset.WOOD, SkinPreset.CAMERA_CONTROLS, SkinPreset.TITANIUM), ButtonSkinDisplayOrder)
    }

    @Test fun skinsOnlyOverrideTheExistingFourButtonTokens() {
        for (dark in listOf(true, false)) {
            val base = if (dark) DarkAppColors else LightAppColors
            for (skin in SkinPreset.entries) {
                val actual = skinAppColors(skin, dark)
                assertEquals(base, actual.copy(buttonSurface = base.buttonSurface,
                    buttonHighlightTop = base.buttonHighlightTop, buttonHighlightBottom = base.buttonHighlightBottom,
                    buttonSheen = base.buttonSheen))
            }
        }
    }

    @Test fun typographyAndQueueMotionRetainAndroidDefaults() {
        assertEquals(28.sp, Typography.headlineLarge.fontSize)
        assertEquals(36.sp, Typography.headlineLarge.lineHeight)
        assertEquals(FontWeight.Bold, Typography.headlineLarge.fontWeight)
        assertEquals(14.sp, Typography.bodyMedium.fontSize)
        assertEquals(320, Motion.QUEUE_PAGE_SLIDE_MS)
        assertEquals(420, Motion.NAV_ENTER_MS)
        assertEquals(280, Motion.NAV_EXIT_MS)
    }
}
