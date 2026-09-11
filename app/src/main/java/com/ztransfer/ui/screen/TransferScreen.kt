package com.ztransfer.ui.screen

import android.annotation.SuppressLint
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.filter.BuiltInPhotoFilters
import com.ztransfer.filter.builtInPhotoFilterNameResId
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.protocol.PtpConstants
import com.ztransfer.ui.theme.*
import com.ztransfer.ui.util.formatDuration
import com.ztransfer.ui.util.formatFileSize
import com.ztransfer.ui.util.formatSpeed
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.CameraState
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import com.ztransfer.viewmodel.TransferViewModel
import com.ztransfer.viewmodel.isTransferredOriginal
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

private data class TransferCameraUiState(
    val isConnectedToCamera: Boolean,
    val connectionType: CameraConnectionType?,
    val isStaConnection: Boolean,
    val wifiRssi: Int?,
)

private fun CameraState.toTransferCameraUiState(): TransferCameraUiState = TransferCameraUiState(
    isConnectedToCamera = isConnectedToCamera,
    connectionType = connectionType,
    isStaConnection = isStaConnection,
    wifiRssi = wifiRssi,
)

/** 队列页固定顶栏；由工作区宿主在页面转场过半后显现，不参与正文横向位移。 */
// `.value` only seeds the mapped flow; ongoing updates are collected immediately below.
@SuppressLint("StateFlowValueCalledInComposition")
@Composable
fun TransferTopControls(
    cameraViewModel: CameraViewModel,
    onNavigateBack: () -> Unit,
) {
    val cameraState by remember(cameraViewModel) {
        cameraViewModel.state
            .map(CameraState::toTransferCameraUiState)
            .distinctUntilChanged()
    }.collectAsState(initial = cameraViewModel.state.value.toTransferCameraUiState())
    val colors = AppTheme.colors

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        GlassButton(
            onClick = onNavigateBack,
            contentPadding = PaddingValues(horizontal = 9.dp, vertical = 7.dp),
            enforceMinimumTouchTarget = false,
            modifier = Modifier.height(36.dp),
        ) {
            Icon(
                Icons.Default.ArrowBack,
                contentDescription = stringResource(R.string.cd_back),
                tint = colors.onBackground,
                modifier = Modifier.size(22.dp),
            )
        }

        Spacer(modifier = Modifier.width(8.dp))
        SignalPill(
            rssi = cameraState.wifiRssi,
            connected = cameraState.isConnectedToCamera,
            connectionType = cameraState.connectionType,
            staMode = cameraState.isStaConnection,
            onStaDisconnectedClick = cameraViewModel::retryStaConnection,
        )
    }
}

// `.value` only seeds the mapped flow; ongoing updates are collected immediately below.
@SuppressLint("StateFlowValueCalledInComposition")
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TransferScreen(
    transferViewModel: TransferViewModel,
    cameraViewModel: CameraViewModel,
    queueControlActionNonce: Long,
    backHandlerEnabled: Boolean,
    onNavigateBack: () -> Unit
) {
    BackHandler(enabled = backHandlerEnabled, onBack = onNavigateBack)
    val transferState by transferViewModel.state.collectAsState()
    // 响应式连接状态：断开/重连即时反映到重试按钮的可用性（getCamera() 不是快照状态，不能作 gating）。
    val connected by remember(cameraViewModel) {
        cameraViewModel.state
            .map { it.isConnectedToCamera }
            .distinctUntilChanged()
    }.collectAsState(initial = cameraViewModel.state.value.isConnectedToCamera)
    SharedTransferScreen(
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

@Composable
private fun TransferTaskCardContent(
    task: TransferTask,
    displayedSpeed: Long,
    displayedFrameGenerationElapsedMs: Long?,
    modifier: Modifier = Modifier,
) {
    val transferred = task.status == TransferStatus.COMPLETED
    val speedText = when {
        task.status == TransferStatus.TRANSFERING && displayedSpeed > 0L -> formatSpeed(displayedSpeed)
        transferred && task.downloadMBps > 0f -> "%.1f MB/s".format(task.downloadMBps)
        else -> null
    }
    val transferDuration = task.elapsedMs?.let(::formatDuration)
    val generationDuration = displayedFrameGenerationElapsedMs?.let(::formatDuration)
    val effectText = transferTaskEffectText(task)
    SharedTransferTaskCardContent(
        task = task,
        text = TransferTaskCardText(
            speedText = speedText,
            transferDuration = transferDuration,
            generationDuration = generationDuration,
            effectText = effectText,
            fileSizeText = transferTaskFileSizeText(task),
            failureText = task.error ?: if (task.status == TransferStatus.FAILED) stringResource(R.string.transfer_failed) else "",
        ),
        modifier = modifier,
    )
}

@Composable
private fun transferTaskEffectText(task: TransferTask): String? {
    val frameName = task.framePreset
        ?.takeIf { task.frameBorderRequested }
        ?.let { photoFramePresetLabel(it) }
    val filterName = task.photoFilterRequested?.let {
        "${photoFilterDisplayName(it.preset)} ${it.normalizedIntensityPercent}%"
    }
    val parts = listOfNotNull(frameName, filterName)
    return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}

private fun transferTaskFileSizeText(task: TransferTask): String = when {
    task.file.size != PtpConstants.SIZE_UNKNOWN -> formatFileSize(task.file.size)
    task.downloaded > 0L -> formatFileSize(task.downloaded)
    else -> "—"
}

@Composable
private fun photoFramePresetLabel(preset: PhotoFramePreset): String = stringResource(
    when (preset) {
        PhotoFramePreset.MIST -> R.string.photo_frame_mist
        PhotoFramePreset.CINEMA -> R.string.photo_frame_cinema
        PhotoFramePreset.MINIMAL -> R.string.photo_frame_minimal
        PhotoFramePreset.FROSTED -> R.string.photo_frame_frosted
        PhotoFramePreset.PLAQUE -> R.string.photo_frame_plaque
        PhotoFramePreset.IMMERSIVE -> R.string.photo_frame_immersive
        PhotoFramePreset.BRAND_INSET -> R.string.photo_frame_brand_inset
        PhotoFramePreset.BRAND_GALLERY -> R.string.photo_frame_brand_gallery
        PhotoFramePreset.CLASSIC_SIGNATURE -> R.string.photo_frame_classic_signature
        PhotoFramePreset.GALLERY_MAT -> R.string.photo_frame_gallery_mat
        PhotoFramePreset.COLOR_ARCHIVE -> R.string.photo_frame_color_archive
        PhotoFramePreset.FILM_GALLERY -> R.string.photo_frame_film_gallery
        PhotoFramePreset.FILM_EDGE -> R.string.photo_frame_film_edge
    }
)

@Composable
private fun photoFilterDisplayName(filter: PhotoFilterPreset): String =
    builtInPhotoFilterNameResId(filter.id)?.let { stringResource(it) } ?: filter.name

/**
 * 传输队列行内的小缩略图。命中缓存即显示，未命中即发 GetThumb（传输中请求排到文件
 * 间隙执行，不拖慢传输中的文件）。[retryNudge] 变化时对加载失败的缩略图再补一次
 *（传输结束是自然的补载时机）。
 */
@Composable
private fun QueueThumbnail(
    file: CameraFileInfo,
    retryNudge: Boolean,
    cameraViewModel: CameraViewModel,
    modifier: Modifier = Modifier,
) {
    var thumbnail by remember(file.handle) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(file.handle, retryNudge) {
        if (thumbnail == null) {
            thumbnail = cameraViewModel.loadThumbnail(file)
        }
    }
    QueueThumbnailContent(thumbnail, modifier)
}
