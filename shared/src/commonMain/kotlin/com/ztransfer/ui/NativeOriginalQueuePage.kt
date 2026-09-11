package com.ztransfer.ui

import androidx.compose.animation.*
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.ztransfer.format.*
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.protocol.PtpConstants
import com.ztransfer.ui.screen.*
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.Motion
import com.ztransfer.viewmodel.TransferStatus
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch

/** Original-file coordinator entry: real shared queue, no sample tasks or fake operation results. */
@Composable
internal fun NativeOriginalQueuePage(
    model: NativeQueuePageModel,
    text: NativeQueuePageText,
    elapsedRealtimeMs: () -> Long,
    onBack: () -> Unit,
    thumbnail: @Composable (CameraFileInfo, Boolean, Modifier) -> Unit,
    showContent: Boolean = true,
    showControls: Boolean = true,
    language: String = "zh-Hans",
) {
    val state by model.state.collectAsState()
    val connected by model.connected.collectAsState()
    val paused by model.paused.collectAsState()
    var controlNonce by remember { mutableLongStateOf(0L) }
    val scope = rememberCoroutineScope()
    val colors = AppTheme.colors
    val executionControl = queueExecutionControl(state.isTransferring,
        state.tasks.count { it.status == TransferStatus.WAITING })
    var retainedExecutionControl by remember {
        mutableStateOf(executionControl ?: QueueExecutionControl.START)
    }
    LaunchedEffect(executionControl) {
        executionControl?.let { retainedExecutionControl = it }
    }
    Box(Modifier.fillMaxSize().navigationBarsPadding()) {
        if (showContent) SharedTransferScreen(
            state, connected, controlNonce, model.activeProgress, elapsedRealtimeMs,
            // The original-only coordinator does not yet have a local-original export index.
            // Never claim offline effect retries work until that pipeline is actually connected.
            isOriginalTransferred = { false }, actions = model.actions, text = text.queue,
            thumbnail = thumbnail,
            cardContent = { task, speed, generationElapsed, modifier ->
                SharedTransferTaskCardContent(task, TransferTaskCardText(
                    speedText = when {
                        task.status == TransferStatus.TRANSFERING && speed > 0L -> formatTransferSpeedText(speed, model::fixed)
                        task.status == TransferStatus.COMPLETED && task.downloadMBps > 0f -> model.completedSpeed(task.downloadMBps)
                        else -> null
                    },
                    transferDuration = task.elapsedMs?.let { formatDurationText(it, model::fixed) },
                    generationDuration = generationElapsed?.let { formatDurationText(it, model::fixed) },
                    effectText = null, // Snapshot admits original-file tasks only, not incomplete effects.
                    fileSizeText = when {
                        task.file.size != PtpConstants.SIZE_UNKNOWN -> formatFileSizeText(task.file.size, model::fixed)
                        task.downloaded > 0 -> formatFileSizeText(task.downloaded, model::fixed)
                        else -> "—"
                    },
                    failureText = task.error?.let { NativeTransferMessages.render(it, language) } ?: text.failed,
                ), modifier)
            },
        )
        if (showControls) Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically) {
            GlassButton(onClick = onBack, contentPadding = PaddingValues(horizontal = 9.dp, vertical = 7.dp),
                enforceMinimumTouchTarget = true, modifier = Modifier.heightIn(min = 48.dp)) {
                Icon(Icons.Default.ArrowBack, text.back, tint = colors.onBackground, modifier = Modifier.size(22.dp))
            }
            Spacer(Modifier.width(8.dp))
            SharedSignalPill(
                text = text.signal, rssi = null, connected = connected,
                connectionType = CameraConnectionType.WIFI, staMode = model.stationMode,
                allowUnknownRssi = true,
                onOpenWifiSettings = model::showConnectionHelp,
                onStaDisconnectedClick = model::showConnectionHelp,
            )
            Spacer(Modifier.weight(1f))
            AnimatedVisibility(
                visible = executionControl != null,
                enter = fadeIn(tween(160)) + scaleIn(initialScale = 0.72f, animationSpec = Motion.bouncy()),
                exit = fadeOut(tween(120)) + scaleOut(targetScale = 0.72f, animationSpec = tween(140)),
            ) {
                SharedQueueExecutionButton(
                    startDescription = text.start, pauseDescription = text.pause,
                    pauseScheduledDescription = text.pauseScheduled,
                    control = retainedExecutionControl, pauseRequested = paused,
                    // This coordinator admits original-file tasks only; all waiting tasks need the camera.
                    startEnabled = connected,
                    onStart = {
                        controlNonce++
                        scope.launch(start = CoroutineStart.UNDISPATCHED) { model.start() }
                    },
                    onPause = {
                        if (state.isTransferring && !paused) {
                            controlNonce++
                            scope.launch(start = CoroutineStart.UNDISPATCHED) { model.pause() }
                        }
                    },
                )
            }
        }
    }
}
