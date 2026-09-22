package com.ztransfer.ui.screen

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.layout.layoutId
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.ztransfer.R
import com.ztransfer.ui.theme.AppTheme

/** Coordinates are local to the toolbar, independent of the screen's internal rotation. */
private class ToolDragState {
    val slots = mutableStateMapOf<String, Rect>()
    val visualPositions = mutableMapOf<String, () -> Offset>()
    var dragging by mutableStateOf<RemoteTool?>(null)
    var topLeft by mutableStateOf(Offset.Zero)
    fun visualBounds(tool: RemoteTool): Rect? = slots[tool.id]?.let {
        Rect(visualPositions[tool.id]?.invoke() ?: it.topLeft, it.size)
    }
    fun moveBy(delta: Offset, tools: RemoteToolLayout) {
        val tool = dragging ?: return
        topLeft += delta
        val size = slots[tool.id]?.size ?: return
        val center = topLeft + Offset(size.width / 2, size.height / 2)
        // Use destination slots, not the animated neighbours, to avoid oscillating as they yield.
        val target = tools.shownTools.firstOrNull { other ->
            other != tool && slots[other.id]?.contains(center) == true
        } ?: return
        val displayedOrder = tools.shownTools.sortedWith(compareBy<RemoteTool>(
            { slots[it.id]?.top ?: Float.MAX_VALUE }, { slots[it.id]?.left ?: Float.MAX_VALUE }))
        tools.move(tool, tools.shownTools.indexOf(target), displayedOrder)
    }
}

/** Keep the mode effect's captures small; share the screen's normal hide/stop path. */
@Composable
internal fun ApplyRemoteToolLayout(layout: RemoteToolLayout, onVisible: (RemoteTool, Boolean) -> Unit) {
    val currentOnVisible by rememberUpdatedState(onVisible)
    LaunchedEffect(layout) {
        layout.hiddenTools.forEach { currentOnVisible(it, false) }
    }
}

/** Same wrapping toolbar in normal and edit modes; no modal, list or scrolling surface. */
@Composable
internal fun RemoteToolBar(
    tools: RemoteToolPreferences,
    editing: Boolean,
    movie: Boolean,
    onVisible: (RemoteTool, Boolean) -> Unit,
    modifier: Modifier = Modifier,
    gap: Dp = 6.dp,
    leading: @Composable () -> Unit = {},
    button: @Composable (RemoteTool?) -> Unit,
) {
    val dragState = remember { ToolDragState() }
    val layout = tools.layout(movie)
    val currentLayout by rememberUpdatedState(layout)
    val secondRowLock = layout.lockStartsSecondRow
    val sequence = layout.shownTools + (if (editing) layout.hiddenTools else emptyList())
    val endTools = listOf(RemoteTool.FULLSCREEN, RemoteTool.ROTATE)
    val gesture = if (!editing) Modifier else Modifier.pointerInput(dragState, layout) {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            val tool = currentLayout.shownTools.firstOrNull {
                dragState.visualBounds(it)?.contains(down.position) == true
            } ?: return@awaitEachGesture
            val origin = dragState.visualBounds(tool)?.topLeft ?: return@awaitEachGesture
            val start = awaitTouchSlopOrCancellation(down.id) { change, _ -> change.consume() }
                ?: return@awaitEachGesture // A tap is handled by the entire button.
            dragState.dragging = tool
            dragState.topLeft = origin
            dragState.moveBy(start.position - down.position, currentLayout)
            try {
                drag(start.id) { change ->
                    dragState.moveBy(change.positionChange(), currentLayout)
                    change.consume()
                }
            } finally { dragState.dragging = null }
        }
    }
    DisposableEffect(editing, layout) {
        onDispose { dragState.dragging = null }
    }
    AdaptiveRemoteToolBar(
        modifier.animateContentSize(tween(220)).then(gesture),
        horizontalGap = gap, verticalGap = 4.dp, pinnedEndCount = endTools.size,
        secondRowFirstId = if (secondRowLock) RemoteTool.LOCK.id else null,
    ) {
        leading()
        (sequence + listOf(null) + endTools).forEach { tool ->
            val id = tool?.id ?: "manage"
            key(id) {
                AnimatedToolSlot(id, tool, editing, layout.visibleOrManager(tool), dragState) {
                    if (editing && tool != null && !tool.fixed) {
                        val visible = layout.visible(tool)
                        val title = stringResource(tool.title)
                        val stateLabel = stringResource(if (visible) R.string.remote_tool_show else R.string.remote_tool_hide)
                        val up = stringResource(R.string.remote_tool_move_up)
                        val down = stringResource(R.string.remote_tool_move_down)
                        val iconOpacity = animateFloatAsState(if (visible) 1f else 0.38f, tween(180), label = "toolIconOpacity-$id")
                        Box {
                            TopIconToggle(visible, title, { onVisible(tool, !layout.visible(tool)) },
                                modifier = Modifier.semantics {
                                    stateDescription = stateLabel
                                    if (visible) customActions = listOf(
                                        CustomAccessibilityAction(up) { layout.move(tool, layout.shownTools.indexOf(tool) - 1); true },
                                        CustomAccessibilityAction(down) { layout.move(tool, layout.shownTools.indexOf(tool) + 1); true },
                                    )
                                }) {
                                    Box(Modifier.graphicsLayer { alpha = iconOpacity.value }) {
                                        RemoteToolMark(tool, tools)
                                    }
                                }
                            val colors = AppTheme.colors
                            Icon(if (visible) Icons.Outlined.Visibility else Icons.Outlined.VisibilityOff,
                                contentDescription = null, tint = colors.onBackground,
                                modifier = Modifier.align(Alignment.TopEnd).offset(x = 2.dp, y = (-2).dp)
                                    .size(14.dp).background(colors.surface, CircleShape).padding(1.dp))
                        }
                    } else button(tool)
                }
            }
        }
    }
}

private fun RemoteToolLayout.visibleOrManager(tool: RemoteTool?) = tool == null || visible(tool)

@Composable
private fun AnimatedToolSlot(
    id: String, tool: RemoteTool?, editing: Boolean, visible: Boolean,
    state: ToolDragState, content: @Composable () -> Unit,
) {
    val slot = state.slots[id]
    val dragging = tool != null && state.dragging == tool
    val position = if (slot != null) animateOffsetAsState(
        if (dragging) state.topLeft else slot.topLeft,
        animationSpec = if (dragging) snap() else spring(dampingRatio = 0.86f, stiffness = 500f),
        label = "toolPosition-$id",
    ) else null
    val scale = animateFloatAsState(if (dragging) 1.10f else 1f, tween(120), label = "toolLift-$id")
    val wiggle = if (editing && visible && tool != null && !tool.fixed && !dragging) {
        val transition = rememberInfiniteTransition(label = "toolEdit-$id")
        transition.animateFloat(-1.3f, 1.3f,
            infiniteRepeatable(tween(160, easing = LinearEasing), RepeatMode.Reverse,
                initialStartOffset = StartOffset((tool.ordinal % 3) * 55)), label = "toolWiggle-$id")
    } else null
    SideEffect { state.visualPositions[id] = { position?.value ?: state.slots[id]?.topLeft ?: Offset.Zero } }
    DisposableEffect(id) {
        onDispose { state.slots.remove(id); state.visualPositions.remove(id) }
    }
    Box(Modifier.layoutId(id).onPlaced { coordinates ->
        val bounds = Rect(coordinates.positionInParent(), Size(coordinates.size.width.toFloat(), coordinates.size.height.toFloat()))
        if (state.slots[id] != bounds) state.slots[id] = bounds
    }.zIndex(if (dragging) 1f else 0f).graphicsLayer {
        val base = state.slots[id]?.topLeft ?: Offset.Zero
        val animated = position?.value ?: base
        translationX = animated.x - base.x
        translationY = animated.y - base.y
        rotationZ = wiggle?.value ?: 0f
        scaleX = scale.value
        scaleY = scale.value
    }) { content() }
}
