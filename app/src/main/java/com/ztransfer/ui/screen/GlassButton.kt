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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.LocalButtonTexturePalette
import com.ztransfer.ui.theme.Motion
import com.ztransfer.ui.theme.SkinPreset
import kotlin.math.max

private fun Outline.toMaterialPath(): Path = when (this) {
    is Outline.Generic -> path
    is Outline.Rectangle -> Path().apply { addRect(rect) }
    is Outline.Rounded -> Path().apply { addRoundRect(roundRect) }
}

/**
 * 轻量液态玻璃光场。所有 Brush 都缓存在 DrawModifier 中，静止时没有状态循环或 CPU 运算；
 * 按下/激活只改变少量渐变参数。每一层直接按 shape 绘制，不画任何闭合描边。
 */
private fun Modifier.liquidGlassOptics(
    enabled: Boolean,
    shape: Shape,
    dark: Boolean,
    showSheen: Boolean,
    panel: Boolean,
    activeColor: Color,
    activeProgress: Float,
    pressProgress: Float
): Modifier {
    if (!enabled) return this
    return drawWithCache {
        val outlinePath = shape.createOutline(size, layoutDirection, this).toMaterialPath()
        val width = size.width.coerceAtLeast(1f)
        val height = size.height.coerceAtLeast(1f)
        val longest = max(width, height)
        val press = pressProgress.coerceIn(0f, 1f)
        val active = activeProgress.coerceIn(0f, 1f)
        val panelFactor = if (panel) 0.68f else 1f
        val ambientAlpha = (
            if (showSheen) 0.15f else 0.075f
            ) * panelFactor + 0.035f * press
        val depthAlpha = (if (dark) 0.12f else 0.075f) * panelFactor

        // 左上方宽阔环境光，让透明底不再像一块平塑料。
        val ambient = Brush.radialGradient(
            colors = listOf(
                Color.White.copy(alpha = ambientAlpha),
                Color.White.copy(alpha = ambientAlpha * 0.28f),
                Color.Transparent
            ),
            center = Offset(
                x = width * (0.10f + 0.09f * press),
                y = height * (0.03f + 0.07f * press)
            ),
            radius = longest * 0.92f
        )

        // 右下方极轻的厚度阴影；它只占局部，不形成圆环或外框。
        val depth = Brush.radialGradient(
            colors = listOf(
                (if (dark) Color.Black else Color(0xFF6D7D8D)).copy(alpha = depthAlpha),
                Color.Transparent
            ),
            center = Offset(width * 1.04f, height * 1.06f),
            radius = longest * 0.88f
        )

        // 极弱 RGB 分离与镜面窄光带。按下时光带向右下滑动并增强，松开后自然淡回。
        val bandAlpha = (if (showSheen) 0.055f else 0.028f) + 0.10f * press
        val specular = Brush.linearGradient(
            colorStops = arrayOf(
                0.00f to Color.Transparent,
                0.36f to Color.Transparent,
                0.455f to Color(0xFFBDEFFF).copy(alpha = bandAlpha * 0.46f),
                0.505f to Color.White.copy(alpha = bandAlpha),
                0.555f to Color(0xFFFFD9F2).copy(alpha = bandAlpha * 0.34f),
                0.66f to Color.Transparent,
                1.00f to Color.Transparent
            ),
            start = Offset(-width * (0.72f - 0.20f * press), -height * 0.10f),
            end = Offset(width * (0.92f + 0.20f * press), height * 1.12f)
        )

        val activeBloom = Brush.radialGradient(
            colors = listOf(
                activeColor.copy(alpha = 0.22f * active),
                activeColor.copy(alpha = 0.07f * active),
                Color.Transparent
            ),
            center = Offset(width * 0.18f, height * 0.94f),
            radius = longest * 0.96f
        )

        onDrawBehind {
            // 每一层都直接按最终轮廓绘制，不创建矩形离屏层再裁切。这样无论按钮是
            // 圆形还是圆角矩形，GPU 都没有机会把缓存层边界显示成一圈方框。
            drawPath(outlinePath, ambient)
            drawPath(outlinePath, depth)
            if (active > 0.001f) drawPath(outlinePath, activeBloom)
            drawPath(outlinePath, specular)
        }
    }
}

private fun Modifier.buttonMaterialBase(
    shape: Shape,
    texture: Brush?,
    highlightTop: Color,
    highlightBottom: Color
): Modifier = drawWithCache {
    val outlinePath = shape.createOutline(size, layoutDirection, this).toMaterialPath()
    val highlight = Brush.verticalGradient(listOf(highlightTop, highlightBottom))
    onDrawBehind {
        texture?.let { drawPath(outlinePath, it) }
        drawPath(outlinePath, highlight)
    }
}

/**
 * 天然材质只使用克制的局部反光：皮革是宽阔哑光，木纹是沿纹理滑过的缎光。
 * 与液态玻璃一样，Brush 只在尺寸或按压进度改变时重建，不运行常驻动画。
 */
private fun Modifier.naturalMaterialOptics(
    skin: SkinPreset?,
    shape: Shape,
    dark: Boolean,
    panel: Boolean,
    pressProgress: Float
): Modifier {
    if (skin == null || skin == SkinPreset.FROSTED_GLASS) return this
    return drawWithCache {
        val outlinePath = shape.createOutline(size, layoutDirection, this).toMaterialPath()
        val width = size.width.coerceAtLeast(1f)
        val height = size.height.coerceAtLeast(1f)
        val longest = max(width, height)
        val press = pressProgress.coerceIn(0f, 1f)
        val panelFactor = if (panel) 0.66f else 1f
        val depth = Brush.radialGradient(
            colors = listOf(
                Color.Black.copy(
                    alpha = (if (dark) 0.10f else 0.065f) * panelFactor
                ),
                Color.Transparent
            ),
            center = Offset(width * 1.02f, height * 1.08f),
            radius = longest * 0.92f
        )
        val materialLight = when (skin) {
            SkinPreset.LEATHER -> Brush.radialGradient(
                colors = listOf(
                    Color(0xFFFFD2B8).copy(
                        alpha = (if (dark) 0.055f else 0.065f) * panelFactor +
                            0.015f * press
                    ),
                    Color(0xFFFFC3A1).copy(
                        alpha = (if (dark) 0.016f else 0.020f) * panelFactor
                    ),
                    Color.Transparent
                ),
                center = Offset(
                    width * (0.12f + 0.06f * press),
                    height * (0.02f + 0.04f * press)
                ),
                radius = longest * 1.08f
            )
            SkinPreset.WOOD -> Brush.linearGradient(
                colorStops = arrayOf(
                    0.00f to Color.Transparent,
                    0.24f to Color.Transparent,
                    0.46f to Color(0xFFFFD997).copy(
                        alpha = (if (dark) 0.075f else 0.10f) * panelFactor +
                            0.045f * press
                    ),
                    0.62f to Color(0xFFFFEDC5).copy(
                        alpha = (if (dark) 0.026f else 0.035f) * panelFactor
                    ),
                    0.78f to Color.Transparent,
                    1.00f to Color.Transparent
                ),
                start = Offset(-width * (0.34f - 0.10f * press), 0f),
                end = Offset(width * (1.10f + 0.12f * press), height * 0.42f)
            )
            SkinPreset.FROSTED_GLASS -> error("handled above")
        }
        // 真皮按钮是一块略微隆起的厚皮：顶部环境光与底部厚度阴影只沿纵向展开，
        // 不画闭合轮廓，避免重新出现圆框/多边形框。按下时厚度收紧，像皮面被压低。
        val leatherBodyDepth = if (skin == SkinPreset.LEATHER) {
            val relaxed = 1f - 0.70f * press
            Brush.verticalGradient(
                colorStops = arrayOf(
                    0.00f to Color(0xFFFFD8C0).copy(
                        alpha = (if (dark) 0.085f else 0.12f) * panelFactor * relaxed
                    ),
                    0.13f to Color(0xFFFFC7A5).copy(
                        alpha = (if (dark) 0.026f else 0.038f) * panelFactor * relaxed
                    ),
                    0.34f to Color.Transparent,
                    0.69f to Color.Transparent,
                    0.88f to Color(0xFF3A100A).copy(
                        alpha = (if (dark) 0.055f else 0.040f) * panelFactor * relaxed
                    ),
                    1.00f to Color(0xFF1B0705).copy(
                        alpha = (if (dark) 0.26f else 0.20f) * panelFactor * relaxed
                    )
                )
            )
        } else {
            null
        }
        onDrawBehind {
            drawPath(outlinePath, materialLight)
            leatherBodyDepth?.let { drawPath(outlinePath, it) }
            drawPath(outlinePath, depth)
        }
    }
}

/**
 * 皮革专属的压凹钢印。
 *
 * 内容轮廓分别向左上形成内阴影、向右下露一线暖色反光；与原图案重叠的主体区域会被
 * 扣除，只留下细窄边缘，不复制完整图案，因此不会形成重影。语义色仍由原内容负责。
 * 使用小范围离屏遮罩而非模糊或常驻动画，光向与按钮本体保持一致。
 */
private fun Modifier.leatherStampedContent(
    enabled: Boolean,
    dark: Boolean,
    pressProgress: Float
): Modifier {
    if (!enabled) return this
    return drawWithCache {
        val press = pressProgress.coerceIn(0f, 1f)
        val depthPx = (if (dark) 0.48.dp else 0.42.dp).toPx() * (1f - 0.16f * press)
        val layerBounds = Rect(
            left = -depthPx * 2f,
            top = -depthPx * 2f,
            right = size.width + depthPx * 2f,
            bottom = size.height + depthPx * 2f
        )
        val innerShadowPaint = Paint().apply {
            alpha = if (dark) 0.62f else 0.48f
            colorFilter = ColorFilter.tint(
                if (dark) Color(0xFF120504) else Color(0xFF35110B),
                BlendMode.SrcIn
            )
        }
        val lowerRimPaint = Paint().apply {
            alpha = if (dark) 0.34f else 0.42f
            colorFilter = ColorFilter.tint(
                if (dark) Color(0xFFFFB994) else Color(0xFFFFE0C8),
                BlendMode.SrcIn
            )
        }
        val knockoutPaint = Paint().apply {
            blendMode = BlendMode.DstOut
        }

        onDrawWithContent stampedDraw@{
            fun stampedEdge(offset: Offset, tintPaint: Paint) {
                // 先画偏移轮廓，再用原位置轮廓挖掉重合部分，只留下不到 1dp 的月牙边。
                drawContext.canvas.saveLayer(layerBounds, tintPaint)
                translate(offset.x, offset.y) { this@stampedDraw.drawContent() }
                drawContext.canvas.saveLayer(layerBounds, knockoutPaint)
                this@stampedDraw.drawContent()
                drawContext.canvas.restore()
                drawContext.canvas.restore()
            }

            // 凹刻的受光方向与凸起按钮相反：左上是内阴影，右下是被照亮的压痕边。
            stampedEdge(Offset(-depthPx, -depthPx), innerShadowPaint)
            stampedEdge(Offset(depthPx, depthPx), lowerRimPaint)
            this@stampedDraw.drawContent()
        }
    }
}

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
    val dark = colors.background.luminance() < 0.5f
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
        .liquidGlassOptics(
            enabled = true,
            shape = shape,
            dark = dark,
            showSheen = showSheen,
            panel = panel,
            activeColor = resolvedActiveColor,
            activeProgress = activeProgress,
            pressProgress = 0f
        )
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
 * 统一的液态毛玻璃悬浮按钮：半透明冷色底、稳定微霜、局部体积光与交互镜面光带。
 * 不画外沿描边，按钮任何状态（含激活态）都不会出现闭合亮框。
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
    val dark = colors.background.luminance() < 0.5f
    val resolvedActiveColor = activeColor ?: colors.accentBlue
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val texturePalette = LocalButtonTexturePalette.current
    val isLeatherButton = texturePalette?.skin == SkinPreset.LEATHER
    // 按下用短 tween 快速跟手，松开用全局弹簧回弹（与顶栏胶囊等共用手感参数）。
    // 厚皮不做玻璃按钮那种明显缩小，而是以轻微下沉表现真实键程。
    val pressScale by animateFloatAsState(
        targetValue = if (pressed && enabled) {
            if (isLeatherButton) 0.975f else 0.95f
        } else {
            1f
        },
        animationSpec = if (pressed) tween(80) else Motion.bouncy(),
        label = "glassPress"
    )
    val pressLight by animateFloatAsState(
        targetValue = if (pressed && enabled) 1f else 0f,
        animationSpec = tween(if (pressed) 90 else 220),
        label = "glassPressLight"
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
    // 三种皮肤都使用可平铺画刷；毛玻璃是最轻的微霜颗粒，叠在底色之上、高光之下。
    // 强度已烘焙进 tile 像素（见 SkinTexture.kt），这里按原样平铺即可。
    val baseElevation = shadowElevation ?: when {
        panel -> 0.dp
        isLeatherButton -> (8f + 2f * activeProgress).dp
        else -> (4f + 3f * activeProgress).dp
    }
    // 静止皮革比玻璃更像有厚度的实体块；按下时阴影与键程同时收紧。
    val elevation = if (isLeatherButton && !panel) {
        (baseElevation.value * (1f - 0.68f * pressLight)).dp
    } else {
        baseElevation
    }
    val compositionTextureSeed = currentCompositeKeyHash
    val skinTexture = remember(texturePalette, textureSeed, compositionTextureSeed) {
        texturePalette?.brushFor(textureSeed ?: compositionTextureSeed)
    }
    val isFrostedGlass = texturePalette?.skin == SkinPreset.FROSTED_GLASS
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
            translationY = if (isLeatherButton && !panel) {
                1.6.dp.toPx() * pressLight
            } else {
                0f
            }
            // 禁用态整体压淡：M3 Surface 的 enabled 只拦点击不改视觉，
            // 不加这行会出现"看起来可点、点了没反应"的假活按钮。
            alpha = if (enabled) 1f else 0.45f
        }
    ) {
        Row(
            modifier = Modifier
                // 材质层直接绘制为 shape，不再依赖矩形 graphicsLayer 裁切。这个约束由
                // 公共按钮统一维护，入口按钮、更新按钮及后续新增按钮不会再各自复发。
                .buttonMaterialBase(
                    shape = shape,
                    texture = skinTexture,
                    highlightTop = highlightTop,
                    highlightBottom = highlightBottom
                )
                .liquidGlassOptics(
                    enabled = isFrostedGlass,
                    shape = shape,
                    dark = dark,
                    showSheen = showSheen,
                    panel = panel,
                    activeColor = resolvedActiveColor,
                    activeProgress = activeProgress,
                    pressProgress = pressLight
                )
                .naturalMaterialOptics(
                    skin = texturePalette?.skin,
                    shape = shape,
                    dark = dark,
                    panel = panel,
                    pressProgress = pressLight
                )
                .padding(contentPadding)
                .leatherStampedContent(
                    enabled = texturePalette?.skin == SkinPreset.LEATHER,
                    dark = dark,
                    pressProgress = pressLight
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            content = content
        )
    }
}
