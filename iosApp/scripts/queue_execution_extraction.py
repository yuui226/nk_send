"""Exact extraction of the original queue control; Android owns resource lookup."""
from transfer_card_extraction import replace_once

HEADER = '''package com.ztransfer.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.Motion

'''


def extract_queue_execution(source):
    source = source.replace('\r\n', '\n')
    if 'internal val TransferQueuePauseIcon = Icons.Default.Pause' not in source:
        raise ValueError('Original pause icon changed; review extraction')
    start = source.index('/** 与状态胶囊同材质的顶部队列操作按钮，不跟随可选按钮皮肤。 */')
    end = source.index('@Composable\nfun QueuePill(', start)
    body = source[start:end]
    signature_end = body.index('    val colors = AppTheme.colors')
    adapter = body[:signature_end] + '''    SharedQueueExecutionButton(
        control = control, pauseRequested = pauseRequested, startEnabled = startEnabled,
        onStart = onStart, onPause = onPause, modifier = modifier,
        startDescription = stringResource(R.string.cd_start_transfers),
        pauseDescription = stringResource(R.string.cd_pause_after_current),
        pauseScheduledDescription = stringResource(R.string.cd_pause_after_current_scheduled),
    )
}

'''
    shared = replace_once(body, 'internal fun QueueExecutionButton(', 'fun SharedQueueExecutionButton(\n    startDescription: String,\n    pauseDescription: String,\n    pauseScheduledDescription: String,')
    shared = replace_once(shared, '                        TransferQueuePauseIcon', '                        Icons.Default.Pause')
    shared = replace_once(shared, '''contentDescription = stringResource(
                        when {
                            current == QueueExecutionControl.START -> R.string.cd_start_transfers
                            pauseRequested -> R.string.cd_pause_after_current_scheduled
                            else -> R.string.cd_pause_after_current
                        }
                    ),''', '''contentDescription = when {
                        current == QueueExecutionControl.START -> startDescription
                        pauseRequested -> pauseScheduledDescription
                        else -> pauseDescription
                    },''')
    return replace_once(source, body, adapter), HEADER + shared.rstrip() + '\n'
