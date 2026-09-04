package com.ztransfer.ui.screen

import android.net.Uri
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
private val VIDEO_EXTENSIONS = setOf(".mov", ".mp4")
private const val PREVIEW_DEFERRED_LOAD_DELAY_MS = 340L
private const val FHD_REVEAL_DURATION_MS = 300L
private const val FHD_REVEAL_FRAME_MS = 16L
private const val FOUR_GIB_BYTES = 4L * 1024L * 1024L * 1024L
private const val PREVIEW_QUEUE_SWIPE_TRIGGER_DP = 96f
private const val PREVIEW_QUEUE_DIRECTION_RATIO = 1.15f
private const val PREVIEW_QUEUE_FLIGHT_DURATION_MS = 560
private const val PREVIEW_QUEUE_GHOST_PREROLL_MS = 32L
private const val PREVIEW_QUEUE_ANIMATION_TIMEOUT_MS = 1_000L

internal enum class PreviewQueueDragDirection { UNDECIDED, UPWARD, REJECTED }

internal enum class LocalOriginalPreviewRoute { DIRECT_BITMAP, RAW_EMBEDDED_JPEG, CAMERA_FHD }

internal fun localOriginalPreviewRoute(extension: String): LocalOriginalPreviewRoute = when {
    extension in NIKON_RAW_EXTENSIONS -> LocalOriginalPreviewRoute.RAW_EMBEDDED_JPEG
    extension in TIFF_EXTENSIONS -> LocalOriginalPreviewRoute.CAMERA_FHD
    else -> LocalOriginalPreviewRoute.DIRECT_BITMAP
}

internal fun <T> isLocalPreviewResolved(
    localSource: T?,
    cachedLocalSource: T?,
): Boolean = localSource != null && cachedLocalSource == localSource

/**
 * 默认缩放下只接管意图明确的上滑。横向或向下移动尽早放行，避免与翻页竞争；
 * 斜向尚未形成稳定方向时继续观察，不在触摸斜率的临界点突然抢手势。
 */
internal fun previewQueueDragDirection(
    totalDrag: Offset,
    touchSlop: Float,
): PreviewQueueDragDirection {
    if (totalDrag.getDistance() < touchSlop) return PreviewQueueDragDirection.UNDECIDED
    if (totalDrag.y >= 0f || abs(totalDrag.x) > -totalDrag.y) {
        return PreviewQueueDragDirection.REJECTED
    }
    return if (-totalDrag.y >= abs(totalDrag.x) * PREVIEW_QUEUE_DIRECTION_RATIO) {
        PreviewQueueDragDirection.UPWARD
    } else {
        PreviewQueueDragDirection.UNDECIDED
    }
}

/** 手指越过触发线后增加阻尼，既保持跟手，也避免照片被拖出过远。 */
internal fun previewQueueVisualOffset(upwardDistance: Float, triggerDistance: Float): Float {
    if (triggerDistance <= 0f) return 0f
    val distance = upwardDistance.coerceAtLeast(0f)
    val resisted = min(distance, triggerDistance) +
        max(0f, distance - triggerDistance) * 0.22f
    return -min(resisted, triggerDistance * 1.24f)
}

/** PTP DateTime（YYYYMMDDThhmmss…）转为预览页使用的稳定本地格式。 */
internal fun formatPreviewCaptureDate(raw: String?): String? {
    if (raw == null || raw.length < 8 || !raw.take(8).all(Char::isDigit)) return null
    val year = raw.substring(0, 4).toInt()
    val month = raw.substring(4, 6).toInt()
    val day = raw.substring(6, 8).toInt()
    runCatching { java.time.LocalDate.of(year, month, day) }.getOrNull() ?: return null
    val date = "%04d-%02d-%02d".format(year, month, day)
    if (raw.length < 15 || raw[8] != 'T' || !raw.substring(9, 15).all(Char::isDigit)) {
        return date
    }
    val hour = raw.substring(9, 11).toInt()
    val minute = raw.substring(11, 13).toInt()
    val second = raw.substring(13, 15).toInt()
    runCatching { java.time.LocalTime.of(hour, minute, second) }.getOrNull() ?: return date
    return "$date %02d:%02d:%02d".format(hour, minute, second)
}

internal fun videoPreviewMetadata(
    fileSize: Long,
    captureDate: String?,
    overFourGbLabel: String,
): String = listOfNotNull(
    when {
        fileSize == PtpConstants.SIZE_UNKNOWN || fileSize > FOUR_GIB_BYTES -> overFourGbLabel
        fileSize > 0L -> formatFileSize(fileSize)
        else -> null
    },
    formatPreviewCaptureDate(captureDate),
).joinToString("  ·  ")

/** 预览分页模型与列表展示模型同构：合集是独立页面，不伪装成其中某张照片。 */
internal sealed interface PhotoPreviewItem {
    val key: Any

    data class Photo(
        val file: CameraFileInfo,
        val burstId: String? = null
    ) : PhotoPreviewItem {
        override val key: Any = file.handle
    }

    data class BurstCollection(
        val id: String,
        val files: List<CameraFileInfo>
    ) : PhotoPreviewItem {
        override val key: Any = "preview_burst_$id"
    }
}

/**
 * 固定一次全屏预览会话能够看到的本地原图来源。
 *
 * 传输可能在 overlay 存活期间完成，但此时不能把正在淡入、缩放或绘制的相机 FHD
 * 热替换成完整原图。除了可能重置手势观感，这还会让旧 FHD 与大尺寸本地位图在同一帧
 * 参与纹理上传，造成明显的内存峰值，部分设备会直接崩溃。下次重新打开 overlay 时会
 * 创建新快照，自然获得刚传完的原图。合集成员也必须在打开时一起冻结，否则展开合集
 * 会绕过同一会话规则。
 */
internal fun <T> snapshotPreviewSessionSources(
    items: List<PhotoPreviewItem>,
    sourceFor: (CameraFileInfo) -> T?,
): Map<Int, T?> = buildMap {
    items.forEach { item ->
        when (item) {
            is PhotoPreviewItem.Photo -> put(item.file.handle, sourceFor(item.file))
            is PhotoPreviewItem.BurstCollection -> item.files.forEach { file ->
                put(file.handle, sourceFor(file))
            }
        }
    }
}

internal fun isPreviewBurstExpanded(
    items: List<PhotoPreviewItem>,
    collectionPage: Int,
    burstId: String
): Boolean =
    (items.getOrNull(collectionPage + 1) as? PhotoPreviewItem.Photo)?.burstId == burstId

internal fun expandPreviewBurst(
    items: List<PhotoPreviewItem>,
    collectionPage: Int,
    collection: PhotoPreviewItem.BurstCollection
): List<PhotoPreviewItem> {
    if (isPreviewBurstExpanded(items, collectionPage, collection.id)) return items
    val members = collection.files.map { file ->
        PhotoPreviewItem.Photo(file = file, burstId = collection.id)
    }
    return buildList(items.size + members.size) {
        addAll(items.take(collectionPage + 1))
        addAll(members)
        addAll(items.drop(collectionPage + 1))
    }
}

internal fun collapsePreviewBurst(
    items: List<PhotoPreviewItem>,
    burstId: String
): List<PhotoPreviewItem> =
    items.filterNot { it is PhotoPreviewItem.Photo && it.burstId == burstId }

/** 当前页必须是合集之后的真实成员；成员数量和所在序号不会影响返回的合集页。 */
internal fun previewBurstCollectionPage(
    items: List<PhotoPreviewItem>,
    memberPage: Int,
): Int? {
    val burstId = (items.getOrNull(memberPage) as? PhotoPreviewItem.Photo)?.burstId
        ?: return null
    val collectionPage = items.indexOfFirst {
        it is PhotoPreviewItem.BurstCollection && it.id == burstId
    }
    return collectionPage.takeIf { it in 0 until memberPage }
}

/**
 * 大图期间默认禁止远程缩略图；只有当前页 FHD 已确认不可用且 EXIF 已收尾时才兜底。
 */
internal fun allowPreviewRemoteThumbnailFallback(
    isCurrent: Boolean,
    fhdUnavailable: Boolean,
    exifFinished: Boolean,
): Boolean = isCurrent && fhdUnavailable && exifFinished

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
    // 会话内固定持有自己的分页快照；后台增量加载/筛选不会让正在看的页突然换内容。
    // 只有用户在合集页主动展开/收起时，才在当前页后插入/移除该组成员。
    var previewItems by remember { mutableStateOf(items) }
    val pagerState = rememberPagerState(initialPage = initialIndex) { previewItems.size }
    val currentItem = previewItems.getOrNull(pagerState.currentPage)
    val currentFile = (currentItem as? PhotoPreviewItem.Photo)?.file
    val currentHandle = currentFile?.handle
    val previewScope = rememberCoroutineScope()
    val contentResolver = LocalContext.current.contentResolver
    val cameraState by cameraViewModel.state.collectAsState()
    val currentTransfersBusy by rememberUpdatedState(transfersBusy)
    var previousTransfersBusy by remember { mutableStateOf(transfersBusy) }
    var overlayBounds by remember { mutableStateOf<Rect?>(null) }
    var collapseAnchorRect by remember { mutableStateOf(anchorRect) }
    val progress = remember { Animatable(0f) }
    var closing by remember { mutableStateOf(false) }
    var burstTransitionBusy by remember { mutableStateOf(false) }
    val latestCurrentFile by rememberUpdatedState(currentFile)
    val latestPrepareDismissTarget by rememberUpdatedState(prepareDismissTarget)
    val latestOnDismiss by rememberUpdatedState(onDismiss)
    // 本次 overlay 打开时已经存在的原图可以直接使用；打开后才完成的传输不热切换。
    // remember 不带动态传输状态 key 是有意的：关闭并重新进入才创建下一份来源快照。
    val sessionLocalOriginalUris = remember {
        snapshotPreviewSessionSources(items, localOriginalUriFor)
    }
    val sessionLocalOriginalUriFor: (CameraFileInfo) -> Uri? = remember(
        sessionLocalOriginalUris,
    ) {
        { file -> sessionLocalOriginalUris[file.handle] }
    }
    // 高清图/EXIF 到位会触发大位图纹理上传与预览子树更新，因此稍延后启动。
    // 这个功能门绝不能依赖 progress.animateTo 返回：某些设备动画帧时钟停滞时，
    // 等动画完成会让 FHD、EXIF 和远程缩略图全部永久不启动。
    var deferredLoadsEnabled by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        delay(PREVIEW_DEFERRED_LOAD_DELAY_MS)
        if (!closing) deferredLoadsEnabled = true
    }

    LaunchedEffect(overlayBounds, closing) {
        if (!closing && overlayBounds != null && progress.value < 1f) {
            progress.animateTo(1f, Motion.overlayExpand)
        }
    }
    LaunchedEffect(closing) {
        if (closing) {
            // 长列表的远距离预定位发生在不透明预览层之后；随后才向最新格子坐标缩回，
            // 因此既不会暴露 LazyGrid 的长距离跳段，也不会飞回已经失效的旧格位。
            val returnFile = latestCurrentFile
            collapseAnchorRect = returnFile?.let { latestPrepareDismissTarget(it) }
            progress.animateTo(0f, Motion.overlayCollapse)
            latestOnDismiss(returnFile.takeIf { collapseAnchorRect != null })
        }
    }
    // 连拍过渡只有约 260ms；这段时间吞掉关闭请求，避免在不可见切页的单帧里
    // 把合集页误当成“当前照片”参与退出定位。
    val startClose: () -> Unit = {
        if (!burstTransitionBusy) closing = true
    }
    BackHandler(enabled = !closing) { startClose() }

    // ---- 高清预览：当前本地原图保持完整分辨率；相机回退仍使用 FHD ----
    // 状态图按 handle 存储；handle 仅在本 overlay 存活期有效（关闭随 Composable 释放）。
    val highResolutionBitmaps = remember { mutableStateMapOf<Int, ImageBitmap>() }
    val highResolutionLoading = remember { mutableStateMapOf<Int, Boolean>() }
    // 仅记录由本地原图生成的高清位图来源。同一会话使用打开时的来源快照，因此这里
    // 只负责避免重复解码，不会在传输完成瞬间替换正在显示的相机 FHD。
    val localPreviewUris = remember { mutableStateMapOf<Int, Uri>() }
    // 本地原图或 RAW 内嵌预览仍可能因损坏、权限或格式异常解码失败；按 URI 记住失败结果，
    // 本次预览不反复读盘，但仍会正常回退到相机 FHD。
    val localDecodeFailures = remember { mutableStateMapOf<Int, Uri>() }
    // 只有当前照片的 FHD 确认不可用、且当前 EXIF 已经读取完毕后，才允许向相机请求
    // 一张缩略图兜底。这样占位图不会跑到 FHD / EXIF 前面争抢相机通道。
    val fhdUnavailable = remember { mutableStateMapOf<Int, Boolean>() }
    // PreviewPage owns thumbnail fallback loading. Publish the actual bitmap it renders so the
    // shared monitor histogram can analyse that exact image without another decode or camera read.
    val displayedBitmaps = remember { mutableStateMapOf<Int, ImageBitmap>() }
    val exifData = remember { mutableStateMapOf<Int, PhotoExif?>() }
    val exifLoading = remember { mutableStateMapOf<Int, Boolean>() }
    val exifFinished = remember { mutableStateMapOf<Int, Boolean>() }
    // 初始方向来自全局偏好；本 overlay 内不取模，每次继续减 90°，
    // 动画始终沿逆时针最短方向旋转。翻页不重置，所有照片共用。
    var rotationDegrees by remember {
        mutableFloatStateOf(-90f * Math.floorMod(initialRotationQuarterTurns, 4))
    }
    val haptics = rememberHaptics(hapticsEnabled)
    val density = LocalDensity.current
    val queueSwipeTriggerPx = with(density) { PREVIEW_QUEUE_SWIPE_TRIGGER_DP.dp.toPx() }
    val queueThrowApexPx = with(density) { 132.dp.toPx() }
    val currentOnTransfer by rememberUpdatedState(onTransfer)
    val currentOnTransferBurst by rememberUpdatedState(onTransferBurst)
    val currentQueueTargetBounds by rememberUpdatedState(queueTargetBounds)
    val currentOnQueueFlightCaught by rememberUpdatedState(onQueueFlightCaught)
    val histogramSource = currentHandle?.let(displayedBitmaps::get)
    val previewHistogram by produceState<LuminanceHistogram?>(
        initialValue = null,
        histogramVisible,
        currentHandle,
        histogramSource,
    ) {
        value = null
        if (histogramVisible && histogramSource != null &&
            currentFile.extension !in VIDEO_EXTENSIONS
        ) {
            value = withContext(Dispatchers.Default) {
                calculateLuminanceHistogram(histogramSource.asAndroidBitmap())
            }
        }
    }

    // 预览入队只变换 Pager 图层，并用当前已解码位图多绘制一个短命影子：不复制 Bitmap、
    // 不重新读取相机，也不创建列表 QueueFlight；抵达时仅触发现有胶囊视觉回弹。
    var currentZoomed by remember { mutableStateOf(false) }
    var queueGestureActive by remember { mutableStateOf(false) }
    var queueAnimating by remember { mutableStateOf(false) }
    var queueOffsetY by remember { mutableFloatStateOf(0f) }
    var queueFlightProgress by remember { mutableFloatStateOf(0f) }
    var queueFlightBitmap by remember { mutableStateOf<ImageBitmap?>(null) }
    var queueFlightBurstFiles by remember {
        mutableStateOf<List<CameraFileInfo>?>(null)
    }
    var queueFlightRotation by remember { mutableFloatStateOf(0f) }
    var queueFlightTarget by remember { mutableStateOf<Rect?>(null) }
    var queueMotionJob by remember { mutableStateOf<Job?>(null) }
    // 连拍展开/收起只驱动 Pager 与合集卡片的图层，不复制位图，也不创建额外页面。
    // 收起时必须先回到仍存在的合集页，再移除成员，避免页数骤减造成闪现或越界。
    val burstStackMotion = remember { Animatable(0f) }
    val burstPagerScale = remember { Animatable(1f) }
    val burstPagerAlpha = remember { Animatable(1f) }
    // 归组时用归一化屏宽位移模拟一次“返回左侧合集页”，不横穿中间所有成员。
    val burstPagerSlide = remember { Animatable(0f) }
    var animatedBurstId by remember { mutableStateOf<String?>(null) }

    fun settleQueuePhoto() {
        queueMotionJob?.cancel()
        val start = queueOffsetY
        if (abs(start) < 0.5f) {
            queueOffsetY = 0f
            return
        }
        queueMotionJob = previewScope.launch {
            Animatable(start).animateTo(
                targetValue = 0f,
                animationSpec = spring(
                    dampingRatio = 0.82f,
                    stiffness = Spring.StiffnessMediumLow,
                ),
            ) { queueOffsetY = value }
        }
    }

    fun startPreviewQueueFlight(
        bitmap: ImageBitmap?,
        rotation: Float,
        burstFiles: List<CameraFileInfo>? = null,
        enqueue: () -> Boolean,
    ) {
        if (queueAnimating || closing) return
        // 父层先完成目录/连接校验并确认真实入队；被拒绝时不抬图、不放残影、
        // 不触发胶囊接收，避免视觉反馈与实际队列相矛盾。
        if (!enqueue()) return
        queueMotionJob?.cancel()
        queueGestureActive = false
        queueAnimating = true
        queueFlightProgress = 0f
        queueFlightRotation = rotation
        queueFlightTarget = currentQueueTargetBounds
        queueFlightBitmap = bitmap
        queueFlightBurstFiles = burstFiles

        queueMotionJob = previewScope.launch {
            try {
                // 极少数设备的 Compose 帧钟可能暂停；超时只兜底复位视觉状态，
                // 入队已在上方同步提交，绝不会因动画未返回而锁死后续操作。
                withTimeoutOrNull(PREVIEW_QUEUE_ANIMATION_TIMEOUT_MS) {
                    coroutineScope {
                        launch {
                            val riseDuration = if (queueOffsetY < -1f) 105 else 155
                            Animatable(queueOffsetY).animateTo(
                                targetValue = -queueThrowApexPx,
                                animationSpec = tween(riseDuration, easing = FastOutSlowInEasing),
                            ) { queueOffsetY = value }
                            Animatable(queueOffsetY).animateTo(
                                targetValue = 0f,
                                animationSpec = spring(
                                    dampingRatio = 0.78f,
                                    stiffness = Spring.StiffnessMedium,
                                ),
                            ) { queueOffsetY = value }
                        }
                        launch {
                            if ((queueFlightBitmap != null || queueFlightBurstFiles != null) &&
                                queueFlightTarget != null
                            ) {
                                delay(PREVIEW_QUEUE_GHOST_PREROLL_MS)
                                Animatable(0f).animateTo(
                                    targetValue = 1f,
                                    animationSpec = tween(
                                        PREVIEW_QUEUE_FLIGHT_DURATION_MS,
                                        easing = QueueFlightEasing,
                                    ),
                                ) { queueFlightProgress = value }
                            }
                            // 与列表 QueueFlightGhost 同一时机：残影真正抵达后才让胶囊接住。
                            currentOnQueueFlightCaught()
                        }
                    }
                }
            } finally {
                queueOffsetY = 0f
                queueFlightProgress = 0f
                queueFlightBitmap = null
                queueFlightBurstFiles = null
                queueFlightTarget = null
                queueAnimating = false
                queueMotionJob = null
            }
        }
    }

    fun enqueueFromPreview(file: CameraFileInfo) {
        // FHD 已经在屏幕上时直接复用；否则复用打开预览所用的缓存缩略图。
        // 先挂载 alpha=0 的影子并预留两帧，再开始飞行，避免首次绘制纹理闪现。
        val bitmap = highResolutionBitmaps[file.handle]
            ?: cameraViewModel.cachedThumbnail(file.handle)
        startPreviewQueueFlight(bitmap, rotationDegrees) {
            currentOnTransfer(file)
        }
    }

    fun enqueueBurstFromPreview(collection: PhotoPreviewItem.BurstCollection) {
        if (collection.files.isEmpty()) return
        startPreviewQueueFlight(
            bitmap = null,
            rotation = 0f,
            burstFiles = collection.files,
        ) {
            currentOnTransferBurst(collection.files)
        }
    }

    LaunchedEffect(currentItem?.key) {
        // 翻页时绝不把上一张尚未结束的拖动/影子带到新页。
        queueMotionJob?.cancel()
        queueOffsetY = 0f
        queueFlightProgress = 0f
        queueFlightBitmap = null
        queueFlightBurstFiles = null
        queueFlightTarget = null
        queueGestureActive = false
        queueAnimating = false
    }

    val expandPreviewBurstCollection: (PhotoPreviewItem.BurstCollection) -> Unit =
        expand@{ collection ->
            if (closing || burstTransitionBusy || collection.files.isEmpty()) return@expand
            val page = pagerState.currentPage
            if (previewItems.getOrNull(page) != collection) return@expand
            val alreadyExpanded = isPreviewBurstExpanded(previewItems, page, collection.id)
            burstTransitionBusy = true
            animatedBurstId = collection.id
            haptics.tick()
            previewScope.launch {
                try {
                    // 这个按钮永远只表示“展开并进入第一张”，不根据 expanded 改图标或语义。
                    // 用户滑回已展开的合集页再次点击时，只回到第一张，不重复更新列表模型。
                    burstStackMotion.snapTo(0f)
                    if (!alreadyExpanded) {
                        previewItems = expandPreviewBurst(previewItems, page, collection)
                        onBurstExpandedChange(collection.id, true)
                        withFrameNanos { }
                    }
                    coroutineScope {
                        launch {
                            burstStackMotion.animateTo(
                                1f,
                                tween(165, easing = FastOutSlowInEasing),
                            )
                        }
                        launch {
                            delay(24)
                            pagerState.animateScrollToPage(
                                page = page + 1,
                                animationSpec = tween(205, easing = FastOutSlowInEasing),
                            )
                        }
                    }
                } finally {
                    burstStackMotion.snapTo(0f)
                    burstPagerScale.snapTo(1f)
                    burstPagerAlpha.snapTo(1f)
                    burstPagerSlide.snapTo(0f)
                    animatedBurstId = null
                    burstTransitionBusy = false
                }
            }
        }

    val collapsePreviewBurstMember: (String) -> Unit = collapseMember@{ burstId ->
        if (closing || burstTransitionBusy || queueAnimating || queueGestureActive ||
            queueMotionJob?.isActive == true
        ) {
            return@collapseMember
        }
        val memberPage = pagerState.currentPage
        val member = previewItems.getOrNull(memberPage) as? PhotoPreviewItem.Photo
            ?: return@collapseMember
        if (member.burstId != burstId) return@collapseMember
        val collectionPage = previewBurstCollectionPage(previewItems, memberPage)
            ?: return@collapseMember

        burstTransitionBusy = true
        animatedBurstId = burstId
        haptics.tick()
        previewScope.launch {
            try {
                // 无论当前是第几张，都模拟一次标准的“返回上一页”：成员向右离场，
                // 合集从左侧进入。在不可见的交接帧定位合集，避免横穿几十张成员。
                burstStackMotion.snapTo(1f)
                coroutineScope {
                    launch {
                        burstPagerScale.animateTo(
                            0.985f,
                            tween(120, easing = FastOutSlowInEasing),
                        )
                    }
                    launch {
                        burstPagerAlpha.animateTo(
                            0f,
                            tween(120, easing = FastOutSlowInEasing),
                        )
                    }
                    launch {
                        burstPagerSlide.animateTo(
                            0.22f,
                            tween(120, easing = FastOutSlowInEasing),
                        )
                    }
                }
                pagerState.scrollToPage(collectionPage)

                // 当前页已经稳定落在合集上，此时原子移除成员不会改变用户正在看的页面。
                previewItems = collapsePreviewBurst(previewItems, burstId)
                onBurstExpandedChange(burstId, false)
                burstPagerSlide.snapTo(-0.22f)
                withFrameNanos { }
                coroutineScope {
                    launch {
                        burstStackMotion.animateTo(
                            0f,
                            spring(
                                dampingRatio = 0.7f,
                                stiffness = Spring.StiffnessHigh,
                            ),
                        )
                    }
                    launch {
                        burstPagerScale.animateTo(
                            1f,
                            spring(
                                dampingRatio = 0.68f,
                                stiffness = Spring.StiffnessHigh,
                            ),
                        )
                    }
                    launch {
                        burstPagerAlpha.animateTo(
                            1f,
                            tween(150, easing = FastOutSlowInEasing),
                        )
                    }
                    launch {
                        burstPagerSlide.animateTo(
                            0f,
                            tween(165, easing = FastOutSlowInEasing),
                        )
                    }
                }
            } finally {
                burstStackMotion.snapTo(0f)
                burstPagerScale.snapTo(1f)
                burstPagerAlpha.snapTo(1f)
                burstPagerSlide.snapTo(0f)
                animatedBurstId = null
                burstTransitionBusy = false
            }
        }
    }

    // 预览期间暂停后台缩略图填充，把 ioMutex 让给 FHD/EXIF 取图。
    DisposableEffect(Unit) {
        cameraViewModel.setFhdActive(true)
        onDispose { cameraViewModel.setFhdActive(false) }
    }

    // 加载单页高清图：普通照片读取本地完整原图，NEF/NRW 提取最大内嵌 JPEG，
    // TIFF 直接请求相机 FHD；视频继续使用既有封面分支。当前页与邻页共用同一规则。
    // 返回 true 表示本次确实取到并解码成功（用于当前页到位的触感反馈）。
    suspend fun loadHighResolutionPage(
        page: Int,
        awaitExisting: Boolean = false,
        allowCameraRequest: Boolean,
    ): Boolean {
        val file = (previewItems.getOrNull(page) as? PhotoPreviewItem.Photo)?.file
            ?: return false
        val h = file.handle
        val localUri = sessionLocalOriginalUriFor(file)
        val localPreviewRoute = localOriginalPreviewRoute(file.extension)
        // 视频没有高清封面（FHD 操作码只对照片有效），不发注定失败的请求、也不显示加载条。
        if (file.extension in VIDEO_EXTENSIONS) {
            fhdUnavailable[h] = true
            return false
        }
        if (h in highResolutionBitmaps) {
            val cachedLocalUri = localPreviewUris[h]
            if (cachedLocalUri != null && cachedLocalUri != localUri) {
                highResolutionBitmaps.remove(h)
                displayedBitmaps.remove(h)
                localPreviewUris.remove(h)
            } else if (localUri == null || cachedLocalUri == localUri) {
                fhdUnavailable.remove(h)
                return false
            }
        }
        if (highResolutionLoading.containsKey(h)) {
            if (!awaitExisting) return false
            // 当前页可能正由上一页的预取任务加载。等待它完成；若它因翻页被取消，
            // loading 会在 finally 中释放，随后由当前页重新发起，绝不漏载。
            while (highResolutionLoading.containsKey(h) && h !in highResolutionBitmaps) delay(16)
            if (h in highResolutionBitmaps) return false
        }
        fhdUnavailable.remove(h)
        highResolutionLoading[h] = true
        try {
            if (localUri != null &&
                localPreviewRoute != LocalOriginalPreviewRoute.CAMERA_FHD &&
                localDecodeFailures[h] != localUri
            ) {
                val localPreview = try {
                    withContext(Dispatchers.IO) {
                        val sourceUri = localUri
                        val bitmap = when (localPreviewRoute) {
                            LocalOriginalPreviewRoute.RAW_EMBEDDED_JPEG ->
                                PhotoFrameExporter.decodeRawEmbeddedPreview(contentResolver, sourceUri)
                            LocalOriginalPreviewRoute.DIRECT_BITMAP ->
                                PhotoFrameExporter.decodeOriginalPreview(contentResolver, sourceUri)
                            LocalOriginalPreviewRoute.CAMERA_FHD -> null
                        }
                        bitmap?.asImageBitmap()
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    null
                }
                if (localPreview != null) {
                    highResolutionBitmaps[h] = localPreview
                    localPreviewUris[h] = localUri
                    fhdUnavailable.remove(h)
                    localDecodeFailures.remove(h)
                    return true
                }
                localDecodeFailures[h] = localUri
            }
            // 相机 FHD 已经存在且本地原图不可解码时，继续复用现有位图，不重复请求相机。
            if (h in highResolutionBitmaps) return false
            // 本地预览不依赖相机连接。没有本地可用图时等待连接状态变化后再回退，
            // 不能把“当前离线”永久记成 FHD 不可用。
            if (!allowCameraRequest) return false
            val res = cameraViewModel.loadFhdPreview(file) ?: run {
                fhdUnavailable[h] = true
                return false
            }
            highResolutionBitmaps[h] = res
            localPreviewUris.remove(h)
            fhdUnavailable.remove(h)
            return true
        } finally {
            highResolutionLoading.remove(h)
        }
    }

    // 加载单页 EXIF（仅当前页，不预加载邻居——EXIF 只在当前页底栏显示，预加载纯浪费通道）。
    suspend fun loadExifPage(page: Int) {
        val file = (previewItems.getOrNull(page) as? PhotoPreviewItem.Photo)?.file
            ?: return
        val h = file.handle
        if (h in exifData || exifLoading.containsKey(h)) return
        exifFinished.remove(h)
        exifLoading[h] = true
        try {
            val localUri = sessionLocalOriginalUriFor(file)
            exifData[h] = if (localUri != null) {
                cameraViewModel.loadLocalExif(file, localUri)
            } else {
                cameraViewModel.loadExif(file)
            }
            exifFinished[h] = true
        } finally {
            exifLoading.remove(h)
        }
    }

    // 即时淘汰（独立 effect，翻页瞬间就跑，不排在 1–3s 的慢加载后面）：保留窗口 ±2。
    // 与加载解耦是关键——否则快速翻页时淘汰永远排在慢加载之后、来不及执行，内存会一路涨。
    LaunchedEffect(previewItems, pagerState.currentPage, currentHandle) {
        val cp = pagerState.currentPage
        val keep = (cp - 2).coerceAtLeast(0)..(cp + 2).coerceAtMost(previewItems.lastIndex)
        val keepH = keep.mapNotNull { page ->
            (previewItems.getOrNull(page) as? PhotoPreviewItem.Photo)?.file?.handle
        }.toSet()
        highResolutionBitmaps.keys
            .filter { it !in keepH }
            .forEach { highResolutionBitmaps.remove(it) }
        localPreviewUris.keys.filter { it !in keepH }.forEach { localPreviewUris.remove(it) }
        displayedBitmaps.keys.filter { it !in keepH }.forEach { displayedBitmaps.remove(it) }
        fhdUnavailable.keys.filter { it !in keepH }.forEach { fhdUnavailable.remove(it) }
        localDecodeFailures.keys.filter { it !in keepH }.forEach { localDecodeFailures.remove(it) }
        exifData.keys.filter { it !in keepH }.forEach { exifData.remove(it) }
        exifFinished.keys.filter { it !in keepH }.forEach { exifFinished.remove(it) }
    }

    val currentLocalOriginalUri = currentFile?.let(sessionLocalOriginalUriFor)

    // 当前页拥有最高优先级。会话快照中的本地 URI 与连接状态纳入 key；传输在本次预览
    // 期间完成不会改变该 URI，因而不会取消当前任务或热替换位图。关闭后重新进入时，
    // 新 overlay 会捕获已完成传输的本地 URI。本地不可用且断线后原地重连时仍可重新请求 FHD。
    // 当前页与邻页由同一协程严格串行，避免首次失败时两个 effect 重复请求并触发熔断。
    LaunchedEffect(
        previewItems,
        pagerState.currentPage,
        currentHandle,
        currentLocalOriginalUri,
        cameraState.isConnectedToCamera,
        deferredLoadsEnabled
    ) {
        if (!deferredLoadsEnabled) return@LaunchedEffect
        val cp = pagerState.currentPage
        val loadedCurrent = loadHighResolutionPage(
            page = cp,
            awaitExisting = true,
            allowCameraRequest = false,
        )
        if (loadedCurrent) haptics.tick()
        val resolvedLocally = currentHandle?.let { handle ->
            isLocalPreviewResolved(
                localSource = currentLocalOriginalUri,
                cachedLocalSource = localPreviewUris[handle],
            )
        } == true
        if (resolvedLocally) {
            // 图片和 EXIF 都直接读取本地文件，不进入相机交互优先窗口。
            loadExifPage(cp)
        } else if (cameraState.isConnectedToCamera) {
            cameraViewModel.withInteractivePreviewPriority {
                if (
                    loadHighResolutionPage(
                        page = cp,
                        awaitExisting = true,
                        allowCameraRequest = true,
                    )
                ) {
                    haptics.tick()
                }
                loadExifPage(cp)
            }
        }
        val allowNeighborCameraRequest = !currentTransfersBusy &&
            cameraState.isConnectedToCamera
        if (cp > 0) {
            loadHighResolutionPage(
                page = cp - 1,
                allowCameraRequest = allowNeighborCameraRequest,
            )
        }
        if (cp < previewItems.lastIndex) {
            loadHighResolutionPage(
                page = cp + 1,
                allowCameraRequest = allowNeighborCameraRequest,
            )
        }
    }

    // 上面的主加载不能把 transfersBusy 放进 key，否则状态变化会取消正在读取的 PTP
    // 事务。这里仅监听“忙→闲”，在用户仍停留当前页时补上此前跳过的邻页预取。
    LaunchedEffect(transfersBusy) {
        val shouldResumePrefetch = previousTransfersBusy && !transfersBusy
        previousTransfersBusy = transfersBusy
        if (!shouldResumePrefetch || !deferredLoadsEnabled) {
            return@LaunchedEffect
        }
        val cp = pagerState.currentPage
        val allowNeighborCameraRequest = cameraState.isConnectedToCamera
        if (cp > 0) {
            loadHighResolutionPage(
                page = cp - 1,
                allowCameraRequest = allowNeighborCameraRequest,
            )
        }
        if (cp < previewItems.lastIndex) {
            loadHighResolutionPage(
                page = cp + 1,
                allowCameraRequest = allowNeighborCameraRequest,
            )
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .onGloballyPositioned { overlayBounds = it.boundsInRoot() }
            .pointerInput(currentHandle, currentZoomed, queueAnimating, closing) {
                val touchSlop = viewConfiguration.touchSlop
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val file = currentFile
                    val canSwipeToQueue =
                        file != null && !currentZoomed && !queueAnimating && !closing &&
                            progress.value >= 0.99f && !pagerState.isScrollInProgress &&
                            abs(pagerState.currentPageOffsetFraction) < 0.01f

                    if (!canSwipeToQueue) {
                        // 保留原有的全屏遮挡语义：深层缩放/翻页先消费，剩余拖动由预览层
                        // 吃掉，绝不穿透到底下仍存活的照片网格。
                        do {
                            val event = awaitPointerEvent()
                            event.changes.forEach { change ->
                                if (!change.isConsumed && change.position != change.previousPosition) {
                                    change.consume()
                                }
                            }
                        } while (event.changes.any { it.pressed })
                        return@awaitEachGesture
                    }
                    val queueFile = requireNotNull(file)

                    queueMotionJob?.cancel()
                    queueOffsetY = 0f
                    var totalDrag = Offset.Zero
                    var direction = PreviewQueueDragDirection.UNDECIDED
                    do {
                        val event = awaitPointerEvent()
                        val pressedCount = event.changes.count { it.pressed }
                        val change = event.changes.firstOrNull { it.id == down.id }

                        if (pressedCount > 1 || currentZoomed) {
                            direction = PreviewQueueDragDirection.REJECTED
                            queueGestureActive = false
                            settleQueuePhoto()
                        } else if (change != null && direction != PreviewQueueDragDirection.REJECTED) {
                            totalDrag += change.position - change.previousPosition
                            if (direction == PreviewQueueDragDirection.UNDECIDED) {
                                direction = if (change.isConsumed) {
                                    PreviewQueueDragDirection.REJECTED
                                } else {
                                    previewQueueDragDirection(totalDrag, touchSlop)
                                }
                                if (direction == PreviewQueueDragDirection.UPWARD) {
                                    queueGestureActive = true
                                }
                            }
                            if (direction == PreviewQueueDragDirection.UPWARD) {
                                change.consume()
                                queueOffsetY = previewQueueVisualOffset(
                                    upwardDistance = -totalDrag.y,
                                    triggerDistance = queueSwipeTriggerPx,
                                )
                            }
                        }
                    } while (event.changes.any { it.pressed })

                    if (direction == PreviewQueueDragDirection.UPWARD) {
                        queueGestureActive = false
                        if (-totalDrag.y >= queueSwipeTriggerPx) {
                            enqueueFromPreview(queueFile)
                        } else {
                            settleQueuePhoto()
                        }
                    }
                }
            }
    ) {
        // 黑色背景：随进度淡入。
        Box(
            modifier = Modifier
                .fillMaxSize()
                // 透明黑直接绘制，不让 graphicsLayer(alpha) 创建全屏离屏缓冲。
                .drawBehind {
                    drawRect(Color.Black, alpha = 0.74f * progress.value)
                }
        )

        // 图片翻页器：整体从被长按格子的位置缩放展开。相邻页预载一页，快速翻页不用等图。
        HorizontalPager(
            state = pagerState,
            beyondViewportPageCount = 1,
            key = { page -> previewItems[page].key },
            userScrollEnabled = !currentZoomed && !queueGestureActive && !queueAnimating &&
                !burstTransitionBusy,
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    val ob = overlayBounds
                    val ar = if (closing) collapseAnchorRect else anchorRect
                    val queueLift =
                        (-queueOffsetY / queueSwipeTriggerPx).coerceIn(0f, 1.24f)
                    val queueScale = 1f - min(queueLift, 1f) * 0.055f
                    val queueAlpha = 1f - min(queueLift, 1f) * 0.07f
                    var baseScale = 1f
                    var baseAlpha = progress.value
                    // 打开阶段只认最初格子；关闭阶段已经重新定位并测得当前照片的新坐标，
                    // 因此翻页后也能缩回正在看的那张，而不是退回旧格位或只做无方向淡出。
                    val shrinkToAnchor = if (closing) ar != null
                        else pagerState.currentPage == initialIndex
                    if (shrinkToAnchor && ob != null && ar != null && ob.width > 0f && ob.height > 0f) {
                        transformOrigin = TransformOrigin(
                            (ar.center.x - ob.left) / ob.width,
                            (ar.center.y - ob.top) / ob.height
                        )
                        val startScale = (ar.width / ob.width).coerceIn(0.05f, 1f)
                        baseScale = startScale + (1f - startScale) * progress.value
                        // 打开首帧就绘制已缓存的源缩略图，避免 overlay 已挂载但动画尚未
                        // 前进时整块图片透明、短暂透出照片列表。关闭时仍随缩回过程淡出，
                        // 与底层原格子自然交接。
                        baseAlpha = if (closing) {
                            (progress.value * 1.6f).coerceAtMost(1f)
                        } else {
                            1f
                        }
                    }
                    if (queueLift > 0f || burstPagerScale.value != 1f) {
                        transformOrigin = TransformOrigin.Center
                    }
                    scaleX = baseScale * queueScale * burstPagerScale.value
                    scaleY = baseScale * queueScale * burstPagerScale.value
                    translationX = size.width * burstPagerSlide.value
                    translationY = queueOffsetY
                    alpha = baseAlpha * queueAlpha * burstPagerAlpha.value
                }
        ) { page ->
            when (val item = previewItems[page]) {
                is PhotoPreviewItem.Photo -> {
                    val file = item.file
                    PreviewPage(
                        file = file,
                        cameraViewModel = cameraViewModel,
                        fhdBitmap = highResolutionBitmaps[file.handle],
                        isLoadingFhd = highResolutionLoading.containsKey(file.handle),
                        allowRemoteThumbnailFallback = allowPreviewRemoteThumbnailFallback(
                            isCurrent = page == pagerState.currentPage,
                            fhdUnavailable = fhdUnavailable[file.handle] == true,
                            exifFinished = exifFinished[file.handle] == true,
                        ),
                        loadEnabled = deferredLoadsEnabled,
                        rotationDegrees = rotationDegrees,
                        isCurrent = page == pagerState.currentPage,
                        onDisplayBitmapChanged = { bitmap ->
                            if (bitmap == null) displayedBitmaps.remove(file.handle)
                            else displayedBitmaps[file.handle] = bitmap
                        },
                        onZoomedChange = { currentZoomed = it },
                        onTap = startClose
                    )
                }
                is PhotoPreviewItem.BurstCollection -> {
                    BurstCollectionPreviewPage(
                        collection = item,
                        cameraViewModel = cameraViewModel,
                        loadEnabled = deferredLoadsEnabled,
                        isCurrent = page == pagerState.currentPage,
                        onZoomedChange = { currentZoomed = it },
                        stackMotionProgress = {
                            if (animatedBurstId == item.id) burstStackMotion.value else 0f
                        },
                        onTap = startClose
                    )
                }
            }
        }

        // 入队影子与主图使用同一份已解码纹理。它在 alpha=0 时预挂载两帧，随后按
        // 列表 QueueFlightGhost 的同款二次贝塞尔弧线加速吸入真实胶囊；主图同时回位，
        // 因此没有消失后闪回的断帧，也不会出现直线飞行的机械感。
        queueFlightBitmap?.let { bitmap ->
            Image(
                bitmap = bitmap,
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        val p = queueFlightProgress.coerceIn(0f, 1f)
                        val viewportWidth = size.width
                        val viewportHeight = size.height
                        val rawAspect = bitmap.width.toFloat() / bitmap.height.coerceAtLeast(1)
                        val viewportAspect = viewportWidth / viewportHeight.coerceAtLeast(1f)
                        val baseWidth = if (rawAspect > viewportAspect) {
                            viewportWidth
                        } else {
                            viewportHeight * rawAspect
                        }
                        val baseHeight = if (rawAspect > viewportAspect) {
                            viewportWidth / rawAspect
                        } else {
                            viewportHeight
                        }
                        val angle = Math.toRadians(queueFlightRotation.toDouble())
                        val rotatedWidth =
                            baseWidth * abs(cos(angle)).toFloat() +
                                baseHeight * abs(sin(angle)).toFloat()
                        val rotatedHeight =
                            baseWidth * abs(sin(angle)).toFloat() +
                                baseHeight * abs(cos(angle)).toFloat()
                        val rotationFit = if (rotatedWidth > 0f && rotatedHeight > 0f) {
                            min(viewportWidth / rotatedWidth, viewportHeight / rotatedHeight)
                        } else {
                            1f
                        }
                        val breathingRoom = if (rawAspect > 1f) {
                            1f - 0.08f * abs(sin(angle)).toFloat()
                        } else {
                            1f
                        }
                        val rootBounds = overlayBounds
                        val targetBounds = queueFlightTarget
                        val sx = viewportWidth / 2f
                        val sy = viewportHeight / 2f
                        // 与列表残影完全相同的胶囊落点：承载区右缘向内 28dp、垂直居中。
                        val ex = if (rootBounds != null && targetBounds != null) {
                            targetBounds.right - rootBounds.left - 28.dp.toPx()
                        } else sx
                        val ey = if (rootBounds != null && targetBounds != null) {
                            targetBounds.center.y - rootBounds.top
                        } else sy
                        val flightCenter = queueFlightBezierPoint(
                            progress = p,
                            start = Offset(sx, sy),
                            end = Offset(ex, ey),
                            liftBasePx = 36.dp.toPx(),
                            maxLiftPx = 90.dp.toPx(),
                            minApexYPx = 12.dp.toPx(),
                            maxBowPx = 52.dp.toPx(),
                            bowFadeDistancePx = 160.dp.toPx(),
                        )

                        val appear = (p / 0.12f).coerceAtMost(1f)
                        // 起飞时仍能认出当前照片，抵达时收拢到胶囊内部的小卡片尺度。
                        val startScale = rotationFit * breathingRoom * 0.82f
                        val endScale = 18.dp.toPx() /
                            max(rotatedWidth, rotatedHeight).coerceAtLeast(1f)
                        val flightScale = startScale + (endScale - startScale) * p
                        val arc = sin(Math.PI * p).toFloat()

                        transformOrigin = TransformOrigin.Center
                        scaleX = flightScale
                        scaleY = flightScale
                        translationX = flightCenter.x - sx
                        translationY = flightCenter.y - sy
                        rotationZ = queueFlightRotation + 2.2f * arc
                        // 和列表一致，只在最后 6% 贴着胶囊消失；接收回弹紧随其后。
                        alpha = appear *
                            (if (p > 0.94f) (1f - p) / 0.06f else 1f) *
                            0.82f * progress.value
                    },
            )
        }
        queueFlightBurstFiles?.let { files ->
            PreviewBurstQueueFlightGhost(
                files = files,
                cameraViewModel = cameraViewModel,
                flightProgress = { queueFlightProgress },
                targetBounds = queueFlightTarget,
                overlayBounds = overlayBounds,
                overlayAlpha = { progress.value },
            )
        }

        if (histogramVisible && currentFile != null &&
            currentFile.extension !in VIDEO_EXTENSIONS
        ) {
            previewHistogram?.let { histogram ->
                HistogramOverlay(
                    histogram = histogram,
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .navigationBarsPadding()
                        .padding(start = 20.dp, bottom = 72.dp)
                        .graphicsLayer {
                            val swipe =
                                (1f - abs(pagerState.currentPageOffsetFraction) * 2f)
                                    .coerceIn(0f, 1f)
                            translationX =
                                (overlayBounds?.width ?: 0f) * burstPagerSlide.value
                            alpha = progress.value * swipe * burstPagerAlpha.value
                        },
                )
            }
        }

        // 顶部信息带与右侧队列胶囊严格共用 36dp 高度和 6dp 顶边距。文件名左对齐，
        // 当前照片的传输状态紧跟其后；右侧为胶囊预留最大安全区，长文件名单行省略。
        // 整条信息带随翻页跟手渐隐/渐显，内容在中点透明时切换，不会硬跳。
        if (currentItem != null) {
            val pageNumber = "${pagerState.currentPage + 1}/${previewItems.size}"
            val title = (currentItem as? PhotoPreviewItem.Photo)?.file?.fileName
            val task = currentFile?.let(queueTaskFor)
            val overlayTask = task?.takeIf { showsQueueStatusOverlay(it.status) }
            val transferred = currentFile?.let(isTransferred) == true
            Row(
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(top = 6.dp, start = 12.dp, end = 184.dp)
                    .height(36.dp)
                    .graphicsLayer {
                        val swipe =
                            (1f - abs(pagerState.currentPageOffsetFraction) * 2f)
                                .coerceIn(0f, 1f)
                        translationX = (overlayBounds?.width ?: 0f) * burstPagerSlide.value
                        alpha = progress.value * swipe * burstPagerAlpha.value
                    },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = title?.let { "$pageNumber  ·  $it" } ?: pageNumber,
                    style = MaterialTheme.typography.labelMedium,
                    color = Color.White.copy(alpha = 0.88f),
                    textAlign = TextAlign.Start,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (overlayTask != null || transferred) {
                    Spacer(Modifier.width(8.dp))
                    if (overlayTask != null) {
                        TransferStatusIndicator(
                            task = overlayTask,
                            activeProgressFlow = activeProgressFlow,
                        )
                    } else {
                        TransferredIndicator()
                    }
                }
            }
        }

        // 左上角第二行：连拍/保护标签与列表语义一致，但在大图舞台上适度放大，避免
        // 像缩略图角标一样小气；与顶部信息带左边缘对齐，并留出 8dp 呼吸间距。
        if (currentFile != null &&
            (currentFile.handle in burstHandles || currentFile.isProtected)
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .statusBarsPadding()
                    .padding(top = 50.dp, start = 12.dp)
                    .graphicsLayer {
                        val swipe =
                            (1f - abs(pagerState.currentPageOffsetFraction) * 2f)
                                .coerceIn(0f, 1f)
                        translationX = (overlayBounds?.width ?: 0f) * burstPagerSlide.value
                        alpha = progress.value * swipe * burstPagerAlpha.value
                    }
            ) {
                if (currentFile.handle in burstHandles) {
                    Surface(
                        shape = RoundedCornerShape(9.dp),
                        color = BurstBadgeColor.copy(alpha = 0.85f)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            modifier = Modifier.padding(horizontal = 9.dp, vertical = 5.dp)
                        ) {
                            Icon(
                                Icons.Default.BurstMode,
                                contentDescription = null,
                                tint = Color.White,
                                modifier = Modifier.size(14.dp)
                            )
                            Text(
                                text = stringResource(R.string.burst_label),
                                style = MaterialTheme.typography.labelSmall.copy(
                                    fontSize = 12.sp,
                                    lineHeight = 14.sp,
                                ),
                                fontWeight = FontWeight.Medium,
                                color = Color.White
                            )
                        }
                    }
                }
                if (currentFile.isProtected) {
                    // 黑底胶囊在黑幕/暗部照片上需要细描边定界(列表页衬在照片上无此问题)。
                    // 钥匙 + "保护"文字，与旁边的连拍角标（图标+字）一致。
                    Surface(
                        shape = RoundedCornerShape(9.dp),
                        color = Color.Black.copy(alpha = 0.45f),
                        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.22f))
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            modifier = Modifier.padding(horizontal = 9.dp, vertical = 5.dp)
                        ) {
                            Icon(
                                Icons.Default.Key,
                                contentDescription = null,
                                tint = Color.White.copy(alpha = 0.9f),
                                modifier = Modifier.size(14.dp)
                            )
                            Text(
                                text = stringResource(R.string.filter_protected),
                                style = MaterialTheme.typography.labelSmall.copy(
                                    fontSize = 12.sp,
                                    lineHeight = 14.sp,
                                ),
                                fontWeight = FontWeight.Medium,
                                color = Color.White
                            )
                        }
                    }
                }
            }
        }

        // 顶部极细进度条：当前页正在取 FHD 高清版时显示（"正在加载高清"的低调提示，
        // 取代旧的突兀底部小转圈）。随展开动画淡入，取到即消失。
        val curLoadingFhd = currentFile?.let {
            highResolutionLoading.containsKey(it.handle)
        } == true
        if (curLoadingFhd) {
            LinearProgressIndicator(
                color = AccentBlue.copy(alpha = 0.9f),
                trackColor = Color.Transparent,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .height(2.dp)
                    .graphicsLayer {
                        translationX = (overlayBounds?.width ?: 0f) * burstPagerSlide.value
                        alpha = progress.value * burstPagerAlpha.value
                    }
            )
        }

        // ---- 底部栏：当前真实照片的 EXIF 参数 ----
        // 跟手淡入淡出：alpha 由翻页滚动进度实时驱动——离开当前页时随手指滑动淡出、
        // 新页吸附到位时淡入，不等翻完。内容在滑过半（currentPage 翻转、此刻 alpha≈0
        // 看不见）时直接切换，因此不会保留上一页参数的退场副本。
        // alpha 计算写在 graphicsLayer 内读滚动值：每帧只重绘图层，不触发子树重组。
        // 新页 EXIF 异步到达后再独立淡入；合集页直接移除整棵参数子树。
        currentFile?.let { file ->
            val curExif = exifData[file.handle]
            val displayExif = curExif?.takeIf {
                it.aperture != null || it.shutterSpeed != null ||
                    it.iso != null || it.exposureCompensation != null ||
                    it.focalLength != null
            }
            val loadedAlpha by animateFloatAsState(
                targetValue = if (displayExif != null) 1f else 0f,
                animationSpec = tween(180, easing = FastOutSlowInEasing),
                label = "exifLoaded"
            )
            if (displayExif != null) {
                Row(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .navigationBarsPadding()
                        .padding(horizontal = 12.dp)
                        .heightIn(min = 44.dp)
                        .padding(vertical = 24.dp)
                        .graphicsLayer {
                            val swipe =
                                (1f - abs(pagerState.currentPageOffsetFraction) * 2f)
                                    .coerceIn(0f, 1f)
                            translationX =
                                (overlayBounds?.width ?: 0f) * burstPagerSlide.value
                            alpha = progress.value * swipe * loadedAlpha * burstPagerAlpha.value
                        },
                    verticalAlignment = Alignment.Bottom
                ) {
                    ExifMetadataBar(
                        exif = displayExif,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                }
            }
        }

        // 普通照片沿用右下旋转/入队；合集页改为底部左右双按钮，与列表卡的
        // “左下 + / 右下 >”完全同语义。合集展开后自动进入第一张成员。
        when (val item = currentItem) {
            is PhotoPreviewItem.Photo -> {
                val current = item.file
                val memberBurstId = item.burstId
                val memberCollectionPage = previewBurstCollectionPage(
                    previewItems,
                    pagerState.currentPage,
                ) ?: -1
                Column(
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .navigationBarsPadding()
                        .padding(end = 20.dp, bottom = 80.dp)
                        .graphicsLayer {
                            translationX =
                                (overlayBounds?.width ?: 0f) * burstPagerSlide.value
                            alpha = progress.value * burstPagerAlpha.value
                        },
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    if (memberCollectionPage in 0 until pagerState.currentPage) {
                        BurstMemberCollapseButton(
                            // 进入成员页时按钮直接以完整形态出现；连拍过渡的防重由
                            // collapsePreviewBurstMember 统一拦截，不借禁用态制造透明渐变。
                            enabled = !queueAnimating && !queueGestureActive &&
                                queueMotionJob?.isActive != true,
                            onClick = {
                                memberBurstId?.let(collapsePreviewBurstMember)
                            },
                        )
                    }
                    if (current.extension !in VIDEO_EXTENSIONS) {
                        PreviewHistogramButton(
                            active = histogramVisible,
                            onClick = {
                                onHistogramVisibleChanged(!histogramVisible)
                            },
                        )
                        PreviewRotationButton(onClick = {
                            if (!burstTransitionBusy) {
                                val nextDegrees = rotationDegrees - 90f
                                rotationDegrees = nextDegrees
                                // 从连续角度换算持久化方向；快速连点也不依赖父层重组时机。
                                val nextTurns = Math.floorMod((-nextDegrees / 90f).toInt(), 4)
                                onRotationChanged(nextTurns)
                            }
                        })
                    }
                    TransferQueueButton(
                        onClick = {
                            if (!burstTransitionBusy) enqueueFromPreview(current)
                        }
                    )
                }
            }
            is PhotoPreviewItem.BurstCollection -> {
                Row(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .navigationBarsPadding()
                        .padding(bottom = 112.dp)
                        .graphicsLayer {
                            translationX =
                                (overlayBounds?.width ?: 0f) * burstPagerSlide.value
                            alpha = progress.value * burstPagerAlpha.value
                        },
                    horizontalArrangement = Arrangement.spacedBy(22.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    TransferQueueButton(
                        onClick = {
                            if (!burstTransitionBusy) enqueueBurstFromPreview(item)
                        },
                        buttonSize = 48.dp
                    )
                    BurstCollectionExpandButton(
                        onClick = { expandPreviewBurstCollection(item) }
                    )
                }
            }
            null -> Unit
        }
    }
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
) {
    var overlayBounds by remember { mutableStateOf<Rect?>(null) }
    val progress = remember { Animatable(0f) }
    var closing by remember { mutableStateOf(false) }
    var rotationDegrees by remember(bitmap) { mutableFloatStateOf(0f) }

    LaunchedEffect(overlayBounds, closing) {
        if (!closing && overlayBounds != null && progress.value < 1f) {
            progress.animateTo(1f, Motion.overlayExpand)
        }
    }
    LaunchedEffect(closing) {
        if (closing) {
            progress.animateTo(0f, Motion.overlayCollapse)
            onDismiss()
        }
    }
    val startClose: () -> Unit = {
        if (!closing) closing = true
    }
    BackHandler(enabled = !closing) { startClose() }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .onGloballyPositioned { overlayBounds = it.boundsInRoot() }
            // 阻断未被大图手势处理的拖动，避免事件穿透到设置页滚动容器。
            .pointerInput(Unit) { detectDragGestures { change, _ -> change.consume() } },
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .drawBehind { drawRect(Color.Black, alpha = 0.74f * progress.value) },
        )

        Box(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    val bounds = overlayBounds
                    val anchor = anchorRect
                    if (bounds != null && anchor != null && bounds.width > 0f && bounds.height > 0f) {
                        transformOrigin = TransformOrigin(
                            (anchor.center.x - bounds.left) / bounds.width,
                            (anchor.center.y - bounds.top) / bounds.height,
                        )
                        val startScale = (anchor.width / bounds.width).coerceIn(0.05f, 1f)
                        val scale = startScale + (1f - startScale) * progress.value
                        scaleX = scale
                        scaleY = scale
                        alpha = if (closing) {
                            (progress.value * 1.6f).coerceAtMost(1f)
                        } else {
                            1f
                        }
                    } else {
                        scaleX = 1f
                        scaleY = 1f
                        alpha = progress.value
                    }
                },
        ) {
            ZoomablePreviewViewport(
                imageSize = IntSize(bitmap.width, bitmap.height),
                stateKey = bitmap,
                rotationDegrees = rotationDegrees,
                isCurrent = true,
                zoomEnabled = true,
                onZoomedChange = {},
                onTap = startClose,
            ) { imageTransform ->
                Image(
                    bitmap = bitmap,
                    contentDescription = title,
                    contentScale = ContentScale.Fit,
                    modifier = imageTransform,
                )
            }
        }

        Text(
            text = title,
            style = MaterialTheme.typography.labelMedium,
            color = Color.White.copy(alpha = 0.85f * progress.value),
            textAlign = TextAlign.Center,
            maxLines = 1,
            modifier = Modifier
                .align(Alignment.TopCenter)
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(top = 12.dp, start = 52.dp, end = 52.dp),
        )

        Box(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .navigationBarsPadding()
                .padding(end = 20.dp, bottom = 32.dp)
                .graphicsLayer { alpha = progress.value },
        ) {
            PreviewRotationButton(onClick = {
                rotationDegrees -= 90f
            })
        }
    }
}

@Composable
private fun BurstCollectionPreviewPage(
    collection: PhotoPreviewItem.BurstCollection,
    cameraViewModel: CameraViewModel,
    loadEnabled: Boolean,
    isCurrent: Boolean,
    onZoomedChange: (Boolean) -> Unit,
    stackMotionProgress: () -> Float = { 0f },
    onTap: () -> Unit
) {
    val a11y = stringResource(R.string.burst_collection_a11y, collection.files.size)
    LaunchedEffect(isCurrent) {
        if (isCurrent) onZoomedChange(false)
    }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .semantics { contentDescription = a11y }
            .pointerInput(collection.id) {
                detectTapGestures(onTap = { onTap() })
            },
        contentAlignment = Alignment.Center
    ) {
        val stackSize = minOf(maxWidth * 0.72f, maxHeight * 0.46f, 360.dp)
        BurstCollectionStack(
            files = collection.files,
            cameraViewModel = cameraViewModel,
            loadEnabled = loadEnabled,
            stackSize = stackSize,
            stackMotionProgress = stackMotionProgress,
            modifier = Modifier.size(stackSize),
        )
    }
}

/**
 * 合集预览与入队残影共用的叠片本体。残影只读已有缩略图缓存，绝不为了短动画新增相机请求。
 */
@Composable
private fun BurstCollectionStack(
    files: List<CameraFileInfo>,
    cameraViewModel: CameraViewModel,
    loadEnabled: Boolean,
    stackSize: Dp,
    stackMotionProgress: () -> Float = { 0f },
    modifier: Modifier = Modifier,
) {
    Box(modifier = modifier) {
        val stackFiles = files.take(3).reversed()
        val stackInset = stackSize * 0.07f + 6.dp
        val stackSpreadPx = with(LocalDensity.current) { 6.dp.toPx() }
        stackFiles.forEachIndexed { index, file ->
            val last = stackFiles.lastIndex
            val rotation = when (stackFiles.size) {
                1 -> 0f
                2 -> if (index == 0) -5f else 3f
                else -> when (index) {
                    0 -> -6f
                    1 -> 5f
                    else -> 0f
                }
            }
            val x = when {
                index == last -> 0.dp
                index % 2 == 0 -> (-12).dp
                else -> 12.dp
            }
            val spreadDirection = when {
                index == last -> 0f
                index % 2 == 0 -> -1f
                else -> 1f
            }
            BurstStackPhoto(
                file = file,
                cameraViewModel = cameraViewModel,
                transfersBusy = false,
                loadEnabled = loadEnabled,
                showPlaceholderIcon = index == last,
                modifier = Modifier
                    .fillMaxSize(0.86f)
                    .align(Alignment.Center)
                    .offset(x = x, y = if (index == last) 2.dp else 5.dp)
                    .graphicsLayer {
                        val motion = stackMotionProgress().coerceIn(0f, 1f)
                        rotationZ = rotation
                        translationX = spreadDirection * stackSpreadPx * motion
                        val motionScale = 1f + 0.012f * motion
                        scaleX = motionScale
                        scaleY = motionScale
                    }
            )
        }

        BurstCollectionBadge(
            count = files.size,
            iconSize = 16.dp,
            modifier = Modifier
                .align(Alignment.TopStart)
                .offset(x = stackInset, y = stackInset)
        )
    }
}

/** 当前合集叠片沿单张预览完全相同的弧线收进队列胶囊。 */
@Composable
private fun PreviewBurstQueueFlightGhost(
    files: List<CameraFileInfo>,
    cameraViewModel: CameraViewModel,
    flightProgress: () -> Float,
    targetBounds: Rect?,
    overlayBounds: Rect?,
    overlayAlpha: () -> Float,
) {
    BoxWithConstraints(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        val stackSize = minOf(maxWidth * 0.72f, maxHeight * 0.46f, 360.dp)
        val viewportWidth = constraints.maxWidth.toFloat()
        val viewportHeight = constraints.maxHeight.toFloat()
        BurstCollectionStack(
            files = files,
            cameraViewModel = cameraViewModel,
            // 影子必须只复用页面已经拿到的缓存，不能为 560ms 的反馈另启网络读取。
            loadEnabled = false,
            stackSize = stackSize,
            modifier = Modifier
                .size(stackSize)
                .graphicsLayer {
                    val p = flightProgress().coerceIn(0f, 1f)
                    val sx = viewportWidth / 2f
                    val sy = viewportHeight / 2f
                    val ex = if (overlayBounds != null && targetBounds != null) {
                        targetBounds.right - overlayBounds.left - 28.dp.toPx()
                    } else sx
                    val ey = if (overlayBounds != null && targetBounds != null) {
                        targetBounds.center.y - overlayBounds.top
                    } else sy
                    val flightCenter = queueFlightBezierPoint(
                        progress = p,
                        start = Offset(sx, sy),
                        end = Offset(ex, ey),
                        liftBasePx = 36.dp.toPx(),
                        maxLiftPx = 90.dp.toPx(),
                        minApexYPx = 12.dp.toPx(),
                        maxBowPx = 52.dp.toPx(),
                        bowFadeDistancePx = 160.dp.toPx(),
                    )
                    val appear = (p / 0.12f).coerceAtMost(1f)
                    val startScale = 0.82f
                    val endScale = 18.dp.toPx() / size.maxDimension.coerceAtLeast(1f)
                    val flightScale = startScale + (endScale - startScale) * p

                    transformOrigin = TransformOrigin.Center
                    scaleX = flightScale
                    scaleY = flightScale
                    translationX = flightCenter.x - sx
                    translationY = flightCenter.y - sy
                    rotationZ = 2.2f * sin(Math.PI * p).toFloat()
                    alpha = appear *
                        (if (p > 0.94f) (1f - p) / 0.06f else 1f) *
                        0.86f * overlayAlpha()
                },
        )
    }
}

@Composable
private fun BurstCollectionExpandButton(onClick: () -> Unit) =
    BurstCollectionNavigationButton(
        expand = true,
        enabled = true,
        onClick = onClick,
    )

/** 成员页专属的“回到并收起合集”按钮，放在旋转按钮上方。 */
@Composable
private fun BurstMemberCollapseButton(
    enabled: Boolean,
    onClick: () -> Unit,
) = BurstCollectionNavigationButton(
    expand = false,
    enabled = enabled,
    onClick = onClick,
)

/** 展开与缩起使用固定的右/左折角；按钮本身不跟随合集状态变形。 */
@Composable
private fun BurstCollectionNavigationButton(
    expand: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val colors = AppTheme.colors
    val description = stringResource(if (expand) R.string.cd_expand else R.string.cd_collapse)
    GlassButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.size(44.dp),
        shape = CircleShape,
        contentPadding = PaddingValues(0.dp),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .semantics { contentDescription = description },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = if (expand) {
                    Icons.Default.ChevronRight
                } else {
                    Icons.Default.ChevronLeft
                },
                contentDescription = null,
                tint = colors.accentBlue,
                modifier = Modifier.size(25.dp),
            )
        }
    }
}

/**
 * 底部毛玻璃参数条：光圈 / 快门 / ISO / 非零曝光补偿 / 焦距。
 * 淡入淡出由外层（overlay 展开进度 × 翻页跟手 × 加载完成度）统一驱动，本身不管透明度。
 */
@Composable
private fun ExifMetadataBar(
    exif: PhotoExif,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    val parts = listOfNotNull(
        exif.aperture,
        exif.shutterSpeed,
        exif.iso,
        exif.exposureCompensation,
        exif.focalLength,
    )
    if (parts.isEmpty()) return
    val text = parts.joinToString("\u2009·\u2009")
    val textMeasurer = rememberTextMeasurer(cacheSize = 4)
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = colors.glassSurfaceHeavy,
        shadowElevation = 4.dp,
        border = BorderStroke(1.dp, colors.glassPanelBorder),
        modifier = modifier
    ) {
        BoxWithConstraints {
            val horizontalPadding = 14.dp
            val availableWidthPx = with(LocalDensity.current) {
                (maxWidth - horizontalPadding * 2).coerceAtLeast(0.dp).roundToPx()
            }
            val baseStyle = MaterialTheme.typography.labelLarge
            val textStyle = remember(text, availableWidthPx, baseStyle) {
                listOf(
                    baseStyle,
                    baseStyle.copy(fontSize = 13.sp, lineHeight = 18.sp),
                    baseStyle.copy(fontSize = 12.sp, lineHeight = 17.sp),
                    baseStyle.copy(fontSize = 11.sp, lineHeight = 16.sp),
                ).firstOrNull { candidate ->
                    textMeasurer.measure(
                        text = AnnotatedString(text),
                        style = candidate,
                        maxLines = 1,
                        softWrap = false,
                    ).size.width <= availableWidthPx
                } ?: baseStyle.copy(fontSize = 11.sp, lineHeight = 16.sp)
            }
            Text(
                text = text,
                style = textStyle,
                color = colors.onBackground,
                textAlign = TextAlign.Center,
                maxLines = 1,
                softWrap = false,
                overflow = TextOverflow.Clip,
                modifier = Modifier.padding(horizontal = horizontalPadding, vertical = 10.dp),
            )
        }
    }
}

/** Preview-styled switch around the monitor page's shared histogram icon and analysis overlay. */
@Composable
private fun PreviewHistogramButton(
    active: Boolean,
    onClick: () -> Unit,
) {
    val colors = AppTheme.colors
    val description = stringResource(R.string.cd_preview_histogram)
    GlassButton(
        onClick = onClick,
        modifier = Modifier.size(44.dp),
        shape = CircleShape,
        contentPadding = PaddingValues(0.dp),
        active = active,
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .semantics {
                    contentDescription = description
                },
            contentAlignment = Alignment.Center,
        ) {
            CompositionLocalProvider(LocalContentColor provides colors.accentBlue) {
                HistogramMark(Modifier.size(20.dp))
            }
        }
    }
}

/**
 * 预览页"加入传输队列"按钮：使用全局统一的玻璃圆钮。
 * 始终允许再次加入；任务执行时检查原片与当前任务对应的边框文件是否存在。
 */
@Composable
private fun TransferQueueButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    buttonSize: Dp = 44.dp
) {
    val colors = AppTheme.colors
    GlassButton(
        onClick = onClick,
        modifier = modifier.size(buttonSize),
        shape = CircleShape,
        contentPadding = PaddingValues(0.dp)
    ) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = Icons.Default.Add,
                contentDescription = stringResource(R.string.cd_transfer),
                tint = colors.accentBlue,
                modifier = Modifier.size(buttonSize * 0.5f)
            )
        }
    }
}

// 普通预览至少允许 4x；本地原图会按实际像素动态提高上限，确保能够查看到 1:1 细节。
private const val MAX_ZOOM = 4f
private const val DOUBLE_TAP_ZOOM = 2.5f

@Composable
private fun PreviewPage(
    file: CameraFileInfo,
    cameraViewModel: CameraViewModel,
    fhdBitmap: ImageBitmap?,
    isLoadingFhd: Boolean,
    allowRemoteThumbnailFallback: Boolean,
    loadEnabled: Boolean,
    rotationDegrees: Float,
    isCurrent: Boolean,
    onDisplayBitmapChanged: (ImageBitmap?) -> Unit,
    onZoomedChange: (Boolean) -> Unit,
    onTap: () -> Unit
) {
    // 预览通常由一个已经显示缩略图的可见格子打开。同步复用同一份内存缓存，确保
    // overlay 第一帧就有画面；缓存未命中时才异步走磁盘/相机兜底。
    var thumbnail by remember(file.handle) {
        mutableStateOf(cameraViewModel.cachedThumbnail(file.handle))
    }
    // 取过仍为 null → 该文件确实没有缩略图（如部分视频）。
    var noThumb by remember(file.handle) { mutableStateOf(false) }
    LaunchedEffect(file.handle, loadEnabled, allowRemoteThumbnailFallback) {
        if (loadEnabled && thumbnail == null && !noThumb) {
            val t = cameraViewModel.loadThumbnail(
                file = file,
                allowRemote = allowRemoteThumbnailFallback,
            )
            if (t != null) thumbnail = t
            else if (allowRemoteThumbnailFallback) noThumb = true
        }
    }

    // FHD 到位后覆盖在缩略图上淡入。缩略图在过渡完成前始终保持不透明，避免两张图
    // 的有效画面边界略有差异时交叉淡出露出背景，视觉上只发生一次连续的“变清晰”。
    var fhdAlpha by remember(file.handle) { mutableFloatStateOf(0f) }
    LaunchedEffect(fhdBitmap) {
        if (fhdBitmap != null) {
            if (thumbnail == null) {
                fhdAlpha = 1f
            } else {
                // FHD 是否可见不能依赖 Compose 动画帧时钟：部分设备上该时钟可能不推进，
                // Animatable 会一直停在 0，造成 FHD 已加载却始终被透明隐藏。
                fhdAlpha = 0f
                val startedAt = SystemClock.uptimeMillis()
                while (isActive) {
                    val elapsed = SystemClock.uptimeMillis() - startedAt
                    val linearProgress =
                        (elapsed.toFloat() / FHD_REVEAL_DURATION_MS).coerceIn(0f, 1f)
                    fhdAlpha = FastOutSlowInEasing.transform(linearProgress)
                    if (linearProgress >= 1f) break
                    delay(FHD_REVEAL_FRAME_MS)
                }
            }
        } else {
            fhdAlpha = 0f
        }
    }

    val displayBitmap = fhdBitmap ?: thumbnail
    LaunchedEffect(displayBitmap, isCurrent) {
        if (isCurrent) onDisplayBitmapChanged(displayBitmap)
    }
    val isVideo = file.extension in VIDEO_EXTENSIONS
    ZoomablePreviewViewport(
        imageSize = displayBitmap?.let { IntSize(it.width, it.height) },
        stateKey = file.handle,
        rotationDegrees = rotationDegrees,
        isCurrent = isCurrent,
        zoomEnabled = !isVideo && displayBitmap != null,
        onZoomedChange = onZoomedChange,
        onTap = onTap,
    ) { imageTransform ->
        val thumb = thumbnail  // 本地变量，delegate 属性无法被编译器 smart cast
        // 若 FHD 比缩略图先到，直接显示 FHD；不能等待 LaunchedEffect 下一帧再 snap，
        // 否则仍会产生一帧全透明图片区。
        val effectiveFhdAlpha = if (thumb == null) 1f else fhdAlpha
        val anyLoading = isLoadingFhd || (!noThumb && thumbnail == null)
        when {
            isVideo -> {
                // 视频无高清封面：缩略图压暗当背景 + 居中毛玻璃信息卡，明确暂不支持播放，
                // 同时复用 ObjectInfo 已有的大小与拍摄时间，不为占位页增加相机请求。
                // 而非把糊掉的小缩略图硬撑满屏当"预览"。
                if (thumb != null) {
                    Image(
                        bitmap = thumb,
                        contentDescription = null,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.fillMaxSize()
                    )
                }
                Box(modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.5f)))
                val metadata = videoPreviewMetadata(
                    fileSize = file.size,
                    captureDate = file.captureDate,
                    overFourGbLabel = stringResource(R.string.video_size_over_4gb),
                )
                Surface(
                    shape = RoundedCornerShape(18.dp),
                    color = Color.Black.copy(alpha = 0.45f),
                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.22f))
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
                    ) {
                        Text(
                            stringResource(R.string.video_no_preview),
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.Medium,
                            color = Color.White,
                        )
                        if (metadata.isNotEmpty()) {
                            Spacer(Modifier.height(6.dp))
                            Text(
                                text = metadata,
                                style = MaterialTheme.typography.labelMedium,
                                color = Color.White.copy(alpha = 0.76f),
                                textAlign = TextAlign.Center,
                            )
                        }
                    }
                }
            }
            displayBitmap != null -> {
                // 图像栈（缩略图淡出 + FHD 淡入）统一套用缩放/平移变换。
                Box(modifier = imageTransform) {
                    if (thumb != null && (fhdBitmap == null || effectiveFhdAlpha < 1f)) {
                        Image(
                            bitmap = thumb,
                            contentDescription = file.fileName.takeIf { fhdBitmap == null },
                            contentScale = ContentScale.Fit,
                            modifier = Modifier.fillMaxSize()
                        )
                    }
                    if (fhdBitmap != null) {
                        Image(
                            bitmap = fhdBitmap,
                            contentDescription = file.fileName,
                            contentScale = ContentScale.Fit,
                            modifier = Modifier.fillMaxSize(),
                            alpha = effectiveFhdAlpha
                        )
                    }

                }
            }
            anyLoading -> CircularProgressIndicator(color = AccentBlue, modifier = Modifier.size(32.dp))
            noThumb -> Text(stringResource(R.string.no_preview), color = DarkOnSurfaceVariant)
            else -> CircularProgressIndicator(color = AccentBlue, modifier = Modifier.size(32.dp))
        }
    }
}

/**
 * 照片大图共用的纯位图交互内核。调用方负责提供图像内容与加载状态；本层只管理缩放、平移、
 * 双击、旋转适配和点击关闭，因此列表预览与其他单图预览不会逐渐产生两套手势行为。
 */
@Composable
private fun ZoomablePreviewViewport(
    imageSize: IntSize?,
    stateKey: Any,
    rotationDegrees: Float,
    isCurrent: Boolean,
    zoomEnabled: Boolean,
    onZoomedChange: (Boolean) -> Unit,
    onTap: () -> Unit,
    content: @Composable BoxScope.(Modifier) -> Unit,
) {
    val animatedRotation by animateFloatAsState(
        targetValue = rotationDegrees,
        animationSpec = tween(220),
        label = "previewRotation",
    )
    var scale by remember(stateKey) { mutableFloatStateOf(1f) }
    var offset by remember(stateKey) { mutableStateOf(Offset.Zero) }
    var zoomAnimJob by remember(stateKey) { mutableStateOf<Job?>(null) }
    val scope = rememberCoroutineScope()
    val zoomed = scale > 1.01f

    LaunchedEffect(isCurrent) {
        if (!isCurrent) {
            zoomAnimJob?.cancel()
            scale = 1f
            offset = Offset.Zero
        }
    }
    LaunchedEffect(isCurrent, zoomed) {
        if (isCurrent) onZoomedChange(zoomed)
    }
    LaunchedEffect(rotationDegrees) {
        zoomAnimJob?.cancel()
        scale = 1f
        offset = Offset.Zero
    }

    val rawAspect = imageSize?.takeIf { it.width > 0 && it.height > 0 }?.let {
        it.width.toFloat() / it.height.toFloat()
    }
    val quarterTurn = ((rotationDegrees / 90f).roundToInt() % 2) != 0
    val imageAspect = rawAspect?.let { if (quarterTurn) 1f / it else it }
    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    val viewportW = viewportSize.width.toFloat()
    val viewportH = viewportSize.height.toFloat()
    val baseImageW: Float
    val baseImageH: Float
    if (rawAspect != null && viewportW > 0f && viewportH > 0f) {
        val viewportAspect = viewportW / viewportH
        baseImageW = if (rawAspect > viewportAspect) viewportW else viewportH * rawAspect
        baseImageH = if (rawAspect > viewportAspect) viewportW / rawAspect else viewportH
    } else {
        baseImageW = 0f
        baseImageH = 0f
    }
    val targetRotationRadians = Math.toRadians(rotationDegrees.toDouble())
    val targetAbsCos = abs(cos(targetRotationRadians)).toFloat()
    val targetAbsSin = abs(sin(targetRotationRadians)).toFloat()
    val targetBoundsWidth = baseImageW * targetAbsCos + baseImageH * targetAbsSin
    val targetBoundsHeight = baseImageW * targetAbsSin + baseImageH * targetAbsCos
    val targetRotationFit = if (
        targetBoundsWidth > 0f && targetBoundsHeight > 0f && viewportW > 0f && viewportH > 0f
    ) {
        min(viewportW / targetBoundsWidth, viewportH / targetBoundsHeight)
    } else {
        1f
    }
    val targetBreathingRoom = if ((rawAspect ?: 0f) > 1f) {
        1f - 0.08f * targetAbsSin
    } else {
        1f
    }
    val oneToOneZoom = imageSize?.takeIf {
        it.width > 0 && it.height > 0 && baseImageW > 0f && baseImageH > 0f
    }?.let {
        max(it.width / baseImageW, it.height / baseImageH) /
            (targetRotationFit * targetBreathingRoom).coerceAtLeast(0.01f)
    } ?: 1f
    val maximumZoom = max(MAX_ZOOM, oneToOneZoom)

    fun clampOffset(
        targetScale: Float,
        targetOffset: Offset,
        displayWidth: Float,
        displayHeight: Float,
        containerWidth: Float,
        containerHeight: Float,
    ): Offset {
        val maxX = max(0f, (displayWidth * targetScale - containerWidth) / 2f)
        val maxY = max(0f, (displayHeight * targetScale - containerHeight) / 2f)
        return Offset(
            targetOffset.x.coerceIn(-maxX, maxX),
            targetOffset.y.coerceIn(-maxY, maxY),
        )
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .onSizeChanged { viewportSize = it }
            // 单指且处于 1x 时不消费，让列表分页器接管；单图预览的根层会统一阻断穿透。
            .pointerInput(imageAspect, zoomEnabled, maximumZoom) {
                val aspect = imageAspect
                if (!zoomEnabled || aspect == null) return@pointerInput
                val containerWidth = size.width.toFloat()
                val containerHeight = size.height.toFloat()
                val containerAspect = containerWidth / containerHeight
                val displayWidth = if (aspect > containerAspect) {
                    containerWidth
                } else {
                    containerHeight * aspect
                }
                val displayHeight = if (aspect > containerAspect) {
                    containerWidth / aspect
                } else {
                    containerHeight
                }
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    zoomAnimJob?.cancel()
                    do {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.count { it.pressed }
                        if (pressed >= 2 || scale > 1.01f) {
                            val zoomChange = event.calculateZoom()
                            val panChange = event.calculatePan()
                            if (zoomChange != 1f || panChange != Offset.Zero) {
                                val newScale = (scale * zoomChange).coerceIn(1f, maximumZoom)
                                val centroid = event.calculateCentroid(useCurrent = true)
                                val centerDelta = Offset(
                                    centroid.x - containerWidth / 2f,
                                    centroid.y - containerHeight / 2f,
                                )
                                offset = clampOffset(
                                    newScale,
                                    offset + centerDelta * (scale - newScale) + panChange,
                                    displayWidth,
                                    displayHeight,
                                    containerWidth,
                                    containerHeight,
                                )
                                scale = newScale
                                event.changes.forEach { change ->
                                    if (change.pressed) change.consume()
                                }
                            }
                        }
                    } while (event.changes.any { it.pressed })
                }
            }
            .pointerInput(imageAspect, zoomEnabled) {
                val containerWidth = size.width.toFloat()
                val containerHeight = size.height.toFloat()
                detectTapGestures(
                    onTap = { if (scale <= 1.01f) onTap() },
                    onDoubleTap = { tap ->
                        val aspect = imageAspect
                        if (!zoomEnabled || aspect == null) return@detectTapGestures
                        val containerAspect = containerWidth / containerHeight
                        val displayWidth = if (aspect > containerAspect) {
                            containerWidth
                        } else {
                            containerHeight * aspect
                        }
                        val displayHeight = if (aspect > containerAspect) {
                            containerWidth / aspect
                        } else {
                            containerHeight
                        }
                        val targetScale = if (scale > 1.01f) 1f else DOUBLE_TAP_ZOOM
                        val startScale = scale
                        val startOffset = offset
                        val targetOffset = if (targetScale == 1f) {
                            Offset.Zero
                        } else {
                            clampOffset(
                                targetScale,
                                Offset(
                                    tap.x - containerWidth / 2f,
                                    tap.y - containerHeight / 2f,
                                ) * (1f - targetScale),
                                displayWidth,
                                displayHeight,
                                containerWidth,
                                containerHeight,
                            )
                        }
                        zoomAnimJob?.cancel()
                        zoomAnimJob = scope.launch {
                            Animatable(0f).animateTo(1f, tween(240)) {
                                scale = startScale + (targetScale - startScale) * value
                                offset = androidx.compose.ui.geometry.lerp(
                                    startOffset,
                                    targetOffset,
                                    value,
                                )
                            }
                        }
                    },
                )
            },
        contentAlignment = Alignment.Center,
    ) {
        val imageTransform = Modifier
            .fillMaxSize()
            .graphicsLayer {
                val angle = Math.toRadians(animatedRotation.toDouble())
                val absCos = abs(cos(angle)).toFloat()
                val absSin = abs(sin(angle)).toFloat()
                val boundsWidth = baseImageW * absCos + baseImageH * absSin
                val boundsHeight = baseImageW * absSin + baseImageH * absCos
                val rotationFit = if (boundsWidth > 0f && boundsHeight > 0f) {
                    min(viewportW / boundsWidth, viewportH / boundsHeight)
                } else {
                    1f
                }
                val portraitBreathingRoom = if ((rawAspect ?: 0f) > 1f) {
                    1f - 0.08f * absSin
                } else {
                    1f
                }
                scaleX = scale * rotationFit * portraitBreathingRoom
                scaleY = scale * rotationFit * portraitBreathingRoom
                translationX = offset.x
                translationY = offset.y
                rotationZ = animatedRotation
            }
        content(imageTransform)
    }
}
