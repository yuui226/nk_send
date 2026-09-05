"""Extract the original untransferred completion-exit coordinator and its exact callback."""
from thumbnail_grid_extraction import section
from transfer_card_extraction import replace_once


def extract_export_exit(source):
    source = source.replace('\r\n', '\n')
    start = '    // “未传输”筛选下，本次队列刚完成的照片先留在网格中播放单格退场'
    end = '    // 分组 / 扁平列表'
    body = section(source, start, end)
    callback = section(source, '                onExportExitFinished = { handle ->', '                modifier = Modifier.fillMaxSize()')
    android = replace_once(source, body, '''    val exportExit = rememberExportExitState(transferState.tasks, filterUntransferred, exportedHandlesForFilter)
    val filteredExportHandles = exportExit.filteredHandles
''')
    android = replace_once(android, '                exitingExportHandles = exitingExportHandles.keys,', '                exitingExportHandles = exportExit.exitingHandles,')
    android = replace_once(android, '                exportReflowActive = exportReflowActive,', '                exportReflowActive = exportExit.reflowActive,')
    android = replace_once(android, callback, '                onExportExitFinished = exportExit.onExitFinished,\n')
    shared = '''@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.runtime.*
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import kotlinx.coroutines.delay

@kotlin.native.HiddenFromObjC
data class ExportExitUiState(
    val filteredHandles: Set<Int>, val exitingHandles: Set<Int>, val reflowActive: Boolean,
    val onExitFinished: (Int) -> Unit,
)

/** Original Android completion-exit state, shared with the native file workspace. */
@kotlin.native.HiddenFromObjC
@Composable
fun rememberExportExitState(
    tasks: List<TransferTask>, filterUntransferred: Boolean, exportedHandlesForFilter: Set<Int>,
): ExportExitUiState {
'''
    shared += body.replace('transferState.tasks', 'tasks')
    shared += '    return ExportExitUiState(filteredExportHandles, exitingExportHandles.keys, exportReflowActive,\n'
    shared += '        onExitFinished = { handle ->\n'
    shared += '\n'.join(line[8:] for line in callback.splitlines()[1:-1])+'\n'
    shared += '        },\n    )\n}\n'
    return android, shared
