package com.ztransfer.ui.screen

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.luminance
import com.ztransfer.ui.theme.SkinPreset
import com.ztransfer.ui.theme.skinAppColors
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FilterButtonPaletteTest {

    @Test
    fun frostedGlassKeepsTheEstablishedFilterColors() {
        val inactive = Color(0xFF123456)
        val active = Color(0xFFABCDEF)
        val palette = filterButtonPalette(
            skin = SkinPreset.FROSTED_GLASS,
            dark = false,
            defaultInactiveIcon = inactive,
            defaultActive = active,
        )

        assertEquals(inactive, palette.inactiveIcon)
        assertEquals(active, palette.activeIcon)
        assertEquals(active, palette.activeMaterial)
    }

    @Test
    fun solidThemesKeepFilterIconReadableInBothColorModes() {
        val solidSkins = listOf(
            SkinPreset.TITANIUM,
            SkinPreset.WOOD,
            SkinPreset.CAMERA_CONTROLS,
        )
        solidSkins.forEach { skin ->
            listOf(false, true).forEach { dark ->
                val colors = skinAppColors(skin, dark)
                val palette = filterButtonPalette(
                    skin = skin,
                    dark = dark,
                    defaultInactiveIcon = colors.onBackground,
                    defaultActive = colors.accentYellow,
                )
                val baseSurface = colors.buttonSurface.compositeOver(colors.background)
                // GlassButton 顶部激活染色的上限是 0.30；以最强覆盖检查，而不是只测中间值。
                val activeSurface = palette.activeMaterial.copy(alpha = 0.30f)
                    .compositeOver(baseSurface)
                val inactiveContrast = contrastRatio(palette.inactiveIcon, baseSurface)
                val activeContrast = contrastRatio(palette.activeIcon, activeSurface)

                assertTrue(
                    "$skin dark=$dark inactive=$inactiveContrast",
                    inactiveContrast >= 3f,
                )
                assertTrue(
                    "$skin dark=$dark active=$activeContrast",
                    activeContrast >= 3f,
                )
            }
        }
    }

    private fun contrastRatio(first: Color, second: Color): Float {
        val lighter = maxOf(first.luminance(), second.luminance())
        val darker = minOf(first.luminance(), second.luminance())
        return (lighter + 0.05f) / (darker + 0.05f)
    }
}
