package com.ztransfer.ui.screen

import android.net.Uri
import android.content.ContentResolver
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.BurstMode
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Key
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.IntSize
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.Dispatchers
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.frame.PhotoFrameExporter
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.protocol.PtpConstants
import com.ztransfer.ui.theme.*
import com.ztransfer.ui.util.formatFileSize
import com.ztransfer.ui.util.rememberHaptics
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.NIKON_RAW_EXTENSIONS
import com.ztransfer.viewmodel.TIFF_EXTENSIONS
import com.ztransfer.viewmodel.PhotoExif
import com.ztransfer.viewmodel.ActiveTransferProgress
import com.ztransfer.viewmodel.TransferTask
import kotlinx.coroutines.flow.StateFlow

// 视频扩展名：无高清封面，预览走"压暗缩略图 + 视频占位"分支。
// 注意与 CameraViewModel.VIDEO_EXTENSIONS（封面黑边兜底）保持同步。
private const val FOUR_GIB_BYTES = 4L * 1024L * 1024L * 1024L

internal fun localOriginalPreviewRoute(extension: String): LocalOriginalPreviewRoute =
    originalLocalPreviewRoute(extension)

/** PTP DateTime（YYYYMMDDThhmmss…）转为预览页使用的稳定本地格式。 */
internal fun formatPreviewCaptureDate(raw: String?): String? = previewCaptureDateText(raw,
    dateText = { year, month, day -> "%04d-%02d-%02d".format(year, month, day) },
    timeText = { hour, minute, second -> "%02d:%02d:%02d".format(hour, minute, second) },
)

internal fun videoPreviewMetadata(
    fileSize: Long,
    captureDate: String?,
    overFourGbLabel: String,
): String = previewVideoMetadataText(fileSize, captureDate, overFourGbLabel,
    sizeText = ::formatFileSize, captureText = ::formatPreviewCaptureDate)

/**
 * 全屏预览层：普通页显示缓存缩略图的**未裁切**（Fit）完整画面；折叠连拍在分页中
 * 保持为一个合集页，只有用户主动展开才把成员插入其后。
 * 传输中仍可预读相邻本地原图；只有相机 FHD + EXIF 继续限制为当前页优先。
 * 整体从被长按格子 [anchorRect] 的位置缩放展开，关闭时反向缩回（从哪来回哪去）。
 * 已传输原图优先从本地解码；本地不存在或无法解码时才向相机请求 FHD。
 * 本层在深浅两种主题下都保持黑底沉浸式（照片查看器惯例，黑底最衬照片），
 * 因此内部直接用深色常量而非主题 token——这是有意的，不参与深浅切换。
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun PhotoPreviewOverlay(
    items: List<PhotoPreviewItem>,
    initialIndex: Int,
    anchorRect: Rect?,
    cameraViewModel: CameraViewModel,
    hapticsEnabled: Boolean,
    transfersBusy: Boolean,
    // 全局持久化方向：0..3 个逆时针 90°。只用作本次 overlay 初始值；
    // overlay 内部保留不取模的连续角度，保证 270°→0° 时仍是向左短转 90°。
    initialRotationQuarterTurns: Int = 0,
    // 由传输 ViewModel 持久化；所有连接方式和后续预览共用同一个开关状态。
    histogramVisible: Boolean = false,
    // 连拍成员 handle 集(列表页的检测结果):预览左上角展示连拍角标用;空集即不展示。
    burstHandles: Set<Int> = emptySet(),
    // 复用列表的任务索引与完成判定，预览不维护第二套传输状态。
    queueTaskFor: (CameraFileInfo) -> TransferTask? = { null },
    isTransferred: (CameraFileInfo) -> Boolean = { false },
    // 与完成对号复用同一导出索引；三种连接模式都先走本地 URI，再回退相机 FHD。
    localOriginalUriFor: (CameraFileInfo) -> Uri? = { null },
    activeProgressFlow: StateFlow<ActiveTransferProgress?>,
    // 根坐标中的真实队列胶囊承载区；预览残影使用它计算与列表一致的弧线落点。
    queueTargetBounds: Rect? = null,
    onQueueFlightStarted: (Int) -> Unit = {},
    onQueueFlightFinished: (Int) -> Unit = {},
    onQueueFlightsCancelled: (Int) -> Unit = {},
    onQueueFlightCaught: () -> Unit = {},
    // 把当前预览文件加入传输队列（父层只负责目录/连接校验与入队；动画留在本层）。
    onTransfer: (CameraFileInfo) -> Boolean = { false },
    // 合集页整组入队；动画在本层复用当前合集叠片，不借用被遮住的列表坐标。
    onTransferBurst: (List<CameraFileInfo>) -> Boolean = { false },
    // 预览内主动展开/收起合集时同步底层列表，关闭预览后两处状态一致。
    onBurstExpandedChange: (String, Boolean) -> Unit = { _, _ -> },
    // 每次旋转后回传归一化方向，父层写入全局偏好。
    onRotationChanged: (Int) -> Unit = {},
    onHistogramVisibleChanged: (Boolean) -> Unit = {},
    // 关闭前让底层列表把当前照片准备到可见位置，并返回它最新的根坐标。
    prepareDismissTarget: suspend (CameraFileInfo) -> Rect? = { null },
    // 非空表示当前照片已在底层列表找到，可在预览消失后播放定位脉冲。
    onDismiss: (CameraFileInfo?) -> Unit
) {
    val contentResolver = LocalContext.current.contentResolver
    val session = remember(cameraViewModel, contentResolver) { AndroidPreviewSession(cameraViewModel, contentResolver) }
    SharedPhotoPreviewOverlay(
        items = items, initialIndex = initialIndex, anchorRect = anchorRect, session = session,
        text = AndroidPreviewPageText,
        burstContent = remember(cameraViewModel) { AndroidPreviewBurstContent(cameraViewModel) },
        backHandler = { enabled, onBack -> BackHandler(enabled, onBack) },
        hapticsEnabled = hapticsEnabled, transfersBusy = transfersBusy,
        initialRotationQuarterTurns = initialRotationQuarterTurns, histogramVisible = histogramVisible,
        burstHandles = burstHandles, queueTaskFor = queueTaskFor, isTransferred = isTransferred,
        localOriginalUriFor = localOriginalUriFor,
        activeProgress = { activeProgressFlow.collectAsStateWithLifecycle().value },
        queueTargetBounds = queueTargetBounds,
        onQueueFlightStarted = onQueueFlightStarted,
        onQueueFlightFinished = onQueueFlightFinished,
        onQueueFlightsCancelled = onQueueFlightsCancelled,
        onQueueFlightCaught = onQueueFlightCaught,
        onTransfer = onTransfer, onTransferBurst = onTransferBurst,
        onBurstExpandedChange = onBurstExpandedChange, onRotationChanged = onRotationChanged,
        onHistogramVisibleChanged = onHistogramVisibleChanged,
        prepareDismissTarget = prepareDismissTarget, onDismiss = onDismiss,
    )
}

/**
 * 单张内存位图的大图预览。与照片列表预览共用缩放、平移、双击和旋转内核，但刻意不创建分页器，
 * 因而横向手势只可能用于放大后的平移，不存在翻到其他图片的路径。
 */
@Composable
internal fun SinglePhotoPreviewOverlay(
    bitmap: ImageBitmap,
    title: String,
    anchorRect: Rect?,
    onDismiss: () -> Unit,
) = SharedSinglePhotoPreviewOverlay(bitmap, title, anchorRect, onDismiss,
    backHandler = { enabled, onBack -> BackHandler(enabled, onBack) },
    rotationDescription = { stringResource(R.string.cd_rotate_photo) },
)

private class AndroidPreviewSession(
    private val cameraViewModel: CameraViewModel,
    private val contentResolver: ContentResolver,
) : PreviewSessionSource<Uri> {
    @Composable override fun connected(): Boolean {
        val cameraState by cameraViewModel.state.collectAsState()
        return cameraState.isConnectedToCamera
    }
    override fun setFhdActive(active: Boolean) = cameraViewModel.setFhdActive(active)
    override fun localRoute(extension: String): LocalOriginalPreviewRoute = localOriginalPreviewRoute(extension)
    override suspend fun decodeLocal(source: Uri, route: LocalOriginalPreviewRoute): ImageBitmap? =
        withContext(Dispatchers.IO) {
            val bitmap = when (route) {
                LocalOriginalPreviewRoute.RAW_EMBEDDED_JPEG -> PhotoFrameExporter.decodeRawEmbeddedPreview(contentResolver, source)
                LocalOriginalPreviewRoute.DIRECT_BITMAP -> PhotoFrameExporter.decodeOriginalPreview(contentResolver, source)
                LocalOriginalPreviewRoute.CAMERA_FHD -> null
            }
            bitmap?.asImageBitmap()
        }
    override suspend fun loadFhdPreview(file: CameraFileInfo): ImageBitmap? = cameraViewModel.loadFhdPreview(file)
    override suspend fun loadLocalExif(file: CameraFileInfo, source: Uri): PhotoExif? = cameraViewModel.loadLocalExif(file, source)
    override suspend fun loadExif(file: CameraFileInfo): PhotoExif? = cameraViewModel.loadExif(file)
    override suspend fun <T> withInteractivePreviewPriority(block: suspend () -> T): T =
        cameraViewModel.withInteractivePreviewPriority(block)
    override fun histogram(bitmap: ImageBitmap): LuminanceHistogram = calculateLuminanceHistogram(bitmap.asAndroidBitmap())
    override fun uptimeMillis(): Long = SystemClock.uptimeMillis()
    override fun cached(handle: Int): ImageBitmap? = cameraViewModel.cachedThumbnail(handle)
    override suspend fun thumbnail(file: CameraFileInfo, allowRemote: Boolean): ImageBitmap? =
        cameraViewModel.loadThumbnail(file = file, allowRemote = allowRemote)
}

private object AndroidPreviewPageText : PreviewSessionText {
    @Composable override fun burstLabel(): String = stringResource(R.string.burst_label)
    @Composable override fun protectedLabel(): String = stringResource(R.string.filter_protected)
    @Composable override fun histogramDescription(): String = stringResource(R.string.cd_preview_histogram)
    @Composable override fun rotationDescription(): String = stringResource(R.string.cd_rotate_photo)
    @Composable override fun videoMetadata(file: CameraFileInfo): String = videoPreviewMetadata(
        fileSize = file.size, captureDate = file.captureDate,
        overFourGbLabel = stringResource(R.string.video_size_over_4gb),
    )
    @Composable override fun videoUnavailable(): String = stringResource(R.string.video_no_preview)
    @Composable override fun noPreview(): String = stringResource(R.string.no_preview)
    @Composable override fun navigationDescription(expand: Boolean): String =
        stringResource(if (expand) R.string.cd_expand else R.string.cd_collapse)
    @Composable override fun transferDescription(): String = stringResource(R.string.cd_transfer)
}

private class AndroidPreviewBurstContent(private val cameraViewModel: CameraViewModel) : PreviewBurstContent {
    @Composable override fun accessibility(count: Int): String = stringResource(R.string.burst_collection_a11y, count)
    @Composable override fun Photo(file: CameraFileInfo, loadEnabled: Boolean, showPlaceholderIcon: Boolean, modifier: Modifier) {
        BurstStackPhoto(file = file, cameraViewModel = cameraViewModel, transfersBusy = false,
            loadEnabled = loadEnabled, showPlaceholderIcon = showPlaceholderIcon, modifier = modifier)
    }
    @Composable override fun Badge(count: Int, iconSize: Dp, modifier: Modifier) {
        BurstCollectionBadge(count = count, iconSize = iconSize, modifier = modifier)
    }
}
