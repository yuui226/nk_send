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
                val stateTints = listOf(
                    Color.Transparent,
                    colors.statusError.copy(alpha = 0.055f),
                    colors.accentOrange.copy(alpha = 0.045f),
                    colors.accentBlue.copy(alpha = 0.018f),
                )
                stateTints.forEach { tint ->
                    val contrast = contrastRatio(tint.compositeOver(base), colors.onBackground)
                    assertTrue(
                        "$skin dark=$dark tint=$tint text contrast=$contrast",
                        contrast >= MIN_CARD_TEXT_CONTRAST,
                    )
                }
            }
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
