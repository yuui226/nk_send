package com.ztransfer.ui.screen

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.rememberTextMeasurer

internal val MonitorToolLabelStyle = TextStyle(
    fontSize = 10.sp, lineHeight = 12.sp, fontWeight = FontWeight.Medium,
    textAlign = TextAlign.Center,
)

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
    tool: @Composable (RemoteTool, Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    var dockOpen by remember { mutableStateOf(false) }
    // A window/ratio change can detach a menu's old tool anchor. Close that menu before reuse.
    LaunchedEffect(layout) { onPanelChange() }
    fun close() {
        onPanelChange()
        dockOpen = false
    }
    BackHandler(dockOpen) { close() }
    // One signed progress: controls fade to zero before Dock gains any opacity.
    // Reversing cancels only the current animation, retaining its exact visual progress.
    val panelProgress = remember { Animatable(-1f) }
    LaunchedEffect(dockOpen) {
        panelProgress.animateTo(if (dockOpen) 1f else -1f,
            tween(280, easing = FastOutSlowInEasing))
    }
    val dockSlot: @Composable () -> Unit = {
        dockButton(dockOpen, {
            onPanelChange()
            dockOpen = !dockOpen
        }, Modifier)
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
        MonitorDockLayer(panelProgress, dock = false,
            Modifier.fillMaxSize().blockMonitorPanelInput { dockOpen }) {
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
    val dockContent: @Composable () -> Unit = {
        val dockScroll = rememberScrollState()
        MonitorDockLayer(panelProgress, dock = true,
            Modifier.fillMaxSize().blockMonitorPanelInput { !dockOpen }) {
            BoxWithConstraints(Modifier.fillMaxSize().padding(horizontal = 4.dp)) {
                val density = LocalDensity.current
                val measurer = rememberTextMeasurer()
                val names = tools.map { stringResource(it.title) }
                val widthPx = with(density) { maxWidth.roundToPx() }
                val gapPx = with(density) { 8.dp.roundToPx() }
                val minCellPx = with(density) { 56.dp.roundToPx() }
                // Resolve wrapping before the shared reveal animation; never resize from onTextLayout.
                val measurements = remember(names, widthPx, density.density, density.fontScale, layout.bottomControls, measurer) {
                    val wordWidth = names.flatMap { it.split(' ', '-') }.maxOfOrNull { word ->
                        // Keep English words intact; CJK names may wrap between characters.
                        if (word.any { it in 'A'..'Z' || it in 'a'..'z' })
                            measurer.measure(word, MonitorToolLabelStyle, softWrap = false).size.width else 0
                    } ?: 0
                    val maxColumns = if (layout.bottomControls)
                        ((widthPx + gapPx) / (maxOf(minCellPx, wordWidth) + gapPx))
                            .coerceIn(1, tools.size.coerceAtLeast(1))
                    else 3
                    val columns = (maxColumns downTo 1).first { count ->
                        val cell = ((widthPx - gapPx * (count - 1)) / count).coerceAtLeast(1)
                        count == 1 || (cell >= maxOf(minCellPx, wordWidth) && names.all { name ->
                            !measurer.measure(name, MonitorToolLabelStyle, maxLines = 2,
                                constraints = Constraints(maxWidth = cell)).hasVisualOverflow
                        })
                    }
                    val cell = ((widthPx - gapPx * (columns - 1)) / columns).coerceAtLeast(1)
                    val lines = names.map { name ->
                        measurer.measure(name, MonitorToolLabelStyle, maxLines = 2,
                            constraints = Constraints(maxWidth = cell)).lineCount.coerceIn(1, 2)
                    }
                    columns to lines
                }
                val columns = measurements.first
                Column(Modifier.fillMaxSize().verticalScrollEdgeFade(dockScroll)
                    .verticalScroll(dockScroll).padding(vertical = 4.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    tools.chunked(columns).forEachIndexed { rowIndex, row ->
                        val lines = measurements.second.drop(rowIndex * columns).take(row.size).maxOrNull() ?: 1
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            row.forEach { entry -> key(entry) {
                                Box(Modifier.weight(1f), contentAlignment = Alignment.TopCenter) { tool(entry, lines) }
                            } }
                            repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
                        }
                    }
                }
            }
        }
    }
    val captureSlot: @Composable () -> Unit = {
        Box(Modifier.size(layout.shutterSize.dp), contentAlignment = Alignment.Center) {
            MonitorDockLayer(panelProgress, dock = false,
                Modifier.blockMonitorPanelInput { dockOpen }) { shutter() }
        }
    }
    // Horizontal expansion stays in the bottom row, beside rotation.
    val localSlot: @Composable () -> Unit = {
        Box(Modifier.height(36.dp), contentAlignment = Alignment.CenterStart) {
            MonitorDockLayer(panelProgress, dock = false,
                Modifier.blockMonitorPanelInput { dockOpen }) { localRecorder() }
        }
    }
    val dispSlot: @Composable () -> Unit = {
        Box(Modifier.size(36.dp), contentAlignment = Alignment.Center) {
            MonitorDockLayer(panelProgress, dock = false,
                Modifier.blockMonitorPanelInput { dockOpen }) { dispButton() }
        }
    }
    val rotationSlot: @Composable () -> Unit = {
        Box(Modifier.size(36.dp), contentAlignment = Alignment.Center) {
            MonitorDockLayer(panelProgress, dock = false,
                Modifier.blockMonitorPanelInput { dockOpen }) { rotateButton() }
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

/** Only the zero crossing changes composition; animation frames update the graphics layer. */
@Composable
private fun MonitorDockLayer(
    progress: Animatable<Float, androidx.compose.animation.core.AnimationVector1D>,
    dock: Boolean,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val present by remember(progress, dock) {
        derivedStateOf { if (dock) progress.value > 0f else progress.value < 0f }
    }
    val travel = with(LocalDensity.current) { 4.dp.toPx() }
    if (present) {
        Box(modifier.graphicsLayer {
            val visibility = (if (dock) progress.value else -progress.value).coerceIn(0f, 1f)
            alpha = visibility
            translationY = (1f - visibility) * travel
        }) { content() }
    }
}
