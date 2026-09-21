package com.ztransfer.ui.screen

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.ztransfer.R
import com.ztransfer.ui.theme.AppTheme
import kotlinx.coroutines.delay

/** An in-page modal, so it follows the monitor's internal rotation and safe bounds. */
@Composable
internal fun RemoteToolManager(
    preferences: RemoteToolPreferences,
    busy: Set<RemoteTool>,
    onVisible: (RemoteTool, Boolean) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = AppTheme.colors
    val list = rememberLazyListState()
    val edgePx = with(LocalDensity.current) { 48.dp.toPx() }
    val paneName = stringResource(R.string.remote_tool_manage)
    var dragging by remember { mutableStateOf<RemoteTool?>(null) }
    var dragCenter by remember { mutableFloatStateOf(0f) }
    val currentBusy by rememberUpdatedState(busy)
    fun moveAtPointer() {
        val dragged = dragging ?: return
        val target = list.layoutInfo.visibleItemsInfo.firstOrNull {
            dragCenter >= it.offset && dragCenter < it.offset + it.size &&
                preferences.order.any { tool -> tool.id == it.key }
        } ?: return
        val targetIndex = preferences.order.indexOfFirst { it.id == target.key }
        if (targetIndex >= 0 && preferences.order.indexOf(dragged) != targetIndex) {
            preferences.move(dragged, targetIndex)
        }
    }
    LaunchedEffect(dragging) {
        while (dragging != null) {
            val info = list.layoutInfo
            val edge = edgePx
            val delta = when {
                dragCenter < info.viewportStartOffset + edge -> -12f
                dragCenter > info.viewportEndOffset - edge -> 12f
                else -> 0f
            }
            if (delta != 0f) { list.scrollBy(delta); moveAtPointer() }
            delay(16)
        }
    }
    BackHandler(onBack = onDismiss)
    Box(Modifier.fillMaxSize().semantics { paneTitle = paneName }, contentAlignment = Alignment.Center) {
        Box(Modifier.fillMaxSize().background(colors.scrim).clickable(
            interactionSource = remember { MutableInteractionSource() }, indication = null,
            onClick = onDismiss,
        ))
        Surface(
            modifier = Modifier.padding(20.dp).widthIn(max = 420.dp).fillMaxWidth().fillMaxHeight(0.88f),
            shape = RoundedCornerShape(24.dp), color = colors.glassSurfaceHeavy,
            shadowElevation = 6.dp,
        ) {
            Column {
                Row(Modifier.fillMaxWidth().padding(start = 22.dp, end = 10.dp, top = 8.dp, bottom = 4.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.remote_tool_manage), style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold, color = colors.onBackground, modifier = Modifier.weight(1f))
                    IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, stringResource(R.string.cd_close), tint = colors.onSurfaceVariant) }
                }
                LazyColumn(state = list, modifier = Modifier.weight(1f), contentPadding = PaddingValues(10.dp)) {
                    items(preferences.order + RemoteTool.entries.filter { it.fixed }, key = { it.id }) { tool ->
                        val visible = preferences.visible(tool)
                        val fixedText = stringResource(R.string.remote_tool_fixed)
                        val title = stringResource(tool.title)
                        val visibilityText = stringResource(if (visible) R.string.remote_tool_show else R.string.remote_tool_hide)
                        val moveUp = stringResource(R.string.remote_tool_move_up)
                        val moveDown = stringResource(R.string.remote_tool_move_down)
                        val item = list.layoutInfo.visibleItemsInfo.firstOrNull { it.key == tool.id }
                        val isDragging = dragging == tool
                        Row(
                            Modifier.fillMaxWidth().zIndex(if (isDragging) 1f else 0f)
                                .graphicsLayer { translationY = if (isDragging && item != null) dragCenter - item.offset - item.size / 2f else 0f }
                                .background(if (isDragging) colors.surface else androidx.compose.ui.graphics.Color.Transparent, RoundedCornerShape(14.dp))
                                .heightIn(min = 60.dp), verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Row(Modifier.weight(1f).clickable(enabled = tool !in busy && dragging == null,
                                role = Role.Switch) { onVisible(tool, !visible) }
                                .semantics { stateDescription = visibilityText }
                                .padding(vertical = 8.dp, horizontal = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                                CompositionLocalProvider(LocalContentColor provides if (visible) colors.accentBlue else colors.onSurfaceVariant.copy(alpha = 0.5f)) {
                                    Box(Modifier.size(38.dp).background(if (visible) colors.accentBlue.copy(alpha = 0.10f) else colors.onSurfaceVariant.copy(alpha = 0.04f), CircleShape), contentAlignment = Alignment.Center) {
                                        RemoteToolMark(tool, preferences)
                                    }
                                }
                                Spacer(Modifier.width(14.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(title, style = MaterialTheme.typography.bodyMedium,
                                        color = if (visible) colors.onBackground else colors.onSurfaceVariant)
                                    if (tool.fixed) Text(fixedText, style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
                                }
                                if (tool in busy) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                            }
                            if (!tool.fixed) {
                                Box(Modifier.size(44.dp).semantics {
                                    customActions = listOf(
                                        CustomAccessibilityAction(moveUp) { preferences.move(tool, preferences.order.indexOf(tool) - 1); true },
                                        CustomAccessibilityAction(moveDown) { preferences.move(tool, preferences.order.indexOf(tool) + 1); true },
                                    )
                                }.pointerInput(tool) {
                                    detectDragGestures(
                                        onDragStart = {
                                            if (tool !in currentBusy) {
                                                list.layoutInfo.visibleItemsInfo.firstOrNull { it.key == tool.id }?.let { row ->
                                                    dragCenter = row.offset + row.size / 2f
                                                    dragging = tool
                                                }
                                            }
                                        },
                                        onDragEnd = { dragging = null }, onDragCancel = { dragging = null },
                                    ) { change, amount ->
                                        if (dragging == tool) { change.consume(); dragCenter += amount.y; moveAtPointer() }
                                    }
                                }, contentAlignment = Alignment.Center) {
                                    Icon(Icons.Default.DragHandle, title, tint = colors.onSurfaceVariant.copy(alpha = 0.55f), modifier = Modifier.size(20.dp))
                                }
                            } else Spacer(Modifier.width(44.dp))
                        }
                    }
                }
            }
        }
    }
}
