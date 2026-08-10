package com.ztransfer.ui.screen

import com.ztransfer.ui.theme.ButtonSkinDisplayOrder
import com.ztransfer.ui.theme.SkinPreset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ThumbnailThemeBorderTest {

    @Test
    fun buttonThemesUseTheRequestedDisplayOrder() {
        assertEquals(
            listOf(
                SkinPreset.FROSTED_GLASS,
                SkinPreset.WOOD,
                SkinPreset.CAMERA_CONTROLS,
                SkinPreset.TITANIUM,
            ),
            ButtonSkinDisplayOrder,
        )
        assertEquals(SkinPreset.entries.size, ButtonSkinDisplayOrder.distinct().size)
        assertEquals(SkinPreset.entries.toSet(), ButtonSkinDisplayOrder.toSet())
    }

    @Test
    fun thumbnailBordersRemainVisibleButRestrained() {
        SkinPreset.entries.forEach { skin ->
            listOf(false, true).forEach { dark ->
                val base = thumbnailThemeBorderColor(skin, dark)
                val stacked = stackedThumbnailThemeBorderColor(skin, dark)

                assertTrue("$skin dark=$dark base=${base.alpha}", base.alpha in 0.08f..0.21f)
                assertTrue(
                    "$skin dark=$dark stacked=${stacked.alpha}",
                    stacked.alpha > base.alpha && stacked.alpha <= 0.36f,
                )
            }
        }
    }

    @Test
    fun materialThemesDoNotCollapseToOneGenericBorder() {
        val lightColors = SkinPreset.entries.map { thumbnailThemeBorderColor(it, dark = false) }
        val darkColors = SkinPreset.entries.map { thumbnailThemeBorderColor(it, dark = true) }

        assertEquals(lightColors.size, lightColors.distinct().size)
        assertEquals(darkColors.size, darkColors.distinct().size)
        assertNotEquals(lightColors, darkColors)
    }
}
