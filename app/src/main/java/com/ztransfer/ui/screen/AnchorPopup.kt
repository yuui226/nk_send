package com.ztransfer.ui.screen

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
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
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.AppTheme
import kotlinx.coroutines.launch

/** 布局/开合热路径专用的非观察状态；更新它不会让弹窗的大型内容树重新组合。 */
private class PopupAnimationState(
    var panelBounds: Rect? = null,
    var expansionStarted: Boolean = false,
    var closing: Boolean = false,
    var interactive: Boolean = false,
    // The panel is static during an open/close transition. Recording it once avoids
    // re-rasterizing the whole settings tree on every animation frame.
    var layerRecorded: Boolean = false,
)

/** Let content scroll/fling first, then keep its unused motion inside the modal boundary. */
private object PopupScrollBoundary : NestedScrollConnection {
    override fun onPostScroll(
        consumed: Offset,
        available: Offset,
        source: NestedScrollSource,
    ): Offset = available

    override suspend fun onPostFling(consumed: Velocity, available: Velocity): Velocity = available
}

/** Shared button-anchored genie shell. Content keeps its final layout throughout the animation.
 * Missing/invalid anchors use the renderer's fade fallback. Outside taps and back close it.
 */
@Composable
fun AnchorPopup(
    anchorBounds: Rect?,
    onDismiss: () -> Unit,
    panelModifier: Modifier,
    panelAlignment: Alignment = Alignment.TopStart,
    shape: Shape = RoundedCornerShape(20.dp),
    // 遮罩是否压暗背景：大面板（设置）保持压暗聚焦；小面板（筛选下拉）传 false——
    // 全屏变暗对几个胶囊的下拉太兴师动众，遮罩仍在（点外部收起、拦滚动穿透），只是透明。
    dim: Boolean = true,
    // 大图上的编辑面板采用轻缩放，不扭曲照片与表单；默认弹窗仍沿用原动画。
    gentleMotion: Boolean = false,
    overlayContent: @Composable BoxScope.() -> Unit = {},
    content: @Composable BoxScope.(close: () -> Unit) -> Unit
) {
    val colors = AppTheme.colors
    val genieLayer = rememberGraphicsLayer()

    // 入场进度：0=不可见，1=完全展开。
    val progress = remember { Animatable(0f) }
    val animationState = remember { PopupAnimationState() }
    val animationScope = rememberCoroutineScope()
    val currentOnDismiss by rememberUpdatedState(onDismiss)

    // 关闭只驱动图层动画，不写 Compose State；否则设置面板会在收起首帧整树重组。
    val startClose: () -> Unit = {
        if (!animationState.closing) {
            animationState.closing = true
            animationState.interactive = false
            animationScope.launch {
                progress.animateTo(0f,
                    tween(((if (gentleMotion) 220 else GENIE_COLLAPSE_DURATION_MS) * progress.value).toInt().coerceAtLeast(1),
                        easing = if (gentleMotion) FastOutSlowInEasing else GenieCollapseEasing))
                // 收起期间调用方状态仍可能更新，始终执行最新回调，避免捕获关闭开始前的旧闭包。
                currentOnDismiss()
            }
        }
    }
    BackHandler { startClose() }

    Box(modifier = Modifier
        .fillMaxSize()
        .nestedScroll(PopupScrollBoundary)
        // Catch vertical drags on short content, headers and blank space after children.
        // Match child vertical slop: a 2D detector could steal a diagonal scroll from them.
        .pointerInput(Unit) { detectVerticalDragGestures { change, _ -> change.consume() } }
    ) {
        // 遮罩随进度淡入，点击外部收回；面板外保留各方向的拖动拦截。
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

        // Content is measured at its final size; only drawing changes during the transition.
        // No per-frame width/height state updates, bitmap snapshots or layout-size animation here.
        Box(
            modifier = Modifier
                .align(panelAlignment)
                .then(panelModifier)
                .onGloballyPositioned { coordinates ->
                    val bounds = coordinates.boundsInRoot()
                    if (animationState.panelBounds?.size != bounds.size) animationState.layerRecorded = false
                    animationState.panelBounds = bounds
                    if (!animationState.expansionStarted && !animationState.closing) {
                        animationState.expansionStarted = true
                        animationScope.launch {
                            withFrameNanos { }
                            if (!animationState.closing) {
                                progress.animateTo(1f,
                                    tween(if (gentleMotion) 260 else GENIE_EXPAND_DURATION_MS,
                                        easing = if (gentleMotion) FastOutSlowInEasing else GenieExpandEasing))
                                if (!animationState.closing) animationState.interactive = true
                            }
                        }
                    }
                },
            propagateMinConstraints = true,
        ) {
            Surface(
                modifier = Modifier
                    .then(if (gentleMotion) Modifier.graphicsLayer {
                        val p = progress.value
                        val panel = animationState.panelBounds
                        val anchor = anchorBounds
                        transformOrigin = if (panel != null && anchor != null && panel.width > 0 && panel.height > 0) {
                            TransformOrigin(
                                ((anchor.center.x - panel.left) / panel.width).coerceIn(0f, 1f),
                                ((anchor.center.y - panel.top) / panel.height).coerceIn(0f, 1f),
                            )
                        } else TransformOrigin.Center
                        alpha = p
                        scaleX = .94f + .06f * p
                        scaleY = scaleX
                    } else Modifier.geniePopupLayer(
                        layer = genieLayer,
                        progress = { progress.value },
                        anchor = { anchorBounds },
                        panel = { animationState.panelBounds },
                        layerRecorded = { animationState.layerRecorded },
                        setLayerRecorded = { animationState.layerRecorded = it },
                        allowAboveAnchor = true,
                    ))
                    // Preserve the original settings-content render boundary beneath the warp.
                    .graphicsLayer {
                        compositingStrategy = CompositingStrategy.Auto
                        alpha = 1f
                        scaleX = 1f
                        scaleY = 1f
                    }
                    .then(if (gentleMotion) Modifier.pointerInput(Unit) {
                        // 开合期间先于子控件消费事件，防止重复触发或收起时误改参数。
                        awaitPointerEventScope {
                            while (true) {
                                val event = awaitPointerEvent(PointerEventPass.Initial)
                                if (!animationState.interactive) event.changes.forEach { it.consume() }
                            }
                        }
                    } else Modifier)
                    .pointerInput(Unit) { detectTapGestures { } },
                shape = shape,
                color = colors.glassSurfaceHeavy,
                border = BorderStroke(1.dp, colors.glassPanelBorder),
                tonalElevation = 6.dp,
            ) {
                Box {
                    Box(
                        modifier = Modifier
                            .matchParentSize()
                            .background(Brush.verticalGradient(listOf(colors.glassSheen, Color.Transparent)))
                    )
                    content(startClose)
                }
            }
        }

        overlayContent()
    }
}
