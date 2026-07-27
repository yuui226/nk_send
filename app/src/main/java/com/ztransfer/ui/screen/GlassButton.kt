package com.ztransfer.ui.screen

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.currentCompositeKeyHash
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.LocalButtonTexturePalette
import com.ztransfer.ui.theme.Motion

/**
 * 全局毛玻璃容器。按钮、卡片等浮层只负责传入形状和状态色，玻璃底、高光、描边与投影
 * 始终由这里统一绘制，避免各页面复制一套近似实现。
 */
@Composable
fun GlassSurface(
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(20.dp),
    panel: Boolean = false,
    active: Boolean = false,
    activeColor: Color? = null,
    showSheen: Boolean = true,
    tint: Color = Color.Transparent,
    borderColor: Color? = null,
    content: @Composable BoxScope.() -> Unit
) {
    val colors = AppTheme.colors
    val resolvedActiveColor = activeColor ?: colors.accentBlue
    val activeProgress by animateFloatAsState(
        targetValue = if (active && !panel) 1f else 0f,
        animationSpec = tween(180),
        label = "glassActive"
    )
    val normalHighlightTop = if (!showSheen) Color.Transparent
        else if (panel) colors.glassSheen else colors.glassHighlightTop
    val normalHighlightBottom = if (!showSheen || panel) Color.Transparent
        else colors.glassHighlightBottom
    val highlightTop = lerp(normalHighlightTop, resolvedActiveColor.copy(alpha = 0.30f), activeProgress)
    val highlightBottom = lerp(normalHighlightBottom, resolvedActiveColor.copy(alpha = 0.12f), activeProgress)
    val decoration = modifier
        .graphicsLayer {
            this.shape = shape
            clip = true
        }
        .background(if (panel) colors.onBackground.copy(alpha = 0.05f) else colors.glassSurface)
        .background(Brush.verticalGradient(listOf(highlightTop, highlightBottom)))
        .background(tint)
        .then(
            // 描边只保留两类"定义面板边缘"的用法：panel 的细 hairline 与调用方显式
            // 指定语义色的 borderColor（如已连接徽标的绿圈）。普通玻璃表面不再画
            // 渐变描边——按钮/浮层的外圈亮框正是它画出来的。
            if (borderColor != null || panel) {
                Modifier.border(
                    width = 1.dp,
                    brush = borderColor?.let(::SolidColor) ?: SolidColor(colors.glassPanelBorder),
                    shape = shape
                )
            } else {
                Modifier
            }
        )
    Box(modifier = decoration, content = content)
}

/**
 * 统一的"毛玻璃"悬浮按钮：半透明底 + 自上而下白色高光渐变，不画外沿描边——
 * 玻璃感全部来自底色与高光，按钮任何状态（含激活态）都不出现描边亮框。
 * 与 "Z传" 悬浮按钮同款视觉。全局悬浮控件（返回/标题/清空/重试等）复用，保证设计语言一致。
 *
 * 按压微缩放：按下快速下沉到 0.95、松开弹性回弹——全 App 玻璃按钮统一的"手感"，
 * 一处定义处处生效。
 *
 * [panel]：面板内变体。默认样式的投影是为悬浮在照片/内容之上设计的，
 * 放进平整的玻璃弹窗（如高级版/换机弹窗）里显得突兀；panel 为真时改用
 * 面板内卡片的同一玻璃语言——淡底、顶部微高光、无投影，
 * 浅色/深色主题各自取 onBackground 同族色，两套主题都贴着面板长。
 *
 * [active]：持续选中态。保留毛玻璃基底和按压手感，叠加强调色淡光与稍高投影，
 * 供筛选等“离开页面后仍持续生效”的状态使用；不画强调色轮廓圈。
 * [activeColor] 可让有明确语义色的按钮复用同一套激活动画，不另造组件。
 *
 * [showSheen]：控制未激活时的白色顶部高光。紧凑按钮可关闭它，避免高光在
 * 小面积圆角表面上看起来像一圈白框；激活色淡光仍会正常显示。
 */
@Composable
fun GlassButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    shape: Shape = RoundedCornerShape(20.dp),
    contentPadding: PaddingValues = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
    panel: Boolean = false,
    active: Boolean = false,
    activeColor: Color? = null,
    showSheen: Boolean = true,
    shadowElevation: Dp? = null,
    textureSeed: Int? = null,
    content: @Composable RowScope.() -> Unit
) {
    val colors = AppTheme.colors
    val resolvedActiveColor = activeColor ?: colors.accentBlue
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    // 按下用短 tween 快速跟手，松开用全局弹簧回弹（与顶栏胶囊等共用手感参数）。
    val pressScale by animateFloatAsState(
        targetValue = if (pressed && enabled) 0.95f else 1f,
        animationSpec = if (pressed) tween(80) else Motion.bouncy(),
        label = "glassPress"
    )
    // 保持原有 Surface → Row 测量层级；照片列表、续费等既有按钮依赖这套布局。
    val activeProgress by animateFloatAsState(
        targetValue = if (active && !panel) 1f else 0f,
        animationSpec = tween(180),
        label = "glassActive"
    )
    // 按钮读 button* token（皮肤只覆写这组）；面板/GlassSurface 读 glass* token，
    // 因此换皮肤只有按钮换材质，弹窗和卡片保持默认毛玻璃。
    val normalHighlightTop = if (!showSheen) Color.Transparent
        else if (panel) colors.buttonSheen else colors.buttonHighlightTop
    val normalHighlightBottom = if (!showSheen || panel) Color.Transparent
        else colors.buttonHighlightBottom
    val highlightTop = lerp(normalHighlightTop, resolvedActiveColor.copy(alpha = 0.30f), activeProgress)
    val highlightBottom = lerp(normalHighlightBottom, resolvedActiveColor.copy(alpha = 0.12f), activeProgress)
    val elevation = shadowElevation ?: if (panel) 0.dp else (4f + 3f * activeProgress).dp
    // 皮肤纹理（皮革/木纹为可平铺画刷，毛玻璃为 null）：叠在底色之上、高光之下。
    // 强度已烘焙进 tile 像素（见 SkinTexture.kt），这里按原样平铺即可。
    val texturePalette = LocalButtonTexturePalette.current
    val compositionTextureSeed = currentCompositeKeyHash
    val skinTexture = remember(texturePalette, textureSeed, compositionTextureSeed) {
        texturePalette?.brushFor(textureSeed ?: compositionTextureSeed)
    }
    Surface(
        onClick = onClick,
        enabled = enabled,
        shape = shape,
        color = if (panel) colors.onBackground.copy(alpha = 0.05f) else colors.buttonSurface,
        border = null,
        shadowElevation = elevation,
        interactionSource = interactionSource,
        modifier = modifier.graphicsLayer {
            scaleX = pressScale
            scaleY = pressScale
            // 禁用态整体压淡：M3 Surface 的 enabled 只拦点击不改视觉，
            // 不加这行会出现"看起来可点、点了没反应"的假活按钮。
            alpha = if (enabled) 1f else 0.45f
        }
    ) {
        Row(
            modifier = Modifier
                // 纹理层夹在 Surface 底色与高光渐变之间，随 Surface 的 shape 一起被裁剪；
                // 低透明度平铺，不影响其上文字/图标的可读性。
                .then(if (skinTexture != null) Modifier.background(skinTexture) else Modifier)
                .background(
                    brush = Brush.verticalGradient(listOf(highlightTop, highlightBottom))
                )
                .padding(contentPadding),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            content = content
        )
    }
}
