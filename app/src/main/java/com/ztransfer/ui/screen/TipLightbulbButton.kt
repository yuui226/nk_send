package com.ztransfer.ui.screen

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.LocalButtonTexturePalette
import com.ztransfer.ui.theme.SkinPreset

private const val TIP_LIGHTBULB_TEXTURE_SEED = 0x1457A101

/** 小技巧提示统一入口；调用方只决定尺寸，材质、主题对比度和图标比例保持一致。 */
@Composable
internal fun TipLightbulbButton(
    onClick: () -> Unit,
    contentDescription: String,
    modifier: Modifier = Modifier,
    attention: Boolean = false,
) {
    val colors = AppTheme.colors
    val skin = LocalButtonTexturePalette.current?.skin ?: SkinPreset.FROSTED_GLASS
    val dark = colors.background.luminance() < 0.5f
    val iconColor = remember(skin, dark, colors.accentOrange) {
        tipLightbulbIconColor(
            skin = skin,
            dark = dark,
            defaultColor = colors.accentOrange,
        )
    }
    val attentionScale = if (attention) {
        val transition = rememberInfiniteTransition(label = "tipLightbulbAttention")
        val scale by transition.animateFloat(
            initialValue = 1f,
            targetValue = 1.055f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 1_100, easing = FastOutSlowInEasing),
                repeatMode = RepeatMode.Reverse,
            ),
            label = "tipLightbulbScale",
        )
        scale
    } else {
        1f
    }
    GlassButton(
        onClick = onClick,
        shape = RoundedCornerShape(12.dp),
        contentPadding = PaddingValues(0.dp),
        textureSeed = TIP_LIGHTBULB_TEXTURE_SEED,
        materialContentColor = iconColor,
        modifier = modifier.graphicsLayer {
            scaleX = attentionScale
            scaleY = attentionScale
        },
    ) {
        Box(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Default.Lightbulb,
                contentDescription = contentDescription,
                tint = iconColor,
                modifier = Modifier.fillMaxSize(0.45f),
            )
        }
    }
}

/** 实体按钮上的灯泡改用材质印记色，避免暖黄色落在木纹上失去轮廓。 */
internal fun tipLightbulbIconColor(
    skin: SkinPreset,
    dark: Boolean,
    defaultColor: Color,
): Color = when (skin) {
    SkinPreset.FROSTED_GLASS -> defaultColor
    SkinPreset.TITANIUM -> if (dark) Color(0xFFE4ECEF) else Color(0xFF344149)
    SkinPreset.WOOD -> if (dark) Color(0xFFF1D6A7) else Color(0xFF472A18)
    SkinPreset.CAMERA_CONTROLS -> Color(0xFFD5D8DA)
}
