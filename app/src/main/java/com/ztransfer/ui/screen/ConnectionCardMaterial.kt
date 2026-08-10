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

private data class ConnectionCardFramePalette(
    val washTop: Color,
    val washBottom: Color,
    val edgeTop: Color,
    val edgeBottom: Color,
)

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

    Box(
        modifier = modifier
            .graphicsLayer {
                this.shape = shape
                clip = true
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
        when (skin) {
            SkinPreset.FROSTED_GLASS -> ConnectionCardFramePalette(
                washTop = Color.Transparent,
                washBottom = Color.Transparent,
                edgeTop = if (dark) {
                    colors.glassBorderTop.copy(alpha = 0.36f)
                } else {
                    Color.White.copy(alpha = 0.72f)
                },
                edgeBottom = if (dark) {
                    colors.glassBorderBottom.copy(alpha = 0.12f)
                } else {
                    Color.Black.copy(alpha = 0.12f)
                },
            )

            SkinPreset.TITANIUM -> if (dark) {
                ConnectionCardFramePalette(
                    washTop = Color.White.copy(alpha = 0.026f),
                    washBottom = Color.Black.copy(alpha = 0.032f),
                    edgeTop = Color(0xFFDDE5E9).copy(alpha = 0.24f),
                    edgeBottom = Color.Black.copy(alpha = 0.36f),
                )
            } else {
                ConnectionCardFramePalette(
                    washTop = Color.White.copy(alpha = 0.10f),
                    washBottom = Color(0xFF65727A).copy(alpha = 0.022f),
                    edgeTop = Color(0xFFBBC6CC).copy(alpha = 0.36f),
                    edgeBottom = Color(0xFF56636B).copy(alpha = 0.22f),
                )
            }

            SkinPreset.WOOD -> if (dark) {
                ConnectionCardFramePalette(
                    washTop = Color(0xFFF0C37D).copy(alpha = 0.026f),
                    washBottom = Color(0xFF2A1308).copy(alpha = 0.050f),
                    edgeTop = Color(0xFFE2B66F).copy(alpha = 0.24f),
                    edgeBottom = Color(0xFF1B0D06).copy(alpha = 0.44f),
                )
            } else {
                ConnectionCardFramePalette(
                    washTop = Color(0xFFF4CC8F).copy(alpha = 0.030f),
                    washBottom = Color(0xFF7A431F).copy(alpha = 0.026f),
                    edgeTop = Color(0xFFD5A35E).copy(alpha = 0.30f),
                    edgeBottom = Color(0xFF6C391B).copy(alpha = 0.22f),
                )
            }

            SkinPreset.CAMERA_CONTROLS -> if (dark) {
                ConnectionCardFramePalette(
                    washTop = Color(0xFFBFC6CA).copy(alpha = 0.018f),
                    washBottom = Color.Black.copy(alpha = 0.052f),
                    edgeTop = Color(0xFFCBD1D4).copy(alpha = 0.18f),
                    edgeBottom = Color.Black.copy(alpha = 0.52f),
                )
            } else {
                ConnectionCardFramePalette(
                    washTop = Color(0xFF879095).copy(alpha = 0.010f),
                    washBottom = Color.Black.copy(alpha = 0.030f),
                    edgeTop = Color(0xFF717A7F).copy(alpha = 0.22f),
                    edgeBottom = Color.Black.copy(alpha = 0.30f),
                )
            }
        }
    }
    // 绘制 Modifier 单独 remember，确保父卡片呼吸缩放持续刷新图层时，路径、
    // 渐变和线宽仍只在尺寸/主题变化时重建，而不是每个动画帧重建。
    val drawingModifier = remember(shape, palette) {
        Modifier.drawWithCache {
            val outlinePath = shape.createOutline(size, layoutDirection, this)
                .toConnectionCardPath()
            val wash = Brush.verticalGradient(
                listOf(palette.washTop, palette.washBottom),
            )
            val edge = Brush.verticalGradient(
                listOf(palette.edgeTop, palette.edgeBottom),
            )
            val hasWash = palette.washTop.alpha > 0.001f || palette.washBottom.alpha > 0.001f
            // 父容器已按同一 shape 裁切，这里以 2.4dp 居中画在边界上，
            // 外半圈被裁掉，最终只留下约 1.2dp 的清晰内描边。
            val edgeWidth = 2.4.dp.toPx()
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
