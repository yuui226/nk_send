"""Explicit platform-boundary substitutions; preserve the original queue UI body."""
import re
from transfer_card_extraction import replace_once


def adapt_async_page(page):
    # UNDISPATCHED starts synchronous Android adapters inline, before the click returns.
    page = replace_once(page, "import kotlinx.coroutines.delay", "import kotlinx.coroutines.CoroutineStart\nimport kotlinx.coroutines.delay")
    for invocation in ("actions.retrySingleTask(taskId)", "actions.retryFailed(removingTaskIds.keys.toSet())"):
        line = next(line for line in page.splitlines() if invocation in line)
        indent = line[:len(line) - len(line.lstrip())]
        page = replace_once(page, line, indent + "clearScope.launch(start = CoroutineStart.UNDISPATCHED) {\n" + "    " + line + "\n" + indent + "}")
    old = """                                                actions.withdrawTask(taskId)
                                                removingTaskIds[taskId] = Unit"""
    new = """                                                clearScope.launch(start = CoroutineStart.UNDISPATCHED) {
                                                    actions.withdrawTask(taskId)
                                                    removingTaskIds[taskId] = Unit
                                                }"""
    page = replace_once(page, old, new)
    start = page.index("                        clearAllInProgress = true")
    marker = "                        clearScope.launch {\n                            try {\n"
    end = page.index(marker, start) + len(marker)
    prefix = page[start:end-len(marker)].splitlines(True)
    rewritten = ("                        clearScope.launch(start = CoroutineStart.UNDISPATCHED) {\n"
                 "                            clearAllInProgress = true\n"
                 "                            try {\n" + ''.join('        ' + line for line in prefix[1:]))
    return replace_once(page, page[start:end], rewritten)


def remove_unused_android_wrappers(source):
    start = source.index("@Composable\nprivate fun TransferRetryButton(")
    end = source.index("@Composable\nprivate fun TransferTaskCardContent(", start)
    source = replace_once(source, source[start:end], "")
    start = source.index('/**\n * 右下角悬浮的"图标 FAB + 二次确认"控件')
    end = source.index('/**\n * 传输队列行内的小缩略图', start)
    return replace_once(source, source[start:end], "")

HEADER = """package com.ztransfer.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.theme.*
import com.ztransfer.viewmodel.ActiveTransferProgress
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

"""

SIGNATURE = """/** One product queue body. Platform adapters retain services, text formatting and image I/O. */
@OptIn(ExperimentalFoundationApi::class, kotlin.experimental.ExperimentalObjCRefinement::class)
@kotlin.native.HiddenFromObjC
@Composable
fun SharedTransferScreen(
    transferState: TransferQueueUiState,
    connected: Boolean,
    queueControlActionNonce: Long,
    activeTransferProgress: StateFlow<ActiveTransferProgress?>,
    elapsedRealtimeMs: () -> Long,
    isOriginalTransferred: (TransferTask) -> Boolean,
    actions: TransferQueueUiActions,
    text: TransferQueueUiText,
    thumbnail: @Composable (CameraFileInfo, Boolean, Modifier) -> Unit,
    cardContent: @Composable (TransferTask, Long, Long?, Modifier) -> Unit,
) {
"""

ANDROID_BINDING = """    SharedTransferScreen(
        transferState = TransferQueueUiState(
            tasks = transferState.tasks,
            isTransferring = transferState.isTransferring,
            existingExportRevision = transferState.existingExportRevision,
        ),
        connected = connected,
        queueControlActionNonce = queueControlActionNonce,
        activeTransferProgress = transferViewModel.activeTransferProgress,
        elapsedRealtimeMs = android.os.SystemClock::elapsedRealtime,
        isOriginalTransferred = { task ->
            isTransferredOriginal(task.file, transferState.existingExportIndex, task.destinationFolderName)
        },
        actions = remember(transferViewModel, cameraViewModel) {
            TransferQueueUiActions(
                removeTask = transferViewModel::removeTask,
                withdrawTask = transferViewModel::withdrawTask,
                retrySingleTask = { transferViewModel.retrySingleTask(it, cameraViewModel::getCamera) },
                retryFailed = { transferViewModel.retryFailed(cameraViewModel::getCamera, excludedTaskIds = it) },
                withdrawPending = transferViewModel::withdrawPending,
                removeCleared = transferViewModel::removeCleared,
                currentTasks = { transferViewModel.state.value.tasks },
            )
        },
        text = TransferQueueUiText(
            removeFromQueue = stringResource(R.string.cd_remove_from_queue),
            retryFailedDescription = stringResource(R.string.cd_retry_failed),
            retryFailedTitle = stringResource(R.string.retry_failed_title),
            retry = stringResource(R.string.retry),
            clearQueueDescription = stringResource(R.string.cd_clear_queue),
            clearQueueTitle = stringResource(R.string.clear_queue_title),
            clearQueueSubtitle = stringResource(R.string.clear_queue_subtitle),
            clear = stringResource(R.string.clear),
            cancel = stringResource(R.string.cancel),
        ),
        thumbnail = { file, retryNudge, modifier ->
            QueueThumbnail(file, retryNudge, cameraViewModel, modifier)
        },
        cardContent = { task, speed, generationElapsed, modifier ->
            TransferTaskCardContent(task, speed, generationElapsed, modifier)
        },
    )
}

"""


def extract_transfer_page(source):
    source = source.replace("\r\n", "\n")
    start = source.index("fun TransferScreen(")
    body_start = source.index("    val colors = AppTheme.colors", start)
    end = source.index("@Composable\nprivate fun TransferRetryButton(", body_start)
    original_body = source[body_start:end]
    body = original_body
    constants_start = source.index("private const val TRANSFER_CARD_WAVE_CYCLE_MS")
    constants_end = source.index("private data class TransferCameraUiState", constants_start)
    constants = source[constants_start:constants_end]
    replacements = (
        ("transferViewModel.activeTransferProgress.collectAsState()", "activeTransferProgress.collectAsState()"),
        ("transferViewModel.removeTask(taskId)", "actions.removeTask(taskId)"),
        ("transferViewModel.withdrawTask(taskId)", "actions.withdrawTask(taskId)"),
        ("transferViewModel.withdrawPending()", "actions.withdrawPending()"),
        ("transferViewModel.removeCleared()", "actions.removeCleared()"),
        ("transferViewModel.state.value.tasks", "actions.currentTasks()"),
        ("""transferViewModel.retrySingleTask(
                                                taskId,
                                                cameraViewModel::getCamera,
                                            )""", "actions.retrySingleTask(taskId)"),
        ("""transferViewModel.retryFailed(
                            cameraProvider = cameraViewModel::getCamera,
                            excludedTaskIds = removingTaskIds.keys.toSet(),
                        )""", "actions.retryFailed(removingTaskIds.keys.toSet())"),
        ("""QueueThumbnail(
                                        file = task.file,
                                        retryNudge = transferState.isTransferring,
                                        cameraViewModel = cameraViewModel,
                                        modifier = Modifier.align(Alignment.Center),
                                    )""", "thumbnail(task.file, transferState.isTransferring, Modifier.align(Alignment.Center))"),
        ("""TransferTaskCardContent(
                                        task = task,
                                        displayedSpeed = displayedSpeed,
                                        displayedFrameGenerationElapsedMs = displayedFrameGenerationElapsedMs,
                                        modifier = Modifier.fillMaxWidth(),
                                    )""", "cardContent(task, displayedSpeed, displayedFrameGenerationElapsedMs, Modifier.fillMaxWidth())"),
        ("TransferRetryButton(", "SharedTransferRetryButton(\n                                        contentDescription = text.retry,"),
    )
    for old, new in replacements:
        body = replace_once(body, old, new)
    for variable in ("it", "task"):
        pattern = rf"isTransferredOriginal\(\s+{variable}\.file,\s+transferState\.existingExportIndex,\s+{variable}\.destinationFolderName,\s+\)"
        matches = re.findall(pattern, body)
        if len(matches) != 1:
            raise ValueError("Unexpected original-file lookup")
        body = replace_once(body, matches[0], f"isOriginalTransferred({variable})")
    for old, new in (
        ("android.os.SystemClock.elapsedRealtime()", "elapsedRealtimeMs()"),
        ("ConfirmFab(", "SharedQueueConfirmFab(\n                    cancelText = text.cancel,"),
    ):
        if body.count(old) != 2:
            raise ValueError(f"Expected exactly two {old} call sites")
        body = body.replace(old, new)
    for resource, field in (
        ("cd_remove_from_queue", "removeFromQueue"),
        ("cd_retry_failed", "retryFailedDescription"),
        ("retry_failed_title", "retryFailedTitle"), ("retry", "retry"),
        ("cd_clear_queue", "clearQueueDescription"), ("clear_queue_title", "clearQueueTitle"),
        ("clear_queue_subtitle", "clearQueueSubtitle"), ("clear", "clear"),
    ):
        body = replace_once(body, f"stringResource(R.string.{resource})", f"text.{field}")
    for forbidden in ("transferViewModel", "cameraViewModel", "stringResource(", "android."):
        if forbidden in body:
            raise ValueError(f"Unadapted platform dependency: {forbidden}")
    android = replace_once(source, original_body, ANDROID_BINDING)
    android = replace_once(android, constants, "")
    android = remove_unused_android_wrappers(android)
    return android, adapt_async_page(HEADER + constants + SIGNATURE + body.rstrip() + "\n")


def extract_collapse_height(source):
    source = source.replace("\r\n", "\n")
    start = source.index("/**\n * 手风琴收合：")
    end = source.index("/** 从 Compose 的 Context", start)
    original = source[start:end]
    shared = """package com.ztransfer.ui.screen

import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.layout.layout
import kotlin.math.roundToInt

""" + replace_once(original, "internal fun Modifier.collapseHeight", "fun Modifier.collapseHeight")
    return replace_once(source, original, ""), shared.rstrip() + "\n"
