package com.ztransfer.ui.screen

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.luminance
import com.ztransfer.ui.theme.SkinPreset
import com.ztransfer.ui.theme.skinAppColors
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionCardMaterialTest {

    @Test
    fun staConnectButtonUsesAControlledPaletteForEveryMaterial() {
        SkinPreset.entries.forEach { skin ->
            listOf(false, true).forEach { dark ->
                val colors = skinAppColors(skin, dark)
                val palette = staConnectButtonPalette(
                    skin = skin,
                    dark = dark,
                    defaultConnecting = colors.accentBlue,
                    defaultConnected = colors.statusConnected,
                )

                assertTrue("$skin dark=$dark distinct states", palette.connecting != palette.connected)
                assertTrue(
                    "$skin dark=$dark success stays green",
                    palette.connected.green > palette.connected.red,
                )
                assertTrue(
                    "$skin dark=$dark fill range",
                    palette.restFillAlpha in 0f..palette.peakFillAlpha &&
                        palette.peakFillAlpha <= 0.12f,
                )
                assertTrue(
                    "$skin dark=$dark edge range",
                    palette.restEdgeAlpha in 0f..palette.peakEdgeAlpha &&
                        palette.peakEdgeAlpha <= 0.42f,
                )
                assertTrue(
                    "$skin dark=$dark stroke range",
                    palette.restEdgeWidthDp in 0.70f..palette.peakEdgeWidthDp &&
                        palette.peakEdgeWidthDp <= 1.20f,
                )

                if (skin == SkinPreset.FROSTED_GLASS) {
                    assertTrue(palette.connecting == colors.accentBlue)
                    assertTrue(palette.connected == colors.statusConnected)
                } else {
                    assertTrue(
                        "$skin gets a material connecting color",
                        palette.connecting != colors.accentBlue,
                    )
                    assertTrue(
                        "$skin gets a material success color",
                        palette.connected != colors.statusConnected,
                    )
                }
            }
        }
    }

    @Test
    fun solidMaterialBadgeIconsKeepNonTextContrastInBothColorModes() {
        val solidSkins = listOf(
            SkinPreset.TITANIUM,
            SkinPreset.WOOD,
            SkinPreset.CAMERA_CONTROLS,
        )

        solidSkins.forEach { skin ->
            listOf(false, true).forEach { dark ->
                val colors = skinAppColors(skin, dark)
                listOf(colors.accentOrange, colors.accentBlue).forEach { accent ->
                    val ink = materialBadgeContentColor(skin, dark, accent)
                    val contrast = contrastRatio(
                        colors.buttonSurface.copy(alpha = 1f),
                        ink.copy(alpha = 1f),
                    )
                    assertTrue(
                        "$skin dark=$dark contrast=$contrast",
                        contrast >= MIN_MATERIAL_BADGE_CONTRAST,
                    )
                }
            }
        }
    }

    @Test
    fun solidConnectionCardSurfacesKeepTextHighlyReadable() {
        val solidSkins = listOf(
            SkinPreset.TITANIUM,
            SkinPreset.WOOD,
            SkinPreset.CAMERA_CONTROLS,
        )

        solidSkins.forEach { skin ->
            listOf(false, true).forEach { dark ->
                val colors = skinAppColors(skin, dark)
                val base = checkNotNull(connectionCardSolidBaseColor(skin, dark))
                val frame = connectionCardFramePalette(
                    skin = skin,
                    dark = dark,
                    glassBorderTop = colors.glassBorderTop,
                    glassBorderBottom = colors.glassBorderBottom,
                )
                val stateTints = listOf(
                    Color.Transparent,
                    colors.statusError.copy(alpha = 0.055f),
                    colors.accentOrange.copy(alpha = 0.045f),
                    colors.accentBlue.copy(alpha = 0.018f),
                )
                stateTints.forEach { tint ->
                    val surface = tint.compositeOver(base)
                    listOf(frame.washTop, frame.washBottom).forEach { wash ->
                        val contrast = contrastRatio(wash.compositeOver(surface), colors.onBackground)
                        assertTrue(
                            "$skin dark=$dark tint=$tint wash=$wash text contrast=$contrast",
                            contrast >= MIN_CARD_TEXT_CONTRAST,
                        )
                    }
                }
            }
        }
    }

    @Test
    fun materialRimStaysThinAndThemeVisible() {
        SkinPreset.entries.forEach { skin ->
            listOf(false, true).forEach { dark ->
                val colors = skinAppColors(skin, dark)
                val frame = connectionCardFramePalette(
                    skin = skin,
                    dark = dark,
                    glassBorderTop = colors.glassBorderTop,
                    glassBorderBottom = colors.glassBorderBottom,
                )

                assertTrue("$skin dark=$dark rim", frame.edgeTop.alpha >= 0.30f)
            }
        }
        assertTrue(CONNECTION_CARD_RIM_STROKE_DP in 1.6f..2.0f)
    }

    @Test
    fun woodWifiSettingsLabelUsesReadableWarmInk() {
        listOf(false, true).forEach { dark ->
            val colors = skinAppColors(SkinPreset.WOOD, dark)
            val ink = wifiSettingsButtonTextColor(
                skin = SkinPreset.WOOD,
                dark = dark,
                defaultColor = colors.accentBlue,
            )
            val buttonSurface = colors.buttonSurface.compositeOver(colors.background)
            val contrast = contrastRatio(ink, buttonSurface)

            assertTrue("wood dark=$dark contrast=$contrast", contrast >= 4.5f)
            assertTrue("wood dark=$dark should not stay blue", ink != colors.accentBlue)
        }
    }

    private fun contrastRatio(first: Color, second: Color): Float {
        val lighter = maxOf(first.luminance(), second.luminance())
        val darker = minOf(first.luminance(), second.luminance())
        return (lighter + 0.05f) / (darker + 0.05f)
    }

    private companion object {
        // 比 3:1 的非文本基线多留余量，避免局部纹理/高光吃掉对比度。
        const val MIN_MATERIAL_BADGE_CONTRAST = 3.4f
        const val MIN_CARD_TEXT_CONTRAST = 7f
    }
}
