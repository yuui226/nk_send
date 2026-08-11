package com.ztransfer.ui.screen

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.luminance
import com.ztransfer.ui.theme.SkinPreset
import com.ztransfer.ui.theme.skinAppColors
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoEffectFavoriteButtonPaletteTest {
    @Test
    fun frostedGlassUsesTheCurrentThemeColors() {
        val inactive = Color(0xFF123456)
        val active = Color(0xFFABCDEF)

        val palette = photoEffectFavoriteButtonPalette(
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
    fun everySolidThemeKeepsTheStarReadableInBothColorModes() {
        val solidSkins = listOf(
            SkinPreset.TITANIUM,
            SkinPreset.WOOD,
            SkinPreset.CAMERA_CONTROLS,
        )

        solidSkins.forEach { skin ->
            listOf(false, true).forEach { dark ->
                val colors = skinAppColors(skin, dark)
                val palette = photoEffectFavoriteButtonPalette(
                    skin = skin,
                    dark = dark,
                    defaultInactiveIcon = colors.onSurfaceVariant,
                    defaultActive = colors.accentOrange,
                )
                val baseSurface = colors.buttonSurface.compositeOver(colors.background)
                val activeSurface = palette.activeMaterial.copy(alpha = 0.30f)
                    .compositeOver(baseSurface)

                assertTrue(
                    "$skin dark=$dark inactive",
                    contrastRatio(palette.inactiveIcon, baseSurface) >= 3f,
                )
                assertTrue(
                    "$skin dark=$dark active",
                    contrastRatio(palette.activeIcon, activeSurface) >= 3f,
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
