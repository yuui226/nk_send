package com.ztransfer.ui.screen

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.Motion

/**
 * 通用「从按钮变形弹出」的毛玻璃浮层外壳（设置面板与筛选面板共用）。
 *
 * 面板以触发按钮 [anchorBounds]（同一 Compose 根坐标系）中心为缩放原点，从约按钮大小（6%）
 * 放大到全尺寸——明显地「从按钮长出来」；关闭时反向缩回按钮再移除（从哪来回哪去）。
 * 遮罩随进度淡入，点击遮罩 / 返回键触发收回。
 *
 * 位置与尺寸由调用方经 [panelModifier] 决定（相对根 Box 左上角，用 padding 贴到按钮下方、
 * fillMaxWidth 或 width 定宽）。[content] 收到 close 回调，供面板内的关闭按钮使用；
 * [overlayContent] 渲染在遮罩与面板之上（如底部玻璃提示），可用 align 自行定位。
 */
@Composable
fun AnchorPopup(
    anchorBounds: Rect?,
    onDismiss: () -> Unit,
    panelModifier: Modifier,
    shape: Shape = RoundedCornerShape(20.dp),
    // 遮罩是否压暗背景：大面板（设置）保持压暗聚焦；小面板（筛选下拉）传 false——
    // 全屏变暗对几个胶囊的下拉太兴师动众，遮罩仍在（点外部收起、拦滚动穿透），只是透明。
    dim: Boolean = true,
    overlayContent: @Composable BoxScope.() -> Unit = {},
    content: @Composable BoxScope.(close: () -> Unit) -> Unit
) {
    val colors = AppTheme.colors

    // 变形动画进度：0=收在按钮处（不可见），1=完全展开。
    var panelBounds by remember { mutableStateOf<Rect?>(null) }
    val progress = remember { Animatable(0f) }
    var closing by remember { mutableStateOf(false) }

    // 面板测量完成即入场展开。
    LaunchedEffect(panelBounds, closing) {
        if (!closing && panelBounds != null && progress.value < 1f) {
            progress.animateTo(1f, Motion.overlayExpand)
        }
    }
    // 关闭：反向收回后再真正移除。
    LaunchedEffect(closing) {
        if (closing) {
            progress.animateTo(0f, Motion.overlayCollapse)
            onDismiss()
        }
    }
    val startClose: () -> Unit = { closing = true }
    BackHandler(enabled = !closing) { startClose() }

    Box(modifier = Modifier.fillMaxSize()) {
        // 遮罩：随进度淡入；点击外部收回。拖动一并消费，防止滚动穿透到底下的列表。
        Box(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer { alpha = progress.value }
                .then(if (dim) Modifier.background(colors.scrim) else Modifier)
                .pointerInput(Unit) { detectTapGestures { startClose() } }
                .pointerInput(Unit) { detectDragGestures { change, _ -> change.consume() } }
        )

        // 面板：以按钮中心为原点缩放展开；毛玻璃底 + 细描边 + 自上而下高光叠层。
        Surface(
            modifier = panelModifier
                .onGloballyPositioned { panelBounds = it.boundsInRoot() }
                .graphicsLayer {
                    val b = panelBounds
                    if (b != null && b.width > 0f && b.height > 0f && anchorBounds != null) {
                        // 按钮中心相对于面板自身的比例位置（可超出 0..1，即原点落在面板外）。
                        transformOrigin = TransformOrigin(
                            (anchorBounds.center.x - b.left) / b.width,
                            (anchorBounds.center.y - b.top) / b.height
                        )
                    }
                    val p = progress.value
                    val s = 0.06f + 0.94f * p
                    scaleX = s
                    scaleY = s
                    // 透明度更快到达不透明，放大过程中面板已清晰可见。
                    alpha = (p * 2f).coerceAtMost(1f)
                }
                // 消费面板内点击，避免穿透到遮罩误关闭。
                .pointerInput(Unit) { detectTapGestures { } },
            shape = shape,
            color = colors.glassSurfaceHeavy,
            border = BorderStroke(1.dp, colors.glassPanelBorder),
            tonalElevation = 6.dp
        ) {
            Box {
                // 自上而下淡出的高光叠层，营造毛玻璃质感。
                Box(
                    modifier = Modifier
                        .matchParentSize()
                        .background(Brush.verticalGradient(listOf(colors.glassSheen, Color.Transparent)))
                )
                content(startClose)
            }
        }

        overlayContent()
    }
}
