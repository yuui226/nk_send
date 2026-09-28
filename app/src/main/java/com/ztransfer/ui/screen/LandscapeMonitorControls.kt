package com.ztransfer.ui.screen

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.AppTheme

/** Layout only: all camera actions and tool preference mutations remain in RemoteScreen. */
@Composable
internal fun LandscapeMonitorControls(
    layout: LandscapeMonitorLayout,
    tools: List<RemoteTool>,
    cameraRecording: Boolean,
    localRecording: Boolean,
    onPanelChange: () -> Unit,
    dockButton: @Composable (Boolean, () -> Unit, Modifier) -> Unit,
    parameterButton: @Composable (Boolean, () -> Unit) -> Unit,
    rotateButton: @Composable () -> Unit,
    backButton: @Composable () -> Unit,
    dispButton: @Composable () -> Unit,
    shutter: @Composable () -> Unit,
    localStop: @Composable () -> Unit,
    parameter: @Composable (Int, Modifier) -> Unit,
    tool: @Composable (RemoteTool) -> Unit,
    modifier: Modifier = Modifier,
) {
    val overlay = layout.placement == MonitorControlPlacement.OVERLAY
    val bottom = layout.placement == MonitorControlPlacement.BOTTOM
    var dockOpen by remember(layout.placement) { mutableStateOf(false) }
    var parametersOpen by remember(layout.placement) { mutableStateOf(!overlay) }
    var anchor by remember { mutableStateOf<Rect?>(null) }
    // A window/ratio change can detach a menu's old tool anchor. Close that menu before reuse.
    LaunchedEffect(layout) { onPanelChange() }
    fun close() {
        onPanelChange()
        dockOpen = false
        parametersOpen = !overlay
    }
    BackHandler(dockOpen || (overlay && parametersOpen)) { close() }
    val showParameters = parametersOpen && !dockOpen
    val parameterAnimation = rememberGenieVisibility(showParameters)
    val dockAnimation = rememberGenieVisibility(dockOpen)
    val panelSurface = if (overlay) Modifier.background(
        AppTheme.colors.background.copy(alpha = .92f), RoundedCornerShape(20.dp)
    ) else Modifier
    val dockSlot: @Composable () -> Unit = {
        dockButton(dockOpen, {
            onPanelChange()
            dockOpen = !dockOpen
            parametersOpen = !overlay
        }, Modifier.onGloballyPositioned { anchor = it.boundsInRoot() })
    }
    val parameterEntry: @Composable () -> Unit = {
        if (overlay && !dockOpen) parameterButton(parametersOpen) {
            onPanelChange()
            parametersOpen = !parametersOpen
        }
    }
    val header: @Composable () -> Unit = {
        // The caller supplies real bounds wide enough for all navigation hit targets.
        Box(Modifier.fillMaxWidth().height(40.dp), contentAlignment = Alignment.CenterEnd) {
            Row(Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically) {
                rotateButton()
                Spacer(Modifier.width(4.dp))
                dockSlot()
                if (overlay) Box(Modifier.size(40.dp), contentAlignment = Alignment.Center) { parameterEntry() }
                Spacer(Modifier.weight(1f))
                backButton()
            }
        }
    }
    val content: @Composable () -> Unit = {
        Box(Modifier.fillMaxSize()) {
            GenieInlinePanel(parameterAnimation, { anchor },
                Modifier.fillMaxSize().blockMonitorPanelInput { !showParameters || parameterAnimation.progress.value < .999f }) {
                Box(Modifier.fillMaxSize().then(panelSurface)) {
                if (bottom) {
                    // Narrow square windows still need readable wheel widths.
                    val parameterColumns = if (layout.controls.width - 140f >= 338f) 4 else 2
                    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically)) {
                        (0..3).toList().chunked(parameterColumns).forEach { row ->
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                row.forEach { parameter(it, Modifier.weight(1f)) }
                            }
                        }
                    }
                } else {
                    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically)) {
                        (0..3).toList().chunked(layout.columns).forEach { indices ->
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                indices.forEach { parameter(it, Modifier.weight(1f)) }
                            }
                        }
                    }
                }
                }
            }
            GenieInlinePanel(dockAnimation, { anchor },
                Modifier.fillMaxSize().blockMonitorPanelInput { !dockOpen || dockAnimation.progress.value < .999f }) {
                Box(Modifier.fillMaxSize().then(panelSurface)) {
                if (bottom) {
                    Row(Modifier.fillMaxSize().horizontalScroll(rememberScrollState()).padding(4.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        tools.chunked(2).forEach { column ->
                            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                column.forEach { entry -> key(entry) { Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) { tool(entry) } } }
                            }
                        }
                    }
                } else {
                    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(4.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        tools.chunked(layout.columns).forEach { row ->
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                                row.forEach { entry -> key(entry) { Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) { tool(entry) } } }
                                if (row.size < layout.columns) Spacer(Modifier.size(44.dp))
                            }
                        }
                    }
                }
                }
            }
        }
    }
    val captureSlot: @Composable () -> Unit = {
        Box(Modifier.size(layout.shutterSize.dp), contentAlignment = Alignment.Center) {
            val visible = !dockOpen || cameraRecording
            AnimatedVisibility(visible, enter = fadeIn(tween(160)), exit = fadeOut(tween(160)),
                modifier = Modifier.blockMonitorPanelInput { !visible }) { shutter() }
        }
    }
    val localSlot: @Composable () -> Unit = {
        Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) { if (localRecording) localStop() }
    }
    val dispSlot: @Composable () -> Unit = {
        Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) {
            AnimatedVisibility(!dockOpen, enter = fadeIn(tween(160)), exit = fadeOut(tween(160)),
                modifier = Modifier.blockMonitorPanelInput { dockOpen }) { dispButton() }
        }
    }
    if (bottom) {
        Row(modifier, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.weight(1f).fillMaxHeight()) { content() }
            Column(Modifier.width(132.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                header()
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceEvenly) { captureSlot(); dispSlot() }
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) { localSlot() }
            }
        }
    } else {
        Box(modifier) {
            Column(Modifier.align(Alignment.TopEnd).width(layout.controls.width.dp).fillMaxHeight(),
                verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Spacer(Modifier.height(40.dp))
                Box(Modifier.weight(1f).fillMaxWidth()) { content() }
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { captureSlot() }
                if (layout.controls.width >= 132f) {
                    Box(Modifier.fillMaxWidth().height(44.dp)) {
                        Box(Modifier.align(Alignment.Center)) { dispSlot() }
                        Box(Modifier.align(Alignment.CenterEnd)) { localSlot() }
                    }
                } else {
                    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                        dispSlot()
                        localSlot()
                    }
                }
            }
            header()
        }
    }
}

/** Prevent outgoing/cached animation surfaces from activating controls or focusing behind them. */
private fun Modifier.blockMonitorPanelInput(blocked: () -> Boolean) = composed {
    val currentBlocked by rememberUpdatedState(blocked)
    pointerInput(Unit) {
        awaitPointerEventScope {
            while (true) {
                val event = awaitPointerEvent(PointerEventPass.Initial)
                if (currentBlocked()) event.changes.forEach { it.consume() }
            }
        }
    }
}
