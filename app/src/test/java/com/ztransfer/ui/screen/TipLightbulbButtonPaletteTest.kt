package com.ztransfer.ui.screen

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.luminance
import com.ztransfer.ui.theme.SkinPreset
import com.ztransfer.ui.theme.skinAppColors
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TipLightbulbButtonPaletteTest {
    @Test
    fun frostedGlassKeepsTheSemanticBulbColor() {
        val expected = Color(0xFFABCDEF)

        assertEquals(
            expected,
            tipLightbulbIconColor(
                skin = SkinPreset.FROSTED_GLASS,
                dark = false,
                defaultColor = expected,
            ),
        )
    }

    @Test
    fun everySolidThemeKeepsTheBulbReadableInBothColorModes() {
        val solidSkins = listOf(
            SkinPreset.TITANIUM,
            SkinPreset.WOOD,
            SkinPreset.CAMERA_CONTROLS,
        )

        solidSkins.forEach { skin ->
            listOf(false, true).forEach { dark ->
                val colors = skinAppColors(skin, dark)
                val icon = tipLightbulbIconColor(skin, dark, colors.accentOrange)
                val surface = colors.buttonSurface.compositeOver(colors.background)
                val ratio = contrastRatio(icon, surface)

                assertTrue("$skin dark=$dark ratio=$ratio", ratio >= 3f)
            }
        }
    }

    private fun contrastRatio(first: Color, second: Color): Float {
        val lighter = maxOf(first.luminance(), second.luminance())
        val darker = minOf(first.luminance(), second.luminance())
        return (lighter + 0.05f) / (darker + 0.05f)
    }
}
