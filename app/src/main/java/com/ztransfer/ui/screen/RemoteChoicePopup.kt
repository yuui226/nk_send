package com.ztransfer.ui.screen

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.AppTheme
import kotlinx.coroutines.launch

private class ChoicePopupGeometry {
    var bounds: Rect? = null
    var recorded = false
}

/** Same genie renderer as Settings, positioned in the monitor's local (possibly rotated) host. */
@Composable
internal fun RemoteChoicePopup(
    anchor: Rect?, landscape: Boolean, width: Dp, closeRequested: Boolean,
    onDismiss: () -> Unit,
    content: @Composable ColumnScope.(close: () -> Unit, closing: Boolean) -> Unit,
) {
    val progress=remember { Animatable(0f) }
    val geometry=remember { ChoicePopupGeometry() }
    val layer=rememberGraphicsLayer()
    val scope=rememberCoroutineScope()
    var closing by remember { mutableStateOf(false) }
    val latestDismiss by rememberUpdatedState(onDismiss)
    val close: () -> Unit = {
        if(!closing) {
            closing=true
            scope.launch {
                progress.animateTo(0f,tween((GENIE_COLLAPSE_DURATION_MS*progress.value).toInt().coerceAtLeast(1),easing=GenieCollapseEasing))
                latestDismiss()
            }
        }
    }
    LaunchedEffect(Unit) {
        withFrameNanos { }
        if(!closing) progress.animateTo(1f,tween(GENIE_EXPAND_DURATION_MS,easing=GenieExpandEasing))
    }
    LaunchedEffect(closeRequested) { if(closeRequested) close() }
    BackHandler { close() }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density=LocalDensity.current
        val gap=6.dp
        val margin=8.dp
        val top=with(density) { (anchor?.top ?: 0f).toDp() }
        val bottom=with(density) { (anchor?.bottom ?: 0f).toDp() }
        val available=(if(landscape) top-gap-margin else maxHeight-bottom-gap-margin).coerceAtLeast(1.dp)
        val menuWidth=width.coerceAtMost((maxWidth-margin*2).coerceAtLeast(1.dp))
        Box(Modifier.matchParentSize().clickable(
            interactionSource=remember { MutableInteractionSource() },indication=null,onClick=close)
            .pointerInput(Unit) { detectDragGestures { change, _ -> change.consume() } })
        Layout(content={
            Column(Modifier.width(menuWidth).heightIn(max=available)
                .geniePopupLayer(layer,{progress.value},{anchor},{geometry.bounds},
                    {geometry.recorded},{geometry.recorded=it},allowAboveAnchor=true)
                .clip(RoundedCornerShape(12.dp)).background(AppTheme.colors.surface)
                .clickable(interactionSource=remember { MutableInteractionSource() },indication=null) { }
                .padding(vertical=4.dp)) { content(close,closing) }
        },modifier=Modifier.fillMaxSize()) { measurables,constraints ->
            val panel=measurables.single().measure(constraints.copy(minWidth=0,minHeight=0))
            val inset=margin.roundToPx()
            val left=(anchor?.left?.toInt() ?: inset).coerceIn(inset,(constraints.maxWidth-panel.width-inset).coerceAtLeast(inset))
            val desiredTop=if(landscape) (anchor?.top?.toInt() ?: constraints.maxHeight)-gap.roundToPx()-panel.height
                else (anchor?.bottom?.toInt() ?: inset)+gap.roundToPx()
            val y=desiredTop.coerceIn(0,(constraints.maxHeight-panel.height).coerceAtLeast(0))
            val bounds=Rect(left.toFloat(),y.toFloat(),(left+panel.width).toFloat(),(y+panel.height).toFloat())
            if(geometry.bounds!=bounds) geometry.recorded=false
            geometry.bounds=bounds
            layout(constraints.maxWidth,constraints.maxHeight) { panel.place(left,y) }
        }
    }
}
