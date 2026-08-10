package com.ztransfer.ui.screen

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.luminance
import com.ztransfer.ui.theme.SkinPreset
import com.ztransfer.ui.theme.skinAppColors
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SignalBarPaletteTest {

    @Test
    fun nonWoodThemesKeepTheirSemanticColors() {
        val lit = Color(0xFF123456)
        val unlit = Color(0x40123456)
        val palette = signalBarPalette(
            skin = SkinPreset.TITANIUM,
            dark = false,
            level = 3,
            defaultLit = lit,
            defaultUnlit = unlit,
        )

        assertEquals(lit, palette.lit)
        assertEquals(unlit, palette.unlit)
    }

    @Test
    fun woodSignalLevelsRemainReadableInBothColorModes() {
        listOf(false, true).forEach { dark ->
            val colors = skinAppColors(SkinPreset.WOOD, dark)
            val surface = colors.buttonSurface.compositeOver(colors.background)
            listOf(1, 2, 4).forEach { level ->
                val palette = signalBarPalette(
                    skin = SkinPreset.WOOD,
                    dark = dark,
                    level = level,
                    defaultLit = colors.accentOrange,
                    defaultUnlit = colors.onSurfaceVariant.copy(alpha = 0.28f),
                )
                val litContrast = contrastRatio(palette.lit, surface)
                val unlitContrast = contrastRatio(palette.unlit.compositeOver(surface), surface)

                assertTrue("dark=$dark level=$level lit=$litContrast", litContrast >= 3f)
                assertTrue("dark=$dark level=$level unlit=$unlitContrast", unlitContrast >= 1.35f)
            }
        }
    }

    private fun contrastRatio(first: Color, second: Color): Float {
        val lighter = maxOf(first.luminance(), second.luminance())
        val darker = minOf(first.luminance(), second.luminance())
        return (lighter + 0.05f) / (darker + 0.05f)
    }
}
