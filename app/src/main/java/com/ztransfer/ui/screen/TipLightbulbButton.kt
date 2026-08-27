package com.ztransfer.ui.screen

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.text.font.FontWeight
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
            targetValue = 1.09f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 900, easing = FastOutSlowInEasing),
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
            if (attention) {
                // 一次性未读引导：红点补足单靠缩放不易察觉的问题；点击后由持久化状态移除。
                Box(
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(top = 2.dp, end = 2.dp)
                        .size(7.dp)
                        .background(Color(0xFFFF4D3D), CircleShape)
                        .border(1.dp, colors.background.copy(alpha = 0.9f), CircleShape),
                )
            }
        }
    }
}

/** 实体按钮上的灯泡改用材质印记色，避免暖黄色落在木纹上失去轮廓。 */
internal fun tipLightbulbIconColor(
    skin: SkinPreset,
    dark: Boolean,
    defaultColor: Color,
): Color = materialButtonForegroundColor(skin, dark, defaultColor)

/** One consistently styled row inside a lightbulb help bubble. */
internal data class TipBubbleItem(
    val text: String,
    val label: String? = null,
    val emphasized: Boolean = false,
)

/** Shared STA-style content hierarchy for every lightbulb help bubble. */
@Composable
internal fun TipBubbleContent(
    title: String,
    items: List<TipBubbleItem>,
    modifier: Modifier = Modifier,
) {
    val colors = AppTheme.colors
    Column(modifier = modifier.padding(18.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = Icons.Default.Lightbulb,
                contentDescription = null,
                tint = colors.accentOrange,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold,
                color = colors.onBackground,
            )
        }
        items.forEachIndexed { index, item ->
            Spacer(Modifier.height(if (index == 0) 10.dp else 12.dp))
            item.label?.takeIf { it.isNotBlank() }?.let { label ->
                Text(
                    text = label,
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Medium,
                    color = colors.accentBlue,
                )
                Spacer(Modifier.height(5.dp))
            }
            if (item.emphasized) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(colors.onBackground.copy(alpha = 0.05f))
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                ) {
                    Text(
                        text = item.text,
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Medium,
                        color = colors.accentBlue,
                    )
                }
            } else {
                Text(
                    text = item.text,
                    style = MaterialTheme.typography.bodyMedium,
                    color = colors.onSurfaceVariant,
                )
            }
        }
    }
}
