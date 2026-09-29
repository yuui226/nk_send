package com.ztransfer.ui.screen

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.lut.LutFolderFailure
import com.ztransfer.lut.LutMonitorState
import com.ztransfer.lut.folderMessage
import com.ztransfer.ui.theme.AppTheme

@Composable
internal fun RemoteLutPanel(state: LutMonitorState, anchor: Rect?, landscape: Boolean,
    onFolder: () -> Unit, onFeedback: () -> Unit) {
    val colors = AppTheme.colors
    val style = MaterialTheme.typography.bodyMedium
    val off = stringResource(R.string.lut_off)
    val folderLabel = stringResource(if (state.folder == null || state.folderFailure == LutFolderFailure.MISSING || state.folderFailure == LutFolderFailure.DENIED) R.string.lut_choose_folder else R.string.lut_change_folder)
    val guidance = when {
        state.folder == null -> stringResource(R.string.lut_choose_hint)
        state.folderFailure != null -> stringResource(folderMessage(state.folderFailure!!))
        state.scanning && state.files.isEmpty() -> stringResource(R.string.lut_reading_folder)
        state.files.isEmpty() -> stringResource(R.string.lut_folder_empty)
        else -> null
    }
    val accessible = state.folderFailure != LutFolderFailure.MISSING && state.folderFailure != LutFolderFailure.DENIED
    RemoteChoicePopup(anchor, landscape, if (state.files.isEmpty()) 260.dp else 320.dp,
        state.closeMenuRequested, state::dismissMenu) { _, closing ->
        if (guidance != null) {
            Text(guidance, color = colors.onSurfaceVariant, style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(12.dp))
            if (state.folder == null) Text(stringResource(R.string.lut_monitor_only),
                color = colors.onSurfaceVariant, style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = 12.dp))
        }
        if ((accessible && state.files.isNotEmpty()) || state.active != null || state.loading != null) {
            LutChoice(off, state.active == null, false, !closing) { onFeedback(); state.chooseOff() }
        }
        if (accessible && state.files.isNotEmpty()) {
            LutCategoryList(state.files, state.active?.file?.uri, !closing,
                Modifier.weight(1f, fill = false).fillMaxWidth()) { file ->
                LutChoice(file.label, state.active?.file?.uri == file.uri,
                    state.loading == file.uri, !closing) { onFeedback(); state.select(file) }
            }
        }
        Text(folderLabel, style = style, color = colors.accentBlue,
            modifier = Modifier.fillMaxWidth().clickable(enabled = !closing) { onFeedback(); onFolder() }
                .padding(horizontal = 12.dp, vertical = 10.dp))
    }
}

@Composable
private fun LutChoice(text: String, selected: Boolean, pending: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val colors = AppTheme.colors
    val breathing = if (pending && enabled) {
        val transition = rememberInfiniteTransition(label = "lutPending")
        val alpha = transition.animateFloat(1f, .5f,
            infiniteRepeatable(tween(600, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "lutOpacity")
        Modifier.graphicsLayer { this.alpha = alpha.value }
    } else Modifier
    Text(text, style = MaterialTheme.typography.bodyMedium,
        color = if (selected || pending) colors.accentBlue else colors.onBackground,
        maxLines = 2, overflow = TextOverflow.Ellipsis,
        modifier = Modifier.fillMaxWidth().then(breathing)
            .background(if (selected) colors.accentBlue.copy(alpha = .08f) else Color.Transparent)
            .clickable(enabled = enabled, onClick = onClick).padding(horizontal = 12.dp, vertical = 8.dp))
}
