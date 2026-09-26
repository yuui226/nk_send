package com.ztransfer.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.AppTheme

internal val framingGridOptions = listOf(
    ViewfinderGrid.OFF, ViewfinderGrid.THIRDS, ViewfinderGrid.THIRDS_DIAGONALS,
    ViewfinderGrid.FOURTHS, ViewfinderGrid.FOURTHS_DIAGONALS, ViewfinderGrid.CENTER,
    ViewfinderGrid.GOLDEN, ViewfinderGrid.WIDE_235, ViewfinderGrid.WIDE_169, ViewfinderGrid.FRAME_43,
)

@Composable
internal fun RemoteGridPanel(grid: ViewfinderGrid, anchor: Rect?, landscape: Boolean,
    closeRequested: Boolean, onSelect: (ViewfinderGrid) -> Unit, onDismiss: () -> Unit) {
    val colors=AppTheme.colors
    val labels=framingGridOptions.associateWith { stringResource(it.labelRes) }
    val measurer=rememberTextMeasurer()
    val density=LocalDensity.current
    val style=MaterialTheme.typography.bodyMedium
    val width=with(density) { labels.values.maxOf { measurer.measure(it,style).size.width }.toDp() }+24.dp
    RemoteChoicePopup(anchor,landscape,width.coerceIn(48.dp,280.dp),closeRequested,onDismiss) { close,closing ->
        LazyColumn(Modifier.weight(1f,fill=false)) {
            items(framingGridOptions,key={it.name}) { option ->
                val selected=option==grid
                Text(labels.getValue(option),color=if(selected) colors.accentBlue else colors.onBackground,
                    style=style,modifier=Modifier.fillMaxWidth()
                        .background(if(selected) colors.accentBlue.copy(alpha=.08f) else Color.Transparent)
                        .selectable(selected,enabled=!closing,role=Role.RadioButton) { onSelect(option);close() }
                        .padding(horizontal=12.dp,vertical=8.dp))
            }
        }
    }
}
