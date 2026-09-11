@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

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
    // “未传输”筛选下，本次队列刚完成的照片先留在网格中播放单格退场，再真正加入过滤集合。
    // 导出目录扫描发现的历史文件不需要动画，仍然同步过滤，避免列表初次加载时闪现旧照片。
    val animatedExportCandidates = remember(tasks, filterUntransferred) {
        if (filterUntransferred) {
            tasks.asSequence()
                .filter {
                    it.status == TransferStatus.WAITING ||
                        it.status == TransferStatus.TRANSFERING ||
                        it.status == TransferStatus.COMPLETED
                }
                .mapTo(HashSet()) { it.file.handle }
        } else {
            emptySet()
        }
    }
    var finishedExportExitHandles by remember(filterUntransferred) {
        mutableStateOf(exportedHandlesForFilter.intersect(animatedExportCandidates))
    }
    val exitingExportHandles = remember { mutableStateMapOf<Int, Unit>() }
    var exportReflowActive by remember { mutableStateOf(false) }
    var exportReflowTick by remember { mutableStateOf(0) }
    val filteredExportHandles = remember(
        exportedHandlesForFilter,
        animatedExportCandidates,
        finishedExportExitHandles
    ) {
        if (filterUntransferred) {
            (exportedHandlesForFilter - animatedExportCandidates) + finishedExportExitHandles
        } else {
            emptySet()
        }
    }

    LaunchedEffect(exportedHandlesForFilter, animatedExportCandidates, filterUntransferred) {
        finishedExportExitHandles = finishedExportExitHandles.intersect(exportedHandlesForFilter)
        exitingExportHandles.keys
            .filterNot { it in exportedHandlesForFilter }
            .forEach(exitingExportHandles::remove)

        if (!filterUntransferred) {
            // 筛选未开启时没有退场语义，也不保留任何已传 handle 集合。
            exitingExportHandles.clear()
            finishedExportExitHandles = emptySet()
            exportReflowActive = false
        } else {
            val newlyExported = exportedHandlesForFilter
                .intersect(animatedExportCandidates)
                .minus(finishedExportExitHandles)
                .minus(exitingExportHandles.keys)
            if (newlyExported.isNotEmpty()) {
                newlyExported.forEach { exitingExportHandles[it] = Unit }
                // 在条目真正移除前启用 placement modifier，让 LazyGrid 已经持有旧位置。
                exportReflowActive = true
            }
        }
    }
    LaunchedEffect(exportReflowTick) {
        if (exportReflowTick > 0) {
            delay(320)
            if (exitingExportHandles.isEmpty()) exportReflowActive = false
        }
    }
    return ExportExitUiState(filteredExportHandles, exitingExportHandles.keys, exportReflowActive,
        onExitFinished = { handle ->
            if (handle in exitingExportHandles) {
                finishedExportExitHandles = finishedExportExitHandles + handle
                exitingExportHandles.remove(handle)
                exportReflowTick++
            }
        },
    )
}
