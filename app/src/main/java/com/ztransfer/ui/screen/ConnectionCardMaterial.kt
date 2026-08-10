package com.ztransfer.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
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

/**
 * 连接卡片只借用当前按钮材质的边缘光和极淡偏色，不在大面积正文区铺纹理。
 * 这样能和实体按钮形成家族感，又不会降低连接步骤的对比度。
 */
@Composable
internal fun BoxScope.ConnectionCardMaterialFrame(shape: RoundedCornerShape) {
    val colors = AppTheme.colors
    val skin = LocalButtonTexturePalette.current?.skin ?: SkinPreset.FROSTED_GLASS
    if (skin == SkinPreset.FROSTED_GLASS) return

    val dark = colors.background.luminance() < 0.5f
    val palette = remember(skin, dark) {
        when (skin) {
            SkinPreset.FROSTED_GLASS -> null
            SkinPreset.TITANIUM -> if (dark) {
                ConnectionCardFramePalette(
                    washTop = Color.White.copy(alpha = 0.026f),
                    washBottom = Color.Black.copy(alpha = 0.032f),
                    edgeTop = Color(0xFFDDE5E9).copy(alpha = 0.17f),
                    edgeBottom = Color.Black.copy(alpha = 0.30f),
                )
            } else {
                ConnectionCardFramePalette(
                    washTop = Color.White.copy(alpha = 0.10f),
                    washBottom = Color(0xFF65727A).copy(alpha = 0.022f),
                    edgeTop = Color(0xFFBBC6CC).copy(alpha = 0.28f),
                    edgeBottom = Color(0xFF56636B).copy(alpha = 0.15f),
                )
            }

            SkinPreset.WOOD -> if (dark) {
                ConnectionCardFramePalette(
                    washTop = Color(0xFFF0C37D).copy(alpha = 0.026f),
                    washBottom = Color(0xFF2A1308).copy(alpha = 0.050f),
                    edgeTop = Color(0xFFE2B66F).copy(alpha = 0.17f),
                    edgeBottom = Color(0xFF1B0D06).copy(alpha = 0.38f),
                )
            } else {
                ConnectionCardFramePalette(
                    washTop = Color(0xFFF4CC8F).copy(alpha = 0.030f),
                    washBottom = Color(0xFF7A431F).copy(alpha = 0.026f),
                    edgeTop = Color(0xFFD5A35E).copy(alpha = 0.24f),
                    edgeBottom = Color(0xFF6C391B).copy(alpha = 0.15f),
                )
            }

            SkinPreset.CAMERA_CONTROLS -> if (dark) {
                ConnectionCardFramePalette(
                    washTop = Color(0xFFBFC6CA).copy(alpha = 0.018f),
                    washBottom = Color.Black.copy(alpha = 0.052f),
                    edgeTop = Color(0xFFCBD1D4).copy(alpha = 0.12f),
                    edgeBottom = Color.Black.copy(alpha = 0.48f),
                )
            } else {
                ConnectionCardFramePalette(
                    washTop = Color(0xFF879095).copy(alpha = 0.010f),
                    washBottom = Color.Black.copy(alpha = 0.030f),
                    edgeTop = Color(0xFF717A7F).copy(alpha = 0.16f),
                    edgeBottom = Color.Black.copy(alpha = 0.22f),
                )
            }
        }
    } ?: return
    val wash = remember(palette) {
        Brush.verticalGradient(listOf(palette.washTop, palette.washBottom))
    }
    val edge = remember(palette) {
        Brush.verticalGradient(listOf(palette.edgeTop, palette.edgeBottom))
    }

    Box(
        modifier = Modifier
            .matchParentSize()
            .clip(shape)
            .background(wash)
            .border(width = 1.dp, brush = edge, shape = shape),
    )
}
