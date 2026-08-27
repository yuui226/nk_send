package com.ztransfer.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.LocalButtonTexturePalette
import com.ztransfer.ui.theme.SkinPreset

internal data class ConnectionCardFramePalette(
    val washTop: Color,
    val washBottom: Color,
    val edgeTop: Color,
    val edgeBottom: Color,
)

internal const val CONNECTION_CARD_RIM_STROKE_DP = 1.8f

private fun Color.withScaledAlpha(scale: Float): Color = copy(alpha = alpha * scale)

internal fun wifiSettingsButtonTextColor(
    skin: SkinPreset,
    dark: Boolean,
    defaultColor: Color,
): Color = if (skin == SkinPreset.WOOD) {
    if (dark) Color(0xFFF1D6A7) else Color(0xFF472A18)
} else {
    defaultColor
}

/** High-contrast foreground shared by content printed on the four button materials. */
internal fun materialButtonForegroundColor(
    skin: SkinPreset,
    dark: Boolean,
    defaultColor: Color,
): Color = when (skin) {
    SkinPreset.FROSTED_GLASS -> defaultColor
    SkinPreset.TITANIUM -> if (dark) Color(0xFFE4ECEF) else Color(0xFF344149)
    SkinPreset.WOOD -> if (dark) Color(0xFFF1D6A7) else Color(0xFF472A18)
    SkinPreset.CAMERA_CONTROLS -> Color(0xFFD5D8DA)
}

internal fun connectionCardFramePalette(
    skin: SkinPreset,
    dark: Boolean,
    glassBorderTop: Color,
    glassBorderBottom: Color,
): ConnectionCardFramePalette = when (skin) {
    SkinPreset.FROSTED_GLASS -> ConnectionCardFramePalette(
        washTop = Color.Transparent,
        washBottom = Color.Transparent,
        edgeTop = if (dark) {
            glassBorderTop.copy(alpha = 0.48f)
        } else {
            Color.White.copy(alpha = 0.78f)
        },
        edgeBottom = if (dark) {
            glassBorderBottom.copy(alpha = 0.18f)
        } else {
            Color.Black.copy(alpha = 0.17f)
        },
    )

    SkinPreset.TITANIUM -> if (dark) {
        ConnectionCardFramePalette(
            washTop = Color.White.copy(alpha = 0.035f),
            washBottom = Color.Black.copy(alpha = 0.040f),
            edgeTop = Color(0xFFDDE5E9).copy(alpha = 0.36f),
            edgeBottom = Color.Black.copy(alpha = 0.48f),
        )
    } else {
        ConnectionCardFramePalette(
            washTop = Color.White.copy(alpha = 0.080f),
            washBottom = Color(0xFF65727A).copy(alpha = 0.028f),
            edgeTop = Color(0xFFADB9BF).copy(alpha = 0.48f),
            edgeBottom = Color(0xFF4D5960).copy(alpha = 0.30f),
        )
    }

    SkinPreset.WOOD -> if (dark) {
        ConnectionCardFramePalette(
            washTop = Color(0xFFF0C37D).copy(alpha = 0.035f),
            washBottom = Color(0xFF2A1308).copy(alpha = 0.055f),
            edgeTop = Color(0xFFE8BE7B).copy(alpha = 0.38f),
            edgeBottom = Color(0xFF160A04).copy(alpha = 0.56f),
        )
    } else {
        ConnectionCardFramePalette(
            washTop = Color(0xFFF4CC8F).copy(alpha = 0.040f),
            washBottom = Color(0xFF7A431F).copy(alpha = 0.030f),
            edgeTop = Color(0xFFC88F43).copy(alpha = 0.42f),
            edgeBottom = Color(0xFF613318).copy(alpha = 0.30f),
        )
    }

    SkinPreset.CAMERA_CONTROLS -> if (dark) {
        ConnectionCardFramePalette(
            washTop = Color(0xFFBFC6CA).copy(alpha = 0.025f),
            washBottom = Color.Black.copy(alpha = 0.060f),
            edgeTop = Color(0xFFD0D5D7).copy(alpha = 0.32f),
            edgeBottom = Color.Black.copy(alpha = 0.62f),
        )
    } else {
        ConnectionCardFramePalette(
            washTop = Color(0xFF879095).copy(alpha = 0.015f),
            washBottom = Color.Black.copy(alpha = 0.035f),
            edgeTop = Color(0xFF626B70).copy(alpha = 0.36f),
            edgeBottom = Color.Black.copy(alpha = 0.40f),
        )
    }
}

private fun Outline.toConnectionCardPath(): Path = when (this) {
    is Outline.Generic -> path
    is Outline.Rectangle -> Path().apply { addRect(rect) }
    is Outline.Rounded -> Path().apply { addRoundRect(roundRect) }
}

/**
 * 实体按钮主题下的卡片承载面。使用不透明、低反射底色，防止照片/页面背景
 * 透过来干扰连接步骤；纹理只留在小图标底座，不进入正文区。
 */
internal fun connectionCardSolidBaseColor(skin: SkinPreset, dark: Boolean): Color? = when (skin) {
    SkinPreset.FROSTED_GLASS -> null
    SkinPreset.TITANIUM -> if (dark) Color(0xFF23282C) else Color(0xFFF2F4F5)
    SkinPreset.WOOD -> if (dark) Color(0xFF261E18) else Color(0xFFFFF9F0)
    SkinPreset.CAMERA_CONTROLS -> if (dark) Color(0xFF191B1D) else Color(0xFFF2F3F3)
}

/**
 * 连接卡片容器：毛玻璃沿用原光学层，三种实体主题改用静态哑光承载面。
 * 实体分支只保留与原 GlassSurface 相同的 shape 裁切图层，不执行玻璃光场绘制。
 */
@Composable
internal fun ConnectionCardSurface(
    modifier: Modifier = Modifier,
    shape: RoundedCornerShape,
    tint: Color,
    content: @Composable BoxScope.() -> Unit,
) {
    val colors = AppTheme.colors
    val skin = LocalButtonTexturePalette.current?.skin ?: SkinPreset.FROSTED_GLASS
    val dark = colors.background.luminance() < 0.5f
    val solidBaseColor = connectionCardSolidBaseColor(skin, dark)

    if (solidBaseColor == null) {
        GlassSurface(
            modifier = modifier,
            shape = shape,
            tint = tint,
            content = content,
        )
        return
    }
    val containerColor = remember(solidBaseColor, tint) {
        tint.compositeOver(solidBaseColor)
    }
    val cardShadowElevation = when (skin) {
        SkinPreset.FROSTED_GLASS -> 0.dp
        SkinPreset.TITANIUM -> 4.5.dp
        SkinPreset.WOOD -> 5.dp
        SkinPreset.CAMERA_CONTROLS -> 5.5.dp
    }

    Box(
        modifier = modifier
            .graphicsLayer {
                this.shape = shape
                clip = true
                shadowElevation = cardShadowElevation.toPx()
            }
            .background(containerColor),
        content = content,
    )
}

/**
 * 连接卡片只借用当前按钮材质的边缘光和极淡偏色，不在大面积正文区铺纹理。
 * 这样能和实体按钮形成家族感，又不会降低连接步骤的对比度。
 */
@Composable
internal fun Modifier.connectionCardMaterialFrame(shape: RoundedCornerShape): Modifier {
    val colors = AppTheme.colors
    val skin = LocalButtonTexturePalette.current?.skin ?: SkinPreset.FROSTED_GLASS
    val dark = colors.background.luminance() < 0.5f
    val palette = remember(skin, dark, colors.glassBorderTop, colors.glassBorderBottom) {
        connectionCardFramePalette(
            skin = skin,
            dark = dark,
            glassBorderTop = colors.glassBorderTop,
            glassBorderBottom = colors.glassBorderBottom,
        )
    }
    // 绘制 Modifier 单独 remember，确保父卡片呼吸缩放持续刷新图层时，路径、
    // 渐变和线宽仍只在尺寸/主题变化时重建，而不是每个动画帧重建。
    val drawingModifier = remember(shape, palette) {
        Modifier.drawWithCache {
            val outlinePath = shape.createOutline(size, layoutDirection, this)
                .toConnectionCardPath()
            val wash = Brush.verticalGradient(
                listOf(
                    palette.washTop,
                    palette.washTop.withScaledAlpha(0.18f),
                    palette.washBottom.withScaledAlpha(0.10f),
                    palette.washBottom,
                ),
            )
            val edge = Brush.verticalGradient(
                listOf(palette.edgeTop, palette.edgeBottom),
            )
            val hasWash = palette.washTop.alpha > 0.001f || palette.washBottom.alpha > 0.001f
            // 只留不到 1dp 的内侧轮廓；立体感由整面连续明暗和外部阴影形成，
            // 避免宽描边在卡片内部产生可见的截止线。
            val edgeWidth = CONNECTION_CARD_RIM_STROKE_DP.dp.toPx()
            onDrawBehind {
                if (hasWash) drawPath(outlinePath, brush = wash)
                drawPath(
                    path = outlinePath,
                    brush = edge,
                    style = Stroke(width = edgeWidth),
                )
            }
        }
    }
    return then(drawingModifier)
}
