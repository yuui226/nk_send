package com.ztransfer.ui.screen

import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ztransfer.R

@Composable
internal fun RemoteMonitorHelpBubble(
    anchorBounds: Rect?,
    tools: RemoteToolPreferences,
    onDismiss: () -> Unit,
) {
    val sections = listOf(
        TipBubbleSection(stringResource(R.string.monitor_help_section_basic), listOf(
            monitorHelpItem(R.string.monitor_help_capture_label, R.string.monitor_help_capture),
            monitorHelpItem(R.string.monitor_help_focus_label, R.string.monitor_help_focus),
            monitorHelpItem(R.string.monitor_help_parameters_label, R.string.monitor_help_parameters),
            monitorHelpItem(R.string.monitor_help_review_label, R.string.monitor_help_review),
            monitorHelpItem(R.string.monitor_help_status_label, R.string.monitor_help_status),
        )),
        TipBubbleSection(stringResource(R.string.monitor_help_section_camera), listOf(
            monitorToolHelpItem(RemoteTool.WHITE_BALANCE, R.string.monitor_help_tool_white_balance, tools),
            monitorToolHelpItem(RemoteTool.FOCUS_MODE, R.string.monitor_help_tool_focus_mode, tools),
            monitorToolHelpItem(RemoteTool.FOCUS_AREA, R.string.monitor_help_tool_focus_area, tools),
            monitorToolHelpItem(RemoteTool.FOCUS_FRAME, R.string.monitor_help_tool_focus_frame, tools),
            monitorToolHelpItem(RemoteTool.PICTURE_CONTROL, R.string.monitor_help_tool_picture_control, tools),
            monitorToolHelpItem(RemoteTool.COMPUTER_CONTROL, R.string.monitor_help_tool_computer_control, tools),
        )),
        TipBubbleSection(stringResource(R.string.monitor_help_section_exposure), listOf(
            monitorToolHelpItem(RemoteTool.HISTOGRAM, R.string.monitor_help_tool_histogram, tools),
            monitorToolHelpItem(RemoteTool.EXPOSURE, R.string.monitor_help_tool_exposure, tools),
            monitorToolHelpItem(RemoteTool.METER, R.string.monitor_help_tool_meter, tools),
            monitorToolHelpItem(RemoteTool.WAVEFORM, R.string.monitor_help_tool_waveform, tools),
            monitorToolHelpItem(RemoteTool.LUT, R.string.monitor_help_tool_lut, tools),
        )),
        TipBubbleSection(stringResource(R.string.monitor_help_section_display), listOf(
            monitorToolHelpItem(RemoteTool.HD, R.string.monitor_help_tool_hd, tools),
            monitorToolHelpItem(RemoteTool.FPS, R.string.monitor_help_tool_fps, tools),
            monitorToolHelpItem(RemoteTool.AUDIO, R.string.monitor_help_tool_audio, tools),
            monitorToolHelpItem(RemoteTool.RECORD, R.string.monitor_help_tool_record, tools),
        )),
        TipBubbleSection(stringResource(R.string.monitor_help_section_layout), listOf(
            monitorToolHelpItem(RemoteTool.GRID, R.string.monitor_help_tool_grid, tools),
            monitorToolHelpItem(RemoteTool.LEVEL, R.string.monitor_help_tool_level, tools),
            monitorToolHelpItem(RemoteTool.DESQUEEZE, R.string.monitor_help_tool_desqueeze, tools),
            monitorToolHelpItem(RemoteTool.LOCK, R.string.monitor_help_tool_lock, tools),
            monitorToolHelpItem(RemoteTool.ROTATE, R.string.monitor_help_tool_rotate, tools),
            TipBubbleItem(
                text = stringResource(R.string.monitor_help_manage),
                label = stringResource(R.string.remote_tool_manage),
                leading = {
                    TopIconToggle(false, "", {}, displayOnly = true) {
                        Icon(Icons.Default.Settings, null, Modifier.size(19.dp))
                    }
                },
            ),
            TipBubbleItem(
                text = stringResource(R.string.monitor_help_disp),
                label = stringResource(R.string.monitor_help_disp_label),
                leading = {
                    TopIconToggle(false, "", {}, displayOnly = true) {
                        Text("DISP", fontSize = 8.sp, fontWeight = FontWeight.Bold)
                    }
                },
            ),
        )),
    )
    TipGuideBubble(
        anchorBounds = anchorBounds,
        title = stringResource(R.string.monitor_help_title),
        sections = sections,
        panelAlignment = Alignment.TopStart,
        onDismiss = onDismiss,
    )
}

@Composable
private fun monitorHelpItem(labelRes: Int, textRes: Int) = TipBubbleItem(
    text = stringResource(textRes),
    label = stringResource(labelRes),
)

@Composable
private fun monitorToolHelpItem(tool: RemoteTool, textRes: Int, tools: RemoteToolPreferences) = TipBubbleItem(
    text = stringResource(textRes),
    label = stringResource(tool.title),
    leading = {
        if (tool == RemoteTool.RECORD) {
            Box(Modifier.size(36.dp).clearAndSetSemantics { }) {
                RecControlBar(
                    isRecording = false,
                    isPaused = false,
                    elapsedSeconds = 0,
                    onStart = {},
                    onPauseResume = {},
                    onStop = {},
                    modifier = Modifier.matchParentSize(),
                )
                // Keep the original recording control untouched. Only its guide sample
                // intercepts taps; drags can still scroll the surrounding help bubble.
                Box(Modifier.matchParentSize().pointerInput(Unit) { detectTapGestures { } })
            }
        } else {
            TopIconToggle(
                active = false,
                contentDescription = "",
                onClick = {},
                modifier = Modifier.size(36.dp),
                fixedControl = tool.fixed,
                preserveContentColors = tool == RemoteTool.PICTURE_CONTROL,
                displayOnly = true,
            ) {
                if (tool == RemoteTool.FOCUS_MODE) {
                    Text("AF-S", fontSize = 8.sp, fontWeight = FontWeight.Bold, maxLines = 1, softWrap = false)
                } else {
                    RemoteToolMark(tool, tools)
                }
            }
        }
    },
)
