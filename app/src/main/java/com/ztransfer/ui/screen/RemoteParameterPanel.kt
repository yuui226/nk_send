package com.ztransfer.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ztransfer.protocol.RcParam
import com.ztransfer.protocol.rcFormat
import com.ztransfer.ui.theme.AppTheme

@Composable
internal fun RemoteParameterPanel(param: RcParam, anchor: Rect?, landscape: Boolean,
    onSelect: (Long) -> Unit, onDismiss: () -> Unit) {
    val colors = AppTheme.colors
    val labels = remember(param.prop, param.values) { param.values.associateWith { rcFormat(param.prop, it) } }
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val style = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    val width = with(density) { (labels.values.maxOfOrNull { measurer.measure(it, style).size.width } ?: 0).toDp() } + 28.dp
    val state = rememberLazyListState(initialFirstVisibleItemIndex =
        (param.values.indexOf(param.current) - 3).coerceAtLeast(0))
    RemoteChoicePopup(anchor, landscape, width.coerceIn(64.dp, 220.dp), false, onDismiss,
        besideAnchor = landscape) { close, closing ->
        LazyColumn(state = state, modifier = Modifier.weight(1f, fill = false)) {
            items(param.values) { value ->
                val selected = value == param.current
                Text(labels.getValue(value), style = style,
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                    color = if (selected) colors.accentBlue else colors.onBackground,
                    textAlign = TextAlign.Center, maxLines = 1,
                    modifier = Modifier.fillMaxWidth()
                        .background(if (selected) colors.accentBlue.copy(alpha = .08f) else Color.Transparent)
                        .clickable(enabled = !closing) { onSelect(value); close() }
                        .padding(horizontal = 14.dp, vertical = 8.dp))
            }
        }
    }
}
