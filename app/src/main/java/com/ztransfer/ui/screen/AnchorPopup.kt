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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.Motion
import kotlinx.coroutines.launch

/** 布局/开合热路径专用的非观察状态；更新它不会让弹窗的大型内容树重新组合。 */
private class PopupAnimationState(
    var panelBounds: Rect? = null,
    var expansionStarted: Boolean = false,
    var closing: Boolean = false,
)

/**
 * 通用「从按钮变形弹出」的毛玻璃浮层外壳（设置面板与筛选面板共用）。
 *
 * 面板以触发按钮 [anchorBounds]（同一 Compose 根坐标系）中心为缩放原点，做轻量缩放淡入；
 * 关闭时反向收回再移除。避免把复杂面板从极小尺寸逐帧放大，降低首次呼出的图层合成压力。
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

    // 入场进度：0=不可见，1=完全展开。
    val progress = remember { Animatable(0f) }
    val animationState = remember { PopupAnimationState() }
    val animationScope = rememberCoroutineScope()
    val currentOnDismiss by rememberUpdatedState(onDismiss)

    // 关闭只驱动图层动画，不写 Compose State；否则设置面板会在收起首帧整树重组。
    val startClose: () -> Unit = {
        if (!animationState.closing) {
            animationState.closing = true
            animationScope.launch {
                progress.animateTo(0f, Motion.overlayCollapse)
                // 收起期间调用方状态仍可能更新（例如语言选择标记“动画后重建”），始终执行
                // 最新回调，避免捕获关闭开始前的旧闭包。
                currentOnDismiss()
            }
        }
    }
    BackHandler { startClose() }

    Box(modifier = Modifier.fillMaxSize()) {
        // 遮罩：随进度淡入；点击外部收回。拖动一并消费，防止滚动穿透到底下的列表。
        Box(
            modifier = Modifier
                .fillMaxSize()
                // 直接画带进度透明度的遮罩，避免 graphicsLayer(alpha) 为整屏内容分配
                // 离屏缓冲。首次呼出小面板时这块全屏合成最容易与面板首帧抢 GPU。
                .drawBehind {
                    if (dim) drawRect(colors.scrim, alpha = progress.value)
                }
                .pointerInput(Unit) { detectTapGestures { startClose() } }
                .pointerInput(Unit) { detectDragGestures { change, _ -> change.consume() } }
        )

        // 面板：以按钮中心为原点轻微缩放淡入；毛玻璃底 + 细描边 + 自上而下高光叠层。
        Surface(
            modifier = panelModifier
                .onGloballyPositioned { coordinates ->
                    animationState.panelBounds = coordinates.boundsInRoot()
                    if (!animationState.expansionStarted && !animationState.closing) {
                        animationState.expansionStarted = true
                        animationScope.launch {
                            progress.animateTo(1f, Motion.overlayExpand)
                        }
                    }
                }
                .graphicsLayer {
                    val b = animationState.panelBounds
                    if (b != null && b.width > 0f && b.height > 0f && anchorBounds != null) {
                        // 按钮中心相对于面板自身的比例位置（可超出 0..1，即原点落在面板外）。
                        transformOrigin = TransformOrigin(
                            (anchorBounds.center.x - b.left) / b.width,
                            (anchorBounds.center.y - b.top) / b.height
                        )
                    }
                    val p = progress.value
                    // 极端缩放会让整块设置/筛选内容在每帧进行高成本重采样；4% 的形变已经足以
                    // 表达来源方向，主要动势交给淡入完成。ModulateAlpha 避免为透明度额外创建
                    // 一块与面板等大的离屏缓冲。
                    compositingStrategy = CompositingStrategy.ModulateAlpha
                    val s = 0.96f + 0.04f * p
                    scaleX = s
                    scaleY = s
                    alpha = p
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
