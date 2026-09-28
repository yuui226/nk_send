package com.ztransfer.ui.screen

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
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

/** Layout only: all camera actions and tool preference mutations remain in RemoteScreen. */
@Composable
internal fun LandscapeMonitorControls(
    layout: LandscapeMonitorLayout,
    tools: List<RemoteTool>,
    onPanelChange: () -> Unit,
    dockButton: @Composable (Boolean, () -> Unit, Modifier) -> Unit,
    rotateButton: @Composable () -> Unit,
    backButton: @Composable () -> Unit,
    dispButton: @Composable () -> Unit,
    shutter: @Composable () -> Unit,
    localRecorder: @Composable () -> Unit,
    parameter: @Composable (Int, Modifier) -> Unit,
    tool: @Composable (RemoteTool) -> Unit,
    modifier: Modifier = Modifier,
) {
    var dockOpen by remember { mutableStateOf(false) }
    var anchor by remember { mutableStateOf<Rect?>(null) }
    // A window/ratio change can detach a menu's old tool anchor. Close that menu before reuse.
    LaunchedEffect(layout) { onPanelChange() }
    fun close() {
        onPanelChange()
        dockOpen = false
    }
    BackHandler(dockOpen) { close() }
    val showParameters = !dockOpen
    val parameterAnimation = rememberGenieVisibility(showParameters)
    val dockAnimation = rememberGenieVisibility(dockOpen)
    val dockSlot: @Composable () -> Unit = {
        dockButton(dockOpen, {
            onPanelChange()
            dockOpen = !dockOpen
        }, Modifier.onGloballyPositioned { anchor = it.boundsInRoot() })
    }
    val header: @Composable () -> Unit = {
        // The caller supplies real bounds wide enough for all navigation hit targets.
        Box(Modifier.fillMaxWidth().height(36.dp), contentAlignment = Alignment.CenterEnd) {
            Row(Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically) {
                dockSlot()
                Spacer(Modifier.weight(1f))
                backButton()
            }
        }
    }
    val content: @Composable () -> Unit = {
        GenieInlinePanel(parameterAnimation, { anchor },
            Modifier.fillMaxSize().blockMonitorPanelInput { !showParameters || parameterAnimation.progress.value < .999f }) {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(if (layout.columns == 1) 2.dp else if (layout.bottomControls) 4.dp else 6.dp, Alignment.CenterVertically)) {
                (0..3).toList().chunked(layout.columns).forEach { indices ->
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        indices.forEach { parameter(it, Modifier.weight(1f)) }
                    }
                }
            }
        }
    }
    // Tool tiles are narrower than parameter wheels, so they have their own column count.
    val dockColumns = ((layout.controls.width - 8f) / 48f).toInt()
        .coerceIn(1, if (layout.bottomControls) Int.MAX_VALUE else 3)
    val dockContent: @Composable () -> Unit = {
        val dockScroll = rememberScrollState()
        GenieInlinePanel(dockAnimation, { anchor },
            Modifier.fillMaxSize().blockMonitorPanelInput { !dockOpen || dockAnimation.progress.value < .999f }) {
            Column(Modifier.fillMaxSize().verticalScrollEdgeFade(dockScroll).verticalScroll(dockScroll).padding(4.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(4.dp)) {
                tools.chunked(dockColumns).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        row.forEach { entry -> key(entry) {
                            Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) { tool(entry) }
                        } }
                        repeat(dockColumns - row.size) { Spacer(Modifier.size(44.dp)) }
                    }
                }
            }
        }
    }
    val captureSlot: @Composable () -> Unit = {
        Box(Modifier.size(layout.shutterSize.dp), contentAlignment = Alignment.Center) {
            val visible = !dockOpen
            AnimatedVisibility(visible, enter = fadeIn(tween(160)), exit = fadeOut(tween(160)),
                modifier = Modifier.blockMonitorPanelInput { !visible }) { shutter() }
        }
    }
    // Horizontal expansion stays in the bottom row, beside rotation.
    val localSlot: @Composable () -> Unit = {
        Box(Modifier.height(36.dp), contentAlignment = Alignment.CenterStart) {
            AnimatedVisibility(!dockOpen, enter = fadeIn(tween(160)), exit = fadeOut(tween(160)),
                modifier = Modifier.blockMonitorPanelInput { dockOpen }) { localRecorder() }
        }
    }
    val dispSlot: @Composable () -> Unit = {
        Box(Modifier.size(36.dp), contentAlignment = Alignment.Center) {
            AnimatedVisibility(!dockOpen, enter = fadeIn(tween(160)), exit = fadeOut(tween(160)),
                modifier = Modifier.blockMonitorPanelInput { dockOpen }) { dispButton() }
        }
    }
    val rotationSlot: @Composable () -> Unit = {
        Box(Modifier.size(36.dp), contentAlignment = Alignment.Center) {
            AnimatedVisibility(!dockOpen, enter = fadeIn(tween(160)), exit = fadeOut(tween(160)),
                modifier = Modifier.blockMonitorPanelInput { dockOpen }) { rotateButton() }
        }
    }
    val captureCluster: @Composable () -> Unit = {
        Box(Modifier.fillMaxWidth().height((layout.footerHeight + layout.captureLift).dp)) {
            Column(Modifier.align(Alignment.BottomStart).padding(start = 4.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp)) {
                dispSlot()
                rotationSlot()
            }
            Box(Modifier.align(if (!layout.bottomControls && layout.columns == 2)
                Alignment.TopCenter else Alignment.TopEnd)) { captureSlot() }
            Box(Modifier.align(Alignment.BottomStart).padding(start = 44.dp)) { localSlot() }
        }
    }
    if (layout.bottomControls) {
        Box(modifier) {
            Row(Modifier.fillMaxSize().padding(top = 40.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f).fillMaxHeight()) { content() }
                Box(Modifier.width(maxOf(116f, layout.shutterSize + 52f).dp)) { captureCluster() }
            }
            Box(Modifier.fillMaxSize().padding(top = 40.dp)) { dockContent() }
            header()
        }
    } else {
        Box(modifier) {
            Column(Modifier.align(Alignment.TopEnd).width(layout.controls.width.dp).fillMaxHeight(),
                verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Spacer(Modifier.height(36.dp))
                Box(Modifier.weight(1f).fillMaxWidth()) { content() }
                // Capture shares the bottom row with DISP; it never takes a wheel row.
                Spacer(Modifier.height((layout.footerHeight + layout.captureLift).dp))
            }
            Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth()) { captureCluster() }
            // Dock owns all space below navigation, including the capture/recorder footer.
            Box(Modifier.align(Alignment.TopEnd).width(layout.controls.width.dp)
                .fillMaxHeight().padding(top = 40.dp)) { dockContent() }
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
