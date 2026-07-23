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
import com.ztransfer.ui.theme.AppTheme
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
    showBorder: Boolean = true,
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
    val normalBorderTop = if (panel) colors.glassPanelBorder else colors.glassBorderTop
    val normalBorderBottom = if (panel) colors.glassPanelBorder else colors.glassBorderBottom
    val highlightTop = lerp(normalHighlightTop, resolvedActiveColor.copy(alpha = 0.30f), activeProgress)
    val highlightBottom = lerp(normalHighlightBottom, resolvedActiveColor.copy(alpha = 0.12f), activeProgress)
    val borderTop = lerp(normalBorderTop, resolvedActiveColor.copy(alpha = 0.95f), activeProgress)
    val borderBottom = lerp(normalBorderBottom, resolvedActiveColor.copy(alpha = 0.52f), activeProgress)
    val decoration = modifier
        .graphicsLayer {
            this.shape = shape
            clip = true
        }
        .background(if (panel) colors.onBackground.copy(alpha = 0.05f) else colors.glassSurface)
        .background(Brush.verticalGradient(listOf(highlightTop, highlightBottom)))
        .background(tint)
        .then(
            if (showBorder) {
                Modifier.border(
                    width = 1.dp,
                    brush = borderColor?.let(::SolidColor)
                        ?: if (panel) SolidColor(borderTop)
                        else Brush.verticalGradient(listOf(borderTop, borderBottom)),
                    shape = shape
                )
            } else {
                Modifier
            }
        )
    Box(modifier = decoration, content = content)
}

/**
 * 统一的"毛玻璃"悬浮按钮：半透明底 + 自上而下白色高光渐变 + 上亮下暗细描边，
 * 与 "Z传" 悬浮按钮同款视觉。全局悬浮控件（返回/标题/清空/重试等）复用，保证设计语言一致。
 *
 * 按压微缩放：按下快速下沉到 0.95、松开弹性回弹——全 App 玻璃按钮统一的"手感"，
 * 一处定义处处生效。
 *
 * [panel]：面板内变体。默认样式的白描边 + 投影是为悬浮在照片/内容之上设计的，
 * 放进平整的玻璃弹窗（如高级版/换机弹窗）里会像多画了一个框；panel 为真时改用
 * 面板内卡片的同一玻璃语言——淡底、细 panelBorder 描边、顶部微高光、无投影，
 * 浅色/深色主题各自取 onBackground 同族色，两套主题都贴着面板长。
 *
 * [active]：持续选中态。保留毛玻璃基底和按压手感，叠加强调色淡光、
 * 强调色轮廓与稍高投影，供筛选等“离开页面后仍持续生效”的状态使用。
 * [activeColor] 可让有明确语义色的按钮复用同一套激活动画，不另造组件。
 *
 * [showBorder]：仅控制外沿描边，玻璃底、高光、激活态和按压反馈不受影响。
 * 小尺寸工具按钮可关闭描边，避免 1dp 亮边挤压图标的视觉空间。
 * [showSheen]：控制未激活时的白色顶部高光。紧凑按钮可关闭它，避免高光在
 * 小面积圆角表面上看起来像第二圈白框；激活色淡光仍会正常显示。
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
    showBorder: Boolean = true,
    showSheen: Boolean = true,
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
    val normalHighlightTop = if (!showSheen) Color.Transparent
        else if (panel) colors.glassSheen else colors.glassHighlightTop
    val normalHighlightBottom = if (!showSheen || panel) Color.Transparent
        else colors.glassHighlightBottom
    val normalBorderTop = if (panel) colors.glassPanelBorder else colors.glassBorderTop
    val normalBorderBottom = if (panel) colors.glassPanelBorder else colors.glassBorderBottom
    val highlightTop = lerp(normalHighlightTop, resolvedActiveColor.copy(alpha = 0.30f), activeProgress)
    val highlightBottom = lerp(normalHighlightBottom, resolvedActiveColor.copy(alpha = 0.12f), activeProgress)
    val borderTop = lerp(normalBorderTop, resolvedActiveColor.copy(alpha = 0.95f), activeProgress)
    val borderBottom = lerp(normalBorderBottom, resolvedActiveColor.copy(alpha = 0.52f), activeProgress)
    val elevation = if (panel) 0.dp else (4f + 3f * activeProgress).dp
    Surface(
        onClick = onClick,
        enabled = enabled,
        shape = shape,
        color = if (panel) colors.onBackground.copy(alpha = 0.05f) else colors.glassSurface,
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
                .background(
                    brush = Brush.verticalGradient(listOf(highlightTop, highlightBottom))
                )
                .then(
                    if (showBorder) {
                        Modifier.border(
                            width = 1.dp,
                            brush = if (panel) SolidColor(borderTop)
                            else Brush.verticalGradient(listOf(borderTop, borderBottom)),
                            shape = shape
                        )
                    } else {
                        Modifier
                    }
                )
                .padding(contentPadding),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            content = content
        )
    }
}
