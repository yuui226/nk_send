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
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
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

@Composable
fun AnchorPopup(
    anchorBounds: Rect?,
    onDismiss: () -> Unit,
    panelModifier: Modifier,
    panelAlignment: Alignment = Alignment.TopStart,
    animateScale: Boolean = true,
    genieFromAnchor: Boolean = false,
    shape: Shape = RoundedCornerShape(20.dp),
    // 遮罩是否压暗背景：大面板（设置）保持压暗聚焦；小面板（筛选下拉）传 false——
    // 全屏变暗对几个胶囊的下拉太兴师动众，遮罩仍在（点外部收起、拦滚动穿透），只是透明。
    dim: Boolean = true,
    overlayContent: @Composable BoxScope.() -> Unit = {},
    content: @Composable BoxScope.(close: () -> Unit) -> Unit
) {
    SharedAnchorPopup(
        anchorBounds = anchorBounds, onDismiss = onDismiss, panelModifier = panelModifier,
        panelAlignment = panelAlignment, animateScale = animateScale, shape = shape, dim = dim,
        genieFromAnchor = genieFromAnchor,
        overlayContent = overlayContent, content = content,
        backHandler = { close -> BackHandler(onBack = close) },
    )
}
