package com.ztransfer.ui.screen

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.LocalButtonTexturePalette
import com.ztransfer.ui.theme.Motion
import com.ztransfer.ui.theme.SkinPreset
import kotlin.math.ceil
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

/**
 * 稳定的磨砂玻璃材质。
 *
 * 不绘制方位光场、镜面高光或彩色分光。半透明底色和均匀雾化层负责散射，
 * 非平铺的确定性微颗粒负责磨砂，宽暗内缘与极细外缘共同交代玻璃厚度。
 * 颗粒直接生成在最终 shape 内，不使用位图 tile，避免某些 GPU 显示矩形接缝。
 */
private fun Modifier.frostedPebbleOptics(
    shape: Shape,
    dark: Boolean,
    showSheen: Boolean,
    panel: Boolean,
    activeColor: Color,
    activeProgress: Float,
    pressProgress: Float
): Modifier = drawWithCache {
    val outlinePath = shape.createOutline(size, layoutDirection, this).toMaterialPath()
    val width = size.width.coerceAtLeast(1f)
    val height = size.height.coerceAtLeast(1f)
    val press = pressProgress.coerceIn(0f, 1f)
    val active = activeProgress.coerceIn(0f, 1f)
    val materialStrength = if (panel) 0.66f else 1f
    val definitionStrength = if (showSheen) 1f else 0.72f
    val volume = 1f - 0.48f * press

    // 这层是均匀雾化，不表达光源方向；深色模式稍微提亮介质，浅色模式增加乳白散射。
    val diffusionVeil = if (dark) {
        Color(0xFFD6E2E8).copy(alpha = 0.050f * materialStrength)
    } else {
        Color.White.copy(alpha = 0.105f * materialStrength)
    }
    val activeVeil = activeColor.copy(alpha = 0.14f * active)
    val pressedVeil = (if (dark) Color.Black else Color(0xFF40515C)).copy(
        alpha = 0.045f * press * materialStrength
    )

    // 两层边缘都沿整个轮廓均匀分布，不做“上亮下暗”。宽内缘提供厚度，细外缘负责定界。
    val innerEdge = (if (dark) Color(0xFF02080C) else Color(0xFF61717B)).copy(
        alpha = (if (dark) 0.24f else 0.13f) * materialStrength * volume
    )
    val outerEdge = Color.White.copy(
        alpha = (if (dark) 0.24f else 0.66f) *
            materialStrength * volume * definitionStrength
    )
    val innerEdgeWidth = 3.2.dp.toPx()
    val outerEdgeWidth = 1.dp.toPx()

    // 每格仅一个亚像素级颗粒，数量随按钮面积线性增长。颗粒在 draw cache 中合并成
    // 明暗两个 Path，实际每帧只有两次 drawPath，而不是逐颗粒提交数百条绘制命令。
    // 哈希包含格子坐标和当前尺寸，因此没有随机状态、没有动画抖动，也没有平铺接缝。
    val grainStep = 5.5.dp.toPx().coerceAtLeast(1f)
    val columns = ceil(width / grainStep).toInt().coerceAtLeast(1)
    val rows = ceil(height / grainStep).toInt().coerceAtLeast(1)
    val lightGrainPath = Path()
    val darkGrainPath = Path()
    for (row in 0 until rows) {
        for (column in 0 until columns) {
            var hash = column * 0x1F123BB5 + row * 0x05491333 +
                columns * 0x0127A5D9 + rows * 0x001B8735
            hash = (hash xor (hash ushr 16)) * 0x45D9F3B
            hash = hash xor (hash ushr 16)
            val xJitter = (hash and 0xFF) / 255f
            val yJitter = ((hash ushr 8) and 0xFF) / 255f
            val radiusJitter = ((hash ushr 16) and 0x7F) / 127f
            val x = (column + 0.18f + 0.64f * xJitter) * grainStep
            val y = (row + 0.18f + 0.64f * yJitter) * grainStep
            val radius = (0.24f + 0.24f * radiusJitter).dp.toPx()
            val particle = Rect(x - radius, y - radius, x + radius, y + radius)
            if ((hash and 0x01000000) == 0) {
                lightGrainPath.addOval(particle)
            } else {
                darkGrainPath.addOval(particle)
            }
        }
    }
    val lightGrain = Color.White.copy(
        alpha = (if (dark) 0.040f else 0.075f) * materialStrength * definitionStrength
    )
    val darkGrain = (if (dark) Color(0xFF071016) else Color(0xFF6A7B85)).copy(
        alpha = (if (dark) 0.045f else 0.038f) * materialStrength * definitionStrength
    )

    onDrawBehind {
        drawPath(outlinePath, diffusionVeil)
        if (active > 0.001f) drawPath(outlinePath, activeVeil)
        if (press > 0.001f) drawPath(outlinePath, pressedVeil)
        drawPath(lightGrainPath, lightGrain)
        drawPath(darkGrainPath, darkGrain)
        drawPath(outlinePath, innerEdge, style = Stroke(width = innerEdgeWidth))
        drawPath(outlinePath, outerEdge, style = Stroke(width = outerEdgeWidth))
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
 * 圆润钛合金体积。
 *
 * 喷砂/拉丝微纹理由稳定贴图提供；这里使用宽冷光、柔和侧暗和较深底部阴影，
 * 塑造成一整块圆润钛合金。反光带足够宽，不产生铬面般锋利的镜面线。
 */
private fun Modifier.titaniumRoundedFinish(
    enabled: Boolean,
    shape: Shape,
    dark: Boolean,
    panel: Boolean,
    pressProgress: Float
): Modifier {
    if (!enabled) return this
    return drawWithCache {
        val outlinePath = shape.createOutline(size, layoutDirection, this).toMaterialPath()
        val width = size.width.coerceAtLeast(1f)
        val height = size.height.coerceAtLeast(1f)
        val longest = max(width, height)
        val press = pressProgress.coerceIn(0f, 1f)
        val panelFactor = if (panel) 0.66f else 1f
        val volume = 1f - 0.62f * press
        val metalLight = if (dark) Color(0xFFEAF2F6) else Color.White
        val metalMid = if (dark) Color(0xFFB8C4CA) else Color(0xFFDCE4E8)
        val metalShadow = if (dark) Color(0xFF242E35) else Color(0xFF66737B)

        val crown = Brush.radialGradient(
            colorStops = arrayOf(
                0.00f to metalLight.copy(alpha = 0.18f * panelFactor * volume),
                0.34f to metalMid.copy(alpha = 0.105f * panelFactor * volume),
                0.62f to metalMid.copy(alpha = 0.035f * panelFactor * volume),
                0.82f to metalShadow.copy(alpha = 0.055f * panelFactor * volume),
                1.00f to metalShadow.copy(
                    alpha = (if (dark) 0.16f else 0.12f) * panelFactor * volume
                )
            ),
            center = Offset(width * 0.40f, height * 0.30f),
            radius = max(width * 0.53f, height * 1.88f)
        )
        val topRoll = Brush.verticalGradient(
            colorStops = arrayOf(
                0.00f to metalLight.copy(alpha = 0.16f * panelFactor * volume),
                0.24f to metalMid.copy(alpha = 0.065f * panelFactor * volume),
                0.52f to Color.Transparent,
                1.00f to Color.Transparent
            )
        )
        val sideRoll = Brush.horizontalGradient(
            colorStops = arrayOf(
                0.00f to metalLight.copy(alpha = 0.040f * panelFactor * volume),
                0.22f to Color.Transparent,
                0.68f to Color.Transparent,
                1.00f to metalShadow.copy(alpha = 0.15f * panelFactor * volume)
            )
        )
        val bottomRoll = Brush.verticalGradient(
            colorStops = arrayOf(
                0.00f to Color.Transparent,
                0.54f to Color.Transparent,
                0.76f to metalShadow.copy(alpha = 0.060f * panelFactor * volume),
                1.00f to metalShadow.copy(
                    alpha = (if (dark) 0.30f else 0.22f) * panelFactor * volume
                )
            )
        )
        val satinReflection = Brush.linearGradient(
            colorStops = arrayOf(
                0.00f to Color.Transparent,
                0.22f to Color.Transparent,
                0.43f to metalLight.copy(alpha = 0.060f * panelFactor * volume),
                0.62f to metalMid.copy(alpha = 0.028f * panelFactor * volume),
                0.82f to Color.Transparent,
                1.00f to Color.Transparent
            ),
            start = Offset(-width * 0.10f, 0f),
            end = Offset(width * 1.06f, height * 0.72f)
        )
        val pressedDull = Brush.radialGradient(
            colors = listOf(
                metalShadow.copy(alpha = 0.045f * press * panelFactor),
                Color.Transparent
            ),
            center = Offset(width * 0.5f, height * 0.52f),
            radius = longest * 0.72f
        )

        onDrawBehind {
            drawPath(outlinePath, crown)
            drawPath(outlinePath, topRoll)
            drawPath(outlinePath, sideRoll)
            drawPath(outlinePath, bottomRoll)
            drawPath(outlinePath, satinReflection)
            if (press > 0.001f) drawPath(outlinePath, pressedDull)
        }
    }
}

/**
 * 实木按钮的硬质微弧面。
 *
 * 木纹仍由稳定随机贴图提供；这里只以较克制的顶部暖光、右侧与底部深木阴影，
 * 把纹理所在的平面塑造成一块有厚度的木料。边缘比毛玻璃硬，但没有额外描边。
 */
private fun Modifier.woodSculptedFinish(
    enabled: Boolean,
    shape: Shape,
    dark: Boolean,
    panel: Boolean,
    pressProgress: Float
): Modifier {
    if (!enabled) return this
    return drawWithCache {
        val outlinePath = shape.createOutline(size, layoutDirection, this).toMaterialPath()
        val width = size.width.coerceAtLeast(1f)
        val height = size.height.coerceAtLeast(1f)
        val longest = max(width, height)
        val press = pressProgress.coerceIn(0f, 1f)
        val panelFactor = if (panel) 0.66f else 1f
        val volume = 1f - 0.64f * press
        val warmLight = if (dark) Color(0xFFF7D69B) else Color(0xFFFFE0A9)
        val woodShadow = if (dark) Color(0xFF140A04) else Color(0xFF5C3013)

        val crown = Brush.radialGradient(
            colorStops = arrayOf(
                0.00f to warmLight.copy(
                    alpha = (if (dark) 0.115f else 0.13f) * panelFactor * volume
                ),
                0.35f to warmLight.copy(
                    alpha = (if (dark) 0.068f else 0.080f) * panelFactor * volume
                ),
                0.61f to warmLight.copy(alpha = 0.025f * panelFactor * volume),
                0.81f to woodShadow.copy(alpha = 0.045f * panelFactor * volume),
                1.00f to woodShadow.copy(
                    alpha = (if (dark) 0.135f else 0.10f) * panelFactor * volume
                )
            ),
            center = Offset(width * 0.39f, height * 0.30f),
            radius = max(width * 0.53f, height * 1.98f)
        )
        val topRoll = Brush.verticalGradient(
            colorStops = arrayOf(
                0.00f to warmLight.copy(
                    alpha = (if (dark) 0.105f else 0.14f) * panelFactor * volume
                ),
                0.20f to warmLight.copy(
                    alpha = (if (dark) 0.040f else 0.055f) * panelFactor * volume
                ),
                0.46f to Color.Transparent,
                1.00f to Color.Transparent
            )
        )
        val sideRoll = Brush.horizontalGradient(
            colorStops = arrayOf(
                0.00f to warmLight.copy(alpha = 0.025f * panelFactor * volume),
                0.22f to Color.Transparent,
                0.72f to Color.Transparent,
                1.00f to woodShadow.copy(
                    alpha = (if (dark) 0.135f else 0.095f) * panelFactor * volume
                )
            )
        )
        val bottomRoll = Brush.verticalGradient(
            colorStops = arrayOf(
                0.00f to Color.Transparent,
                0.58f to Color.Transparent,
                0.78f to woodShadow.copy(alpha = 0.055f * panelFactor * volume),
                1.00f to woodShadow.copy(
                    alpha = (if (dark) 0.31f else 0.21f) * panelFactor * volume
                )
            )
        )
        val pressedDull = Brush.radialGradient(
            colors = listOf(
                woodShadow.copy(alpha = 0.045f * press * panelFactor),
                Color.Transparent
            ),
            center = Offset(width * 0.5f, height * 0.52f),
            radius = longest * 0.72f
        )

        onDrawBehind {
            drawPath(outlinePath, crown)
            drawPath(outlinePath, topRoll)
            drawPath(outlinePath, sideRoll)
            drawPath(outlinePath, bottomRoll)
            if (press > 0.001f) drawPath(outlinePath, pressedDull)
        }
    }
}

/**
 * 钛合金专属的压凹钢印。
 *
 * 钢印的明暗全部限制在文字/图案轮廓内部：金属凹槽底面只比按钮略暗，左上形成
 * 柔和的内阴影，右下露出窄而克制的冷色切面。两级亚像素边缘让压痕自然过渡，
 * 不向轮廓外复制内容，因此不会出现普通投影或重影。
 */
private fun Modifier.titaniumStampedContent(
    enabled: Boolean,
    dark: Boolean,
    pressProgress: Float,
    stampColor: Color?
): Modifier {
    if (!enabled) return this
    return drawWithCache {
        val press = pressProgress.coerceIn(0f, 1f)
        val depthPx = (if (dark) 0.48.dp else 0.44.dp).toPx() * (1f - 0.12f * press)
        val fineDepthPx = depthPx * 0.48f
        val layerBounds = Rect(
            left = -depthPx * 2f,
            top = -depthPx * 2f,
            right = size.width + depthPx * 2f,
            bottom = size.height + depthPx * 2f
        )
        val hasColorInlay = stampColor != null
        val stampFacePaint = Paint().apply {
            alpha = if (hasColorInlay) {
                if (dark) 0.96f else 0.92f
            } else {
                if (dark) 0.90f else 0.88f
            }
            colorFilter = ColorFilter.tint(
                stampColor ?: if (dark) Color(0xFF2B373E) else Color(0xFF58656C),
                BlendMode.SrcIn
            )
        }
        val broadShadowPaint = Paint().apply {
            alpha = if (dark) 0.38f else 0.28f
            colorFilter = ColorFilter.tint(
                if (dark) Color(0xFF1D272D) else Color(0xFF505D64),
                BlendMode.SrcIn
            )
        }
        val deepShadowPaint = Paint().apply {
            alpha = if (dark) 0.25f else 0.18f
            colorFilter = ColorFilter.tint(
                if (dark) Color(0xFF111A1F) else Color(0xFF3F4B52),
                BlendMode.SrcIn
            )
        }
        val broadHighlightPaint = Paint().apply {
            alpha = if (dark) 0.24f else 0.30f
            colorFilter = ColorFilter.tint(
                if (dark) Color(0xFFD6E1E6) else Color(0xFFF1F6F8),
                BlendMode.SrcIn
            )
        }
        val fineHighlightPaint = Paint().apply {
            alpha = if (dark) 0.16f else 0.20f
            colorFilter = ColorFilter.tint(
                if (dark) Color(0xFFF0F6F8) else Color.White,
                BlendMode.SrcIn
            )
        }
        val knockoutPaint = Paint().apply {
            blendMode = BlendMode.DstOut
        }

        onDrawWithContent stampedDraw@{
            fun stampedInnerEdge(knockoutOffset: Offset, tintPaint: Paint) {
                drawContext.canvas.saveLayer(layerBounds, tintPaint)
                this@stampedDraw.drawContent()
                drawContext.canvas.saveLayer(layerBounds, knockoutPaint)
                translate(knockoutOffset.x, knockoutOffset.y) {
                    this@stampedDraw.drawContent()
                }
                drawContext.canvas.restore()
                drawContext.canvas.restore()
            }

            // 凹槽底面仍是同一块金属，只因压低和表面粗糙度增加而略暗。
            drawContext.canvas.saveLayer(layerBounds, stampFacePaint)
            this@stampedDraw.drawContent()
            drawContext.canvas.restore()

            // 光从左上方照来：凹槽左上内壁收暗，右下切面反出一线冷光。
            // 先画宽而淡的过渡，再叠较窄的核心边，避免硬梆梆的双色描边。
            stampedInnerEdge(Offset(depthPx, depthPx), broadShadowPaint)
            stampedInnerEdge(Offset(fineDepthPx, fineDepthPx), deepShadowPaint)
            stampedInnerEdge(Offset(-depthPx, -depthPx), broadHighlightPaint)
            stampedInnerEdge(Offset(-fineDepthPx, -fineDepthPx), fineHighlightPaint)
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
 * 统一的材质悬浮按钮。毛玻璃使用半透明雾化底、微颗粒与双层柔边；钛合金使用喷砂拉丝
 * 与圆润金属体积；木纹使用稳定随机纹理与硬质微弧木面。
 * 三种材质都不额外改变调用方提供的 shape。
 * 与 "Z传" 悬浮按钮同款视觉。全局悬浮控件（返回/标题/清空/重试等）复用，保证设计语言一致。
 *
 * 按压微缩放：按下快速下沉到 0.95、松开弹性回弹——全 App 玻璃按钮统一的"手感"，
 * 一处定义处处生效。
 *
 * [panel]：面板内变体。默认样式的投影是为悬浮在照片/内容之上设计的，
 * 放进平整的玻璃弹窗（如高级版/换机弹窗）里显得突兀；panel 为真时改用
 * 面板内卡片的同一玻璃语言——淡底、低对比材质、无投影，
 * 浅色/深色主题各自取 onBackground 同族色，两套主题都贴着面板长。
 *
 * [active]：持续选中态。保留毛玻璃基底和按压手感，叠加强调色淡层；实体材质稍抬高投影，
 * 供筛选等“离开页面后仍持续生效”的状态使用；不画强调色轮廓圈。
 * [activeColor] 可让有明确语义色的按钮复用同一套激活动画，不另造组件。
 *
 * [showSheen]：控制实体材质的顶部高光；毛玻璃没有方位高光，此参数只降低其边缘和颗粒
 * 定义度。紧凑按钮可关闭它，避免小面积圆角表面看起来像一圈白框。
 *
 * [titaniumStampColor]：仅在钛合金主题中为凹刻内容填色，同时保留钢印内壁的明暗切面。
 * 适合品牌标志等需要成为视觉焦点的内容；普通按钮保持默认的深灰金属钢印。
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
    frostedOpacityBoost: Float = 0f,
    textureSeed: Int? = null,
    titaniumStampColor: Color? = null,
    activeOutline: Boolean = false,
    content: @Composable RowScope.() -> Unit
) {
    val colors = AppTheme.colors
    val dark = colors.background.luminance() < 0.5f
    val resolvedActiveColor = activeColor ?: colors.accentBlue
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val texturePalette = LocalButtonTexturePalette.current
    val isTitaniumButton = texturePalette?.skin == SkinPreset.TITANIUM
    val isWoodButton = texturePalette?.skin == SkinPreset.WOOD
    val isSolidMaterial = isTitaniumButton || isWoodButton
    // 按下用短 tween 快速跟手，松开用全局弹簧回弹（与顶栏胶囊等共用手感参数）。
    // 钛合金的键程略克制，实木与磨砂玻璃稍多一些缩放反馈。
    val pressScale by animateFloatAsState(
        targetValue = if (pressed && enabled) {
            if (isTitaniumButton) 0.970f else 0.965f
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
    // Reuse the existing active transition so the outline and tint settle as one material state.
    // No separate animator or persistent work is introduced.
    val activeOutlineBorder = if (activeOutline && activeProgress > 0.001f) {
        BorderStroke(
            width = 1.25.dp,
            color = resolvedActiveColor.copy(alpha = 0.58f * activeProgress),
        )
    } else {
        null
    }
    // 只有实体材质使用可平铺位图画刷；毛玻璃的非平铺微颗粒由绘制层直接生成。
    val baseElevation = shadowElevation ?: when {
        panel -> 0.dp
        isWoodButton -> (8f + 2f * activeProgress).dp
        isTitaniumButton -> (7f + 2f * activeProgress).dp
        else -> (4f + 3f * activeProgress).dp
    }
    // 钛合金与木头都是实体材质；按下时投影与键程同时收紧。
    val elevation = if (isSolidMaterial && !panel) {
        (baseElevation.value * (1f - 0.66f * pressLight)).dp
    } else {
        baseElevation
    }
    // currentCompositeKeyHash 由稳定调用位置（以及 Lazy 列表的 key）决定；显式 textureSeed
    // 可覆盖它。两者都只参与确定性哈希，所以 A/B 按钮各自选中不同变体后不会在重组、
    // 返回页面或进程重启时跳纹。
    val compositionTextureSeed = currentCompositeKeyHash
    val skinTexture = remember(texturePalette, textureSeed, compositionTextureSeed) {
        texturePalette?.brushFor(textureSeed ?: compositionTextureSeed)
    }
    val isFrostedGlass = texturePalette?.skin == SkinPreset.FROSTED_GLASS
    val baseColor = if (panel) colors.onBackground.copy(alpha = 0.05f) else colors.buttonSurface
    val containerColor =
        if (isFrostedGlass && !panel && frostedOpacityBoost > 0f) {
            val boost = frostedOpacityBoost.coerceIn(0f, 1f)
            baseColor.copy(alpha = baseColor.alpha + (1f - baseColor.alpha) * boost)
        } else {
            baseColor
        }
    // 静止时不创建矩形 RenderNode。毛玻璃是半透明的，部分 GPU 会把合成层边界
    // 显成方框；只有按压动画或禁用态确实需要变换时才临时创建图层。
    val transformedModifier = if (pressScale == 1f && enabled) {
        modifier
    } else {
        modifier.graphicsLayer {
            scaleX = pressScale
            scaleY = pressScale
            translationY = if (isSolidMaterial && !panel) {
                1.6.dp.toPx() * pressLight
            } else {
                0f
            }
            // 禁用态整体压淡：M3 Surface 的 enabled 只拦点击不改视觉，
            // 不加这行会出现"看起来可点、点了没反应"的假活按钮。
            alpha = if (enabled) 1f else 0.45f
        }
    }

    if (isFrostedGlass) {
        // 毛玻璃不再经过 Material Surface。它的 elevation、默认 indication 和半透明
        // 背景会分层缓存，正是圆形入口及更新按钮上残余矩形框的来源。
        Box(
            modifier = transformedModifier
                .clip(shape)
                .background(containerColor)
                .frostedPebbleOptics(
                    shape = shape,
                    dark = dark,
                    showSheen = showSheen,
                    panel = panel,
                    activeColor = resolvedActiveColor,
                    activeProgress = activeProgress,
                    pressProgress = pressLight
                )
                .then(
                    activeOutlineBorder?.let { outline ->
                        Modifier.border(outline, shape)
                    } ?: Modifier
                )
                .clickable(
                    enabled = enabled,
                    role = Role.Button,
                    interactionSource = interactionSource,
                    indication = null,
                    onClick = onClick
                ),
            contentAlignment = Alignment.Center
        ) {
            Row(
                modifier = Modifier.padding(contentPadding),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(
                    6.dp,
                    Alignment.CenterHorizontally,
                ),
                content = content
            )
        }
    } else {
        Surface(
            onClick = onClick,
            enabled = enabled,
            shape = shape,
            color = containerColor,
            border = activeOutlineBorder,
            shadowElevation = elevation,
            interactionSource = interactionSource,
            modifier = transformedModifier
        ) {
            Row(
                modifier = Modifier
                    .buttonMaterialBase(
                        shape = shape,
                        texture = skinTexture,
                        highlightTop = highlightTop,
                        highlightBottom = highlightBottom
                    )
                    .titaniumRoundedFinish(
                        enabled = isTitaniumButton,
                        shape = shape,
                        dark = dark,
                        panel = panel,
                        pressProgress = pressLight
                    )
                    .woodSculptedFinish(
                        enabled = isWoodButton,
                        shape = shape,
                        dark = dark,
                        panel = panel,
                        pressProgress = pressLight
                    )
                    .padding(contentPadding)
                    .titaniumStampedContent(
                        enabled = isTitaniumButton,
                        dark = dark,
                        pressProgress = pressLight,
                        stampColor = titaniumStampColor
                ),
                verticalAlignment = Alignment.CenterVertically,
                // Surface 会把固定尺寸按钮的 Row 撑满；显式居中，避免钛合金/木纹主题
                // 沿用 Row 默认的 Start 排列，把单图标推到按钮左侧。
                horizontalArrangement = Arrangement.spacedBy(
                    6.dp,
                    Alignment.CenterHorizontally,
                ),
                content = content
            )
        }
    }
}
