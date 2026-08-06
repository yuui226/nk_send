package com.ztransfer.ui.screen

import android.Manifest
import android.content.Context
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.SystemClock
import android.provider.DocumentsContract
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowForward
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.center
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.protocol.Lab
import com.ztransfer.protocol.LiveViewFocusFrame
import com.ztransfer.protocol.LiveViewFocusJudgement
import com.ztransfer.protocol.LiveViewMetadata
import com.ztransfer.protocol.LiveViewPacket
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.RcParam
import com.ztransfer.protocol.labEndLiveView
import com.ztransfer.protocol.labGrabFrame
import com.ztransfer.protocol.labStartLiveView
import com.ztransfer.protocol.liveViewWarmupRemainingMs
import com.ztransfer.protocol.rcAfDriveAndWait
import com.ztransfer.protocol.rcAngleLevelRoll
import com.ztransfer.protocol.rcAutoIsoCandidateProps
import com.ztransfer.protocol.rcCapture
import com.ztransfer.protocol.rcFocusAt
import com.ztransfer.protocol.rcChangeApplicationMode
import com.ztransfer.protocol.rcCanonicalExposureProp
import com.ztransfer.protocol.rcEndMovie
import com.ztransfer.protocol.rcFormat
import com.ztransfer.protocol.rcGetAngleLevel
import com.ztransfer.protocol.rcGetCompatibleParam
import com.ztransfer.protocol.rcGetFocusMode
import com.ztransfer.protocol.rcGetMovieMode
import com.ztransfer.protocol.rcGetParam
import com.ztransfer.protocol.rcPollEvents
import com.ztransfer.protocol.rcPrepareAndStartMovieDetailed
import com.ztransfer.protocol.rcRefreshParam
import com.ztransfer.protocol.rcIsBinaryToggle
import com.ztransfer.protocol.rcSetApplicationMode
import com.ztransfer.protocol.rcSetControlMode
import com.ztransfer.protocol.rcSetLvSize
import com.ztransfer.protocol.rcSetValueVerified
import com.ztransfer.protocol.rcStartMovieDetailed
import com.ztransfer.protocol.runLabProbe
import com.ztransfer.protocol.movieStartNeedsLiveViewRestart
import com.ztransfer.protocol.movieProhibitIndicatesRecording
import com.ztransfer.protocol.diagnosticSummary
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.Motion
import com.ztransfer.ui.theme.rememberAppBackgroundBrush
import com.ztransfer.ui.util.rememberHaptics
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.recorder.RecordingSink
import com.ztransfer.recorder.ViewfinderRecorder
import com.ztransfer.viewmodel.TransferViewModel
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.net.SocketTimeoutException
import kotlin.math.hypot

// 直控胶囊覆盖的四个曝光参数，2×2 网格顺序：
// 第一排 曝光补偿 / ISO，第二排 光圈 / 快门速度。
// 照片与录像的参数在机内是两套独立属性（Z 30 实测：拨杆在录像位时照片侧属性
// 读不到/不可写），拨杆位置决定网格绑定哪一组。
private val EXPOSURE_PROPS = listOf(
    Lab.PROP_EXP_COMPENSATION, Lab.PROP_ISO, Lab.PROP_F_NUMBER, Lab.PROP_NK_SHUTTER
)
private val MOVIE_EXPOSURE_PROPS = listOf(
    Lab.PROP_NK_MOVIE_EXP_COMP, Lab.PROP_NK_MOVIE_ISO,
    Lab.PROP_NK_MOVIE_F_NUMBER, Lab.PROP_NK_MOVIE_SHUTTER
)
// 事件刷新的匹配范围（两套都听：拨杆随时可能切换）
private val ALL_EXPOSURE_PROPS = EXPOSURE_PROPS + MOVIE_EXPOSURE_PROPS
private val ALL_AUTO_ISO_PROPS =
    (rcAutoIsoCandidateProps(false) + rcAutoIsoCandidateProps(true)).distinct()
private const val USB_LIVE_VIEW_STABLE_FRAMES = 8
private const val TAP_FOCUS_LOCKED_FEEDBACK_MS = 1800L
private const val TAP_FOCUS_MARKER_VISIBLE_MS = 3_000L

internal fun shouldPollMovieModeDuringLiveViewRecovery(
    initialLoaded: Boolean,
    liveViewStable: Boolean,
    cameraBusy: Boolean
): Boolean = initialLoaded && !liveViewStable && !cameraBusy

internal fun shouldPrepareUsbMovieSessionForRecord(
    connectionType: CameraConnectionType,
    remoteControlModeSet: Boolean
): Boolean = connectionType == CameraConnectionType.USB && !remoteControlModeSet

internal fun shouldReturnUsbMovieSessionToStandby(
    connectionType: CameraConnectionType,
    remoteControlModeSet: Boolean
): Boolean = connectionType == CameraConnectionType.USB && remoteControlModeSet

/**
 * A single GetEvent can repeat the same property change many times while Live View starts.
 * The first batch is already covered by the post-start parameter snapshot; steady-state batches
 * are de-duplicated by logical property so redundant descriptors do not compete with frames.
 */
internal fun coalesceRemoteEvents(
    events: List<Pair<Int, Long>>,
    suppressPropertyChanges: Boolean
): List<Pair<Int, Long>> = buildList {
    val changedProps = mutableSetOf<Int>()
    for (event in events) {
        if (event.first != Lab.EVT_DEVICE_PROP_CHANGED) {
            add(event)
            continue
        }
        if (suppressPropertyChanges) continue
        val canonicalProp = rcCanonicalExposureProp(event.second.toInt())
        if (changedProps.add(canonicalProp)) add(event)
    }
}

private data class RemoteLiveFrame(
    val image: ImageBitmap,
    val histogram: LuminanceHistogram?,
    /** 过曝斑马掩码；斑马纹关闭或尚未计算时为 null，叠加层一笔不画。 */
    val zebraMask: ZebraMask?,
    val metadata: LiveViewMetadata?,
    val receivedAtElapsedMs: Long
)

private data class ConfirmedFocusMarker(
    val fallbackPoint: Offset,
    val confirmedAtElapsedMs: Long
)

private class HistogramThrottle {
    var lastCalculatedAtMs: Long = 0L
    var cached: LuminanceHistogram? = null
}

/** 斑马掩码与直方图同一套节流：250ms 算一次，节流间隔内复用缓存实例。 */
private class ZebraThrottle {
    var lastCalculatedAtMs: Long = 0L
    var cached: ZebraMask? = null
}

private data class ViewfinderTap(
    val focusX: Int,
    val focusY: Int,
    val focusCoordinateWidth: Int,
    val focusCoordinateHeight: Int,
    val normalized: Offset
)

private enum class TapFocusFeedback { IDLE, FOCUSING, LOCKED, FAILED }

/**
 * 无线遥控页（正式功能）：页面外壳跟随全局深浅主题，取景器内部保持相机监看所需的深色覆盖。
 *
 * 布局：竖屏顶栏 / 横屏工具轨 → 监看画面（直方图、构图线、模式徽标）→
 * 2×2 参数拖拽微调 tile
 * （值域来自相机枚举，只读压暗+锁；点数值弹全表直跳）→ 大圆快门键
 * （按住=半按对焦、松开在键内=拍摄）。进页自动开监看、退页自动关；
 * 拍摄结果仅确认不入队（下载走照片列表）。开发者面板：顶栏虫子按钮呼出（探测/日志），
 * 按钮默认隐藏——连按 4 次 FPS 键显示（仅本次进页有效）。
 */
@Composable
fun RemoteScreen(
    cameraViewModel: CameraViewModel,
    transferViewModel: TransferViewModel,
    onNavigateBack: () -> Unit
) {
    val backgroundBrush = rememberAppBackgroundBrush()
    val transferState by transferViewModel.state.collectAsState()
    val context = LocalContext.current
    val activity = context.findActivity()
    val originalOrientation = remember(activity) {
        activity?.requestedOrientation ?: ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    }
    val screenScope = rememberCoroutineScope()
    val rotation = transferState.remoteRotation
    val isLandscape = rotation != 0
    var switchingRotation by remember { mutableStateOf(false) }
    val rotationTransition = remember { Animatable(1f) }
    // Activity 始终保持竖屏。内部顺时针旋转后，系统顶部/底部 inset 分别映射为
    // 横屏内容的左/右安全边；背景不避让，继续铺到系统控制条后面。
    val rotationStatusInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val rotationCutoutInset = WindowInsets.displayCutout.asPaddingValues().calculateTopPadding()
    val rotationLeftInset = maxOf(rotationStatusInset, rotationCutoutInset, 6.dp)
    val rotationRightInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    DisposableEffect(activity) {
        activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        onDispose { activity?.requestedOrientation = originalOrientation }
    }
    fun cycleRotation() {
        if (switchingRotation) return
        screenScope.launch {
            switchingRotation = true
            try {
                rotationTransition.animateTo(0f, tween(110))
                transferViewModel.setRemoteRotation((rotation + 1) % 3)
                rotationTransition.animateTo(1f, tween(190))
            } finally {
                switchingRotation = false
            }
        }
    }
    // 免费版监看限时:每天累计 FREE_REMOTE_DAILY_MS(无单次概念),自然日重置。
    // 计时从"参数加载完 + 监看首帧已显示"（onReady）才开始——进页加载不占时长;
    // 退出本页协程随组合销毁而取消,计时自动暂停,再进来接着剩余走。
    // 每秒经 LicenseManager 落一次账,进程被杀最多丢 1 秒。PRO 无任何额外开销。
    val isPro by LicenseManager.isPro.collectAsState()
    var trialLeftMs by remember { mutableLongStateOf(LicenseManager.remoteTimeLeftMs()) }
    var trialArmed by remember { mutableStateOf(false) }
    if (!isPro) {
        LaunchedEffect(trialArmed) {
            if (!trialArmed) return@LaunchedEffect
            while (trialLeftMs > 0) {
                delay(1000)
                trialLeftMs -= 1000
                LicenseManager.consumeRemoteTime(1000)
            }
            // 归零:自动"按返回"退出。提示气泡显示在退回后的照片列表页——
            // 本页即刻消失,页内气泡没人看得见(跨页标记由列表页读取并清除)。
            RemoteTrialNotice.pending = true
            onNavigateBack()
        }
    }

    Box(Modifier.fillMaxSize().background(backgroundBrush)) {
        BoxWithConstraints(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.Center
        ) {
            val rotationZ = when (rotation) {
                1 -> 90f
                2 -> 270f
                else -> 0f
            }
            val hostModifier = if (isLandscape) {
                Modifier
                    .requiredSize(width = maxHeight, height = maxWidth)
                    .graphicsLayer {
                        this.rotationZ = rotationZ
                        alpha = rotationTransition.value
                        scaleX = 0.96f + 0.04f * rotationTransition.value
                        scaleY = scaleX
                    }
            } else {
                Modifier.fillMaxSize().graphicsLayer {
                    alpha = rotationTransition.value
                    scaleX = 0.96f + 0.04f * rotationTransition.value
                    scaleY = scaleX
                }
            }
            Box(hostModifier.background(backgroundBrush)) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .then(
                            when (rotation) {
                                1 -> Modifier.absolutePadding(
                                    left = rotationLeftInset,
                                    right = rotationRightInset
                                )
                                2 -> Modifier.absolutePadding(
                                    left = rotationRightInset,   // 270°: 底部→左侧
                                    right = rotationLeftInset    // 270°: 顶部→右侧
                                )
                                else -> Modifier
                            }
                        )
                ) {
                    RemoteContent(
                        cameraViewModel = cameraViewModel,
                        transferViewModel = transferViewModel,
                        onNavigateBack = onNavigateBack,
                        rotation = rotation,
                        onCycleRotation = ::cycleRotation,
                        onReady = { trialArmed = true },
                        trialLeftSeconds = if (!isPro) ((trialLeftMs / 1000).coerceAtLeast(0)).toInt() else null,
                        isPro = isPro
                    )
                }
            }
        }
    }
}

/**
 * 监看时长归零自动退出后的跨页提示标记:照片列表页回到组合时读取并清除、弹提示气泡。
 * 自动返回瞬间监看页已消失,提示只能落在退回后的页面上。
 */
object RemoteTrialNotice {
    @Volatile
    var pending = false
}

/** 首帧到达前的取景器占位宽高比（尼康监看常见 3:2）；有帧后一律用帧的真实比例。 */
private const val DEFAULT_VIEWFINDER_ASPECT = 3f / 2f

@Composable
private fun RemoteContent(
    cameraViewModel: CameraViewModel,
    transferViewModel: TransferViewModel,
    onNavigateBack: () -> Unit,
    rotation: Int,
    onCycleRotation: () -> Unit,
    onReady: () -> Unit = {},
    trialLeftSeconds: Int? = null,
    isPro: Boolean = false
) {
    val colors = AppTheme.colors
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val camState by cameraViewModel.state.collectAsState()
    val transferState by transferViewModel.state.collectAsState()
    val haptics = rememberHaptics(transferState.hapticsEnabled)
    val connected = camState.isConnectedToCamera

    // ---------- 会话状态 ----------
    var frame by remember { mutableStateOf<RemoteLiveFrame?>(null) }
    // 取景器容器的宽高比 = 当前帧真实宽高比。用 derivedStateOf 包一层：只有帧【尺寸】
    // 变化（首帧到达、切 HD/标清、切录像裁切）才让布局重组，正常换帧不会重跑外层布局。
    val viewfinderAspect by remember {
        derivedStateOf {
            frame?.let { f ->
                val ratio = f.image.width.toFloat() / f.image.height
                if (ratio.isFinite() && ratio > 0f) ratio else DEFAULT_VIEWFINDER_ASPECT
            } ?: DEFAULT_VIEWFINDER_ASPECT
        }
    }
    var fps by remember { mutableFloatStateOf(0f) }
    var capturing by remember { mutableStateOf(false) }
    var modeText by remember { mutableStateOf<String?>(null) }
    var movieMode by remember { mutableStateOf(false) }
    var focusModeText by remember { mutableStateOf<String?>(null) }
    var focusModeProp by remember { mutableStateOf<Int?>(null) }
    var focusModeManual by remember { mutableStateOf(false) }
    var focusModeQueried by remember { mutableStateOf(false) }
    val params = remember { mutableStateMapOf<Int, RcParam>() }
    // 每个参数一个待发送任务：乐观更新后合并发送最终值（声明在前，事件循环要引用）
    val pendingSets = remember { mutableMapOf<Int, Job>() }
    var autoIsoProp by remember { mutableStateOf<Int?>(null) }
    var autoIsoPropMovieMode by remember { mutableStateOf<Boolean?>(null) }
    var autoIsoBusy by remember { mutableStateOf(false) }
    var autoIsoProbeLogKey by remember { mutableStateOf<String?>(null) }
    // 初始参数是否已加载完：用于把事件轮询推迟到之后开始，避免进页时 GetEvent 与
    // 曝光参数与模式读取抢 ioMutex、拖慢参数首次显示。
    var initialLoaded by remember { mutableStateOf(false) }
    // 只控制后台相机命令何时放行；取帧本身不设任何 FPS 上限。
    var liveViewStable by remember { mutableStateOf(false) }
    // USB 首批事件早于进页参数快照，无须再逐项回读；Wi-Fi 不走这条抑制路径。
    var startupEventBaselinePending by remember { mutableStateOf(false) }
    // 参数加载完且监看首帧已显示 → 通知外层（免费版试用计时以此为起点）。
    // 键取 frame 是否为空而非 frame 本身，避免每帧重启 effect。
    LaunchedEffect(initialLoaded, frame == null) {
        if (initialLoaded && frame != null) onReady()
    }
    // 弹出完整值表的参数（点胶囊中间值触发）
    var listProp by remember { mutableStateOf<Int?>(null) }

    // ---------- 开发者面板 ----------
    val logLines = remember { mutableStateListOf<String>() }
    var devPanel by remember { mutableStateOf(false) }
    // 开发者入口默认隐藏：1.5s 内连按 4 次 FPS 键才现身（FPS 连按 4 次开关状态
    // 恰好复原，不留副作用）。仅本次进页有效，退页复位——这是诊断后门不是常驻功能。
    var devUnlocked by remember { mutableStateOf(false) }
    var fpsTaps by remember { mutableIntStateOf(0) }
    var lastFpsTapAt by remember { mutableLongStateOf(0L) }
    var showFps by remember { mutableStateOf(true) }    // 帧率覆盖默认显示（右下角）
    var hdLiveView by remember { mutableStateOf(false) } // 高清监看(XGA)开关
    var showHistogram by remember { mutableStateOf(false) }
    var framingGrid by remember { mutableStateOf(ViewfinderGrid.OFF) }
    var showZebra by remember { mutableStateOf(false) }
    var showLevel by remember { mutableStateOf(false) }
    // 相机机身的滚转角（0xD067），null=还没读到/机身不支持，此时水平仪一笔都不画
    var levelRoll by remember { mutableStateOf<Float?>(null) }
    var probing by remember { mutableStateOf(false) }
    // 全屏监看：沿用同一个取景器实例做边界动画，只保留右上角返回。
    var immersiveFullscreen by remember { mutableStateOf(false) }
    fun enterFullscreen() {
        // 竖屏入口先沿用页面现有的转屏动画进入横屏；退出全屏后停留在横屏常规布局。
        if (rotation == 0) onCycleRotation()
        listProp = null
        devPanel = false
        immersiveFullscreen = true
    }
    BackHandler(enabled = immersiveFullscreen) {
        immersiveFullscreen = false
    }
    var viewfinderRecorder by remember { mutableStateOf<ViewfinderRecorder?>(null) }
    var recElapsed by remember { mutableIntStateOf(0) }
    var recJob by remember { mutableStateOf<Job?>(null) }
    var recFinalizing by remember { mutableStateOf(false) }
    var recSaveSuccess by remember { mutableStateOf(false) }
    var recSaveFeedbackJob by remember { mutableStateOf<Job?>(null) }
    // 暂停态用 Compose 状态镜像：recorder.isPaused 是普通 @Volatile 字段，
    // 直接读它不会触发重组，暂停/继续按钮图标会卡住不切换。
    var recPaused by remember { mutableStateOf(false) }
    fun devLog(line: String) {
        logLines.add(line)
        // 全量能力探测会为每个属性保留 DESC/VALUE 原始载荷，通常有数百行。
        // 留足容量，确保用户点“复制日志”时开头的机型与完整码表没有被环形淘汰。
        if (logLines.size > 5_000) logLines.removeAt(0)
    }

    // 事件总线：单一轮询协程独占 GetEvent（事件是取走即消费的，多处轮询会互相偷事件），
    // 拍摄流程从这里等 ObjectAdded。
    val eventFlow = remember { MutableSharedFlow<Pair<Int, Long>>(extraBufferCapacity = 32) }

    val currentHistogramEnabled = rememberUpdatedState(showHistogram)
    val histogramThrottle = remember { HistogramThrottle() }
    val currentZebraEnabled = rememberUpdatedState(showZebra)
    val zebraThrottle = remember { ZebraThrottle() }
    suspend fun decode(
        bytes: ByteArray,
        offset: Int = 0,
        metadata: LiveViewMetadata? = null,
        receivedAtElapsedMs: Long = SystemClock.elapsedRealtime()
    ): RemoteLiveFrame? =
        withContext(Dispatchers.Default) {
            BitmapFactory.decodeByteArray(bytes, offset, bytes.size - offset)?.let { bitmap ->
                val histogram = if (currentHistogramEnabled.value) {
                    val now = SystemClock.elapsedRealtime()
                    if (histogramThrottle.cached == null ||
                        now - histogramThrottle.lastCalculatedAtMs >= 250L
                    ) {
                        histogramThrottle.cached = calculateLuminanceHistogram(bitmap)
                        histogramThrottle.lastCalculatedAtMs = now
                    }
                    histogramThrottle.cached
                } else {
                    histogramThrottle.cached = null
                    null
                }
                // 斑马掩码与直方图同一节奏：解码线程上按 250ms 节流计算，关闭时零开销。
                val zebraMask = if (currentZebraEnabled.value) {
                    val now = SystemClock.elapsedRealtime()
                    if (zebraThrottle.cached == null ||
                        now - zebraThrottle.lastCalculatedAtMs >= 250L
                    ) {
                        zebraThrottle.cached = calculateZebraMask(bitmap)
                        zebraThrottle.lastCalculatedAtMs = now
                    }
                    zebraThrottle.cached
                } else {
                    zebraThrottle.cached = null
                    null
                }
                RemoteLiveFrame(
                    image = bitmap.asImageBitmap(),
                    histogram = histogram,
                    zebraMask = zebraMask,
                    metadata = metadata,
                    receivedAtElapsedMs = receivedAtElapsedMs
                )
            }
        }

    suspend fun refreshParam(prop: Int) {
        val cam = cameraViewModel.getCamera() ?: return
        runCatching { cam.rcGetCompatibleParam(prop) }.getOrNull()?.let { params[prop] = it }
    }

    suspend fun refreshAutoIso() {
        val cam = cameraViewModel.getCamera() ?: return
        val preferredProps = rcAutoIsoCandidateProps(movieMode)
        val candidates = buildList {
            // 同一模式内复用已验证成功的属性；拨杆切换后则重新按新模式优先级
            // 选择。录像优先专用的 0xD0AD，再兼容旧机型的 0xD16A/0xD054。
            autoIsoProp
                ?.takeIf { autoIsoPropMovieMode == movieMode && it in preferredProps }
                ?.let(::add)
            addAll(preferredProps)
        }.distinct()
        val probeDetails = mutableListOf<String>()
        val found = candidates.firstNotNullOfOrNull { prop ->
            val param = runCatching { cam.rcGetParam(prop) }.getOrNull()
            probeDetails += if (param == null) {
                "0x%04X=unavailable".format(prop)
            } else {
                "0x%04X=w%d/t%04X/c%d/v%s".format(
                    prop,
                    if (param.writable) 1 else 0,
                    param.dataType,
                    param.current,
                    param.values.take(4).joinToString("/", prefix = "[", postfix = "]")
                )
            }
            param?.takeIf {
                // 录像优先使用专用的 D0AD；D16A/D054 仅作旧机型回退。部分机身不返回
                // enum/range，能力探测允许这种可写 0/1 描述，真正写入仍由回读结果确认。
                it.rcIsBinaryToggle()
            }
        }
        val probeLog = "Auto ISO probe mode=%s %s selected=%s".format(
            if (movieMode) "movie" else "photo",
            probeDetails.joinToString(","),
            found?.let { "0x%04X".format(it.prop) } ?: "none"
        )
        if (autoIsoProbeLogKey != probeLog) {
            autoIsoProbeLogKey = probeLog
            devLog(probeLog)
        }
        autoIsoProp = found?.prop
        autoIsoPropMovieMode = movieMode
        if (found == null) {
            params.remove(Lab.PROP_NK_ISO_CONTROL_SENSITIVITY)
            return
        }
        params[found.prop] = found
        if (found.current != 0L) {
            runCatching { cam.rcGetParam(Lab.PROP_NK_ISO_CONTROL_SENSITIVITY) }.getOrNull()?.let {
                params[Lab.PROP_NK_ISO_CONTROL_SENSITIVITY] = it
            }
        } else {
            params.remove(Lab.PROP_NK_ISO_CONTROL_SENSITIVITY)
        }
    }

    suspend fun refreshMode() {
        val cam = cameraViewModel.getCamera() ?: return
        runCatching { cam.rcGetParam(Lab.PROP_EXPOSURE_PROGRAM) }.getOrNull()?.let {
            modeText = rcFormat(Lab.PROP_EXPOSURE_PROGRAM, it.current)
        }
    }

    suspend fun refreshFocusMode() {
        val cam = cameraViewModel.getCamera() ?: return
        val focus = runCatching { cam.rcGetFocusMode() }.getOrNull()
        val changed = !focusModeQueried ||
            focusModeText != focus?.label || focusModeProp != focus?.prop
        focusModeQueried = true
        focusModeText = focus?.label
        focusModeProp = focus?.prop
        focusModeManual = focus?.manual == true
        if (focus != null && changed) {
            devLog("focus mode ${focus.label} prop=0x%04X raw=0x%X".format(focus.prop, focus.raw))
        } else if (focus == null && changed) {
            devLog("!! focus mode unavailable (0x500A/0xD161)")
        }
    }

    // ---------- 照片/录像模式 ----------
    // movieMode 跟随相机的实体照片/录像拨杆（0xD1A6 LiveViewSelector）：录像位时
    // 快门键变成开始/停止录像。读不到该属性的机型永远按照片模式（优雅降级）。
    // recording 以事件为准（0xC10A 开始 / 0xC108 完成 / 0xC105 中断），发命令成功时
    // 乐观置位让 UI 立即响应；lastStopCmdAt 用于滤掉停止后才轮询到的迟到"已开始"回声。
    var recording by remember { mutableStateOf(false) }
    var recBusy by remember { mutableStateOf(false) }
    var lastStopCmdAt by remember { mutableLongStateOf(0L) }
    // Nikon Z 系远程开录前需要进入应用模式。USB 优先走已验证的 0x9435，
    // 明确不支持时回退 D1F0；成功的入口分别记账，停录回待机时成对恢复。
    var appModeClearBusy by remember { mutableStateOf(false) }
    var movieUsbSessionDiagnostic by remember { mutableStateOf<String?>(null) }
    suspend fun ensureApplicationMode(cam: NikonCamera) {
        if (!cam.remoteMovieApplicationPropSet) {
            val rc = runCatching { cam.rcSetApplicationMode(true) }.getOrDefault(-1)
            devLog("ApplicationMode=1 resp=0x%04X".format(rc and 0xFFFF))
            if (rc == Lab.OK) cam.remoteMovieApplicationPropSet = true
        }
        if (!cam.remoteMovieApplicationOpSet) {
            val rc = runCatching { cam.rcChangeApplicationMode(1) }.getOrDefault(-1)
            devLog("ChangeApplicationMode(1) resp=0x%04X".format(rc and 0xFFFF))
            if (rc == Lab.OK) cam.remoteMovieApplicationOpSet = true
        }
    }
    suspend fun clearAppMode(
        targetCamera: NikonCamera? = cameraViewModel.getCamera(),
        force: Boolean = false
    ) {
        if (appModeClearBusy) return
        val cam = targetCamera ?: return
        // USB 完整远控期间不能单独清 ApplicationMode；停录后的待机恢复会先结束 LV，
        // 再以 force=true 成对清理并退出 ControlMode，避免留下半套远控状态。
        if (!force &&
            cam.connectionType == CameraConnectionType.USB &&
            cam.remoteControlModeSet
        ) return
        if (!cam.remoteMovieApplicationPropSet && !cam.remoteMovieApplicationOpSet) return
        appModeClearBusy = true
        try {
            if (cam.remoteMovieApplicationOpSet) {
                val rc = runCatching { cam.rcChangeApplicationMode(0) }.getOrDefault(-1)
                if (rc == Lab.OK) {
                    cam.remoteMovieApplicationOpSet = false
                } else {
                    devLog("!! ChangeApplicationMode(0) resp=0x%04X".format(rc and 0xFFFF))
                }
            }
            if (cam.remoteMovieApplicationPropSet) {
                val rc = runCatching { cam.rcSetApplicationMode(false) }.getOrDefault(-1)
                if (rc == Lab.OK) {
                    cam.remoteMovieApplicationPropSet = false
                } else {
                    devLog("!! ApplicationMode=0 resp=0x%04X".format(rc and 0xFFFF))
                }
            }
        } finally {
            appModeClearBusy = false
        }
    }
    // ---------- Live View 会话 ----------
    // 手动管理 + 新任务先 join 旧任务：保证"旧会话的 EndLiveView 一定先于新会话的
    // StartLiveView"（LaunchedEffect 换 key 的取消是异步的，直接依赖它会时序穿插）。
    // 会话在页面存续期内【永不放弃】：断流退避重启、断线后等重连自动换新连接续播——
    // 持续取帧本身就是相机的保活信号，会话若静默死掉，相机空闲片刻就按待机计时器休眠。
    var lvJob by remember { mutableStateOf<Job?>(null) }
    fun startSession(
        hd: Boolean,
        adoptActiveLiveView: NikonCamera? = null,
        suppressStartupPropertyEvents: Boolean = false
    ) {
        val prev = lvJob
        lvJob = scope.launch {
            prev?.cancelAndJoin()
            liveViewStable = false
            startupEventBaselinePending = suppressStartupPropertyEvents
            var adoptedCamera = adoptActiveLiveView
            fps = 0f   // 换会话（HD 切换/重启）时清掉上一会话的陈旧读数
            // 解码流水线：取帧（网络 IO）与解码（Default 线程）并行——取下一帧的同时
            // 解上一帧；CONFLATED 只留最新帧，解码偶尔跟不上时丢旧帧而不排队积压。
            val frameCh = Channel<LiveViewPacket>(Channel.CONFLATED)
            launch {
                for (packet in frameCh) {
                    decode(
                        packet.bytes,
                        packet.jpegOffset,
                        packet.metadata,
                        packet.receivedAtElapsedMs
                    )?.let { frame = it }
                }
            }
            try {
                while (isActive) {
                    // 每轮现取相机实例：断线重连后拿到的是新连接，旧会话自然淘汰
                    val cam = cameraViewModel.getCamera()
                    if (cam == null) { delay(2000); continue }
                    // 录像兼容恢复可能已经按“应用模式 → StartLiveView → StartMovie”
                    // 完成了相机侧启动；首轮直接接管这个 LV，不能重复发送 StartLiveView。
                    val started = if (cam === adoptedCamera) {
                        adoptedCamera = null
                        true
                    } else {
                        // LV 分辨率须在 LV 关闭时设置
                        runCatching { cam.rcSetLvSize(if (hd) 3 else 2) }
                        runCatching { cam.labStartLiveView { devLog(it) } }
                            .getOrDefault(false)
                    }
                    if (!started) { delay(3000); continue }
                    val warmupRemainingMs = liveViewWarmupRemainingMs(
                        connectionType = cam.connectionType,
                        readyAtElapsedMs = cam.liveViewReadyAtElapsedMs,
                        nowElapsedMs = SystemClock.elapsedRealtime()
                    )
                    if (warmupRemainingMs > 0L) {
                        devLog("LV USB warmup ${warmupRemainingMs}ms")
                        delay(warmupRemainingMs)
                    }
                    val requiresUsbStabilization =
                        cam.connectionType == CameraConnectionType.USB
                    if (!requiresUsbStabilization) liveViewStable = true
                    val stabilizationStartedAt = SystemClock.elapsedRealtime()
                    var startupSuccessfulFrames = 0
                    var startupBusyResponses = 0
                    // 首个成功帧只建立统计基准，不把 StartLiveView 后的相机预热、
                    // DeviceBusy 等待算进首个 FPS 窗口。后续按帧间隔计数：
                    // N 个间隔 / 实际经过时间，避免把窗口起点帧多算一次。
                    var frameIntervals = 0
                    var windowStart = 0L
                    var errStreak = 0
                    val startupDiagnosticsEndAt =
                        SystemClock.elapsedRealtime() + if (requiresUsbStabilization) 15_000L else 0L
                    var diagnosticWindowStart = SystemClock.elapsedRealtime()
                    var diagnosticPolls = 0
                    var diagnosticSuccesses = 0
                    var diagnosticBusy = 0
                    var diagnosticErrors = 0
                    var diagnosticTotalNanos = 0L
                    var diagnosticMaxNanos = 0L
                    fun recordStartupPoll(
                        elapsedNanos: Long,
                        success: Boolean = false,
                        busy: Boolean = false,
                        error: Boolean = false
                    ) {
                        val nowMs = SystemClock.elapsedRealtime()
                        if (!requiresUsbStabilization || nowMs > startupDiagnosticsEndAt) return
                        diagnosticPolls++
                        if (success) diagnosticSuccesses++
                        if (busy) diagnosticBusy++
                        if (error) diagnosticErrors++
                        diagnosticTotalNanos += elapsedNanos
                        diagnosticMaxNanos = maxOf(diagnosticMaxNanos, elapsedNanos)
                        val windowMs = nowMs - diagnosticWindowStart
                        if (windowMs < 1_000L) return
                        val averageMs =
                            diagnosticTotalNanos / diagnosticPolls.coerceAtLeast(1) / 1_000_000.0
                        val maxMs = diagnosticMaxNanos / 1_000_000.0
                        val successFps = diagnosticSuccesses * 1_000f / windowMs
                        devLog(
                            "LV USB IO: %.1ffps polls=%d busy=%d err=%d avg=%.1fms max=%.1fms"
                                .format(
                                    successFps,
                                    diagnosticPolls,
                                    diagnosticBusy,
                                    diagnosticErrors,
                                    averageMs,
                                    maxMs
                                )
                        )
                        diagnosticWindowStart = nowMs
                        diagnosticPolls = 0
                        diagnosticSuccesses = 0
                        diagnosticBusy = 0
                        diagnosticErrors = 0
                        diagnosticTotalNanos = 0L
                        diagnosticMaxNanos = 0L
                    }
                    while (isActive) {
                        val pollStartedAtNanos = SystemClock.elapsedRealtimeNanos()
                        val grabbed = try {
                            cam.labGrabFrame()
                        } catch (e: CancellationException) {
                            throw e   // 会话被取消（退页/重启），不能当普通错误吞掉
                        } catch (e: Exception) {
                            recordStartupPoll(
                                elapsedNanos =
                                    SystemClock.elapsedRealtimeNanos() - pollStartedAtNanos,
                                error = true
                            )
                            // 非忙失败（掉出 LV / 连接异常）：退避后回外层整体重启
                            errStreak++
                            devLog("!! LV: ${e.message}")
                            if (errStreak >= 3) break
                            delay(300)
                            continue
                        }
                        val pollElapsedNanos =
                            SystemClock.elapsedRealtimeNanos() - pollStartedAtNanos
                        if (grabbed == null) {
                            recordStartupPoll(elapsedNanos = pollElapsedNanos, busy = true)
                            if (!liveViewStable) startupBusyResponses++
                            delay(40)
                            continue
                        }
                        recordStartupPoll(elapsedNanos = pollElapsedNanos, success = true)
                        errStreak = 0
                        frameCh.trySend(grabbed)
                        val now = SystemClock.elapsedRealtime()
                        if (!liveViewStable && requiresUsbStabilization) {
                            startupSuccessfulFrames++
                            if (startupSuccessfulFrames >= USB_LIVE_VIEW_STABLE_FRAMES) {
                                liveViewStable = true
                                devLog(
                                    "LV USB stable: frames=$startupSuccessfulFrames " +
                                        "busy=$startupBusyResponses " +
                                        "elapsed=${now - stabilizationStartedAt}ms; uncapped"
                                )
                            }
                        }
                        if (windowStart == 0L) {
                            windowStart = now
                            continue
                        }
                        frameIntervals++
                        if (now - windowStart >= 1000) {
                            fps = frameIntervals * 1000f / (now - windowStart)
                            frameIntervals = 0
                            windowStart = now
                        }
                    }
                    // 断流重启前先主动关一次 LV：错误退出时相机侧 LV 状态未知，带着
                    // 未关的 LV 直接重开会吃 InvalidStatus、rcSetLvSize 也不生效；
                    // 关闭失败无所谓（可能本就已掉出 LV）。
                    fps = 0f
                    liveViewStable = false
                    if (isActive) runCatching { cam.labEndLiveView() }
                    delay(2000)
                }
            } finally {
                liveViewStable = false
                withContext(NonCancellable) {
                    runCatching { cameraViewModel.getCamera()?.labEndLiveView() }
                }
            }
        }
    }

    suspend fun prepareUsbMovieSession(cam: NikonCamera): NikonCamera? {
        val oldLvJob = lvJob
        oldLvJob?.cancelAndJoin()
        if (lvJob === oldLvJob) lvJob = null
        if (cameraViewModel.getCamera() !== cam) return null

        movieUsbSessionDiagnostic = runCatching {
            cam.refreshUsbRemoteSession()
        }.getOrElse { "session error=${it.javaClass.simpleName}" }
        movieUsbSessionDiagnostic?.let(::devLog)

        val rc = runCatching { cam.rcSetControlMode(true) }.getOrDefault(-1)
        devLog("SetControlMode(1) resp=0x%04X".format(rc and 0xFFFF))
        if (rc != Lab.OK) return null

        // Match Nikon's USB tethering order exactly: XGA profile and
        // StartLiveView immediately after control mode, before property reads.
        val profileRc = runCatching { cam.rcSetLvSize(3) }.getOrDefault(-1)
        val started = runCatching {
            cam.labStartLiveView { devLog(it) }
        }.getOrDefault(false)
        movieUsbSessionDiagnostic =
            "${movieUsbSessionDiagnostic.orEmpty()} lv3=0x%04X/%s".format(
                profileRc and 0xFFFF,
                if (started) "Y" else "N"
            ).trim()
        return cam.takeIf { started }
    }

    suspend fun awaitMovieCompletion(cam: NikonCamera): Boolean =
        withTimeoutOrNull(8_000L) {
            while (true) {
                val events = runCatching { cam.rcPollEvents() }.getOrDefault(emptyList())
                for (event in events) {
                    eventFlow.emit(event)
                    if (event.first == Lab.EVT_OBJECT_ADDED) {
                        cameraViewModel.onCameraObjectAdded(event.second.toInt())
                    }
                    if (event.first == Lab.EVT_NK_MOVIE_REC_COMPLETE ||
                        event.first == Lab.EVT_NK_MOVIE_REC_INTERRUPTED
                    ) {
                        return@withTimeoutOrNull true
                    }
                }
                delay(200L)
            }
        } == true

    suspend fun releaseUsbMovieSession(cam: NikonCamera): Boolean {
        if (recording) {
            val rc = runCatching { cam.rcEndMovie() }.getOrDefault(-1)
            if (rc != Lab.OK) {
                devLog("!! movie end before photo mode resp=0x%04X".format(rc and 0xFFFF))
                return false
            }
            recording = false
            if (!awaitMovieCompletion(cam)) {
                devLog("!! movie completion event timeout before photo mode")
            }
        }
        val oldLvJob = lvJob
        if (oldLvJob != null) {
            oldLvJob.cancelAndJoin()
        } else {
            // prepareUsbMovieSession 已经同步启动、但取帧任务尚未来得及接管时也要
            // 明确结束 LV，不能带着活动 LV 直接退出电脑控制。
            runCatching { cam.labEndLiveView() }
        }
        if (lvJob === oldLvJob) lvJob = null
        clearAppMode(cam, force = true)
        for (attempt in 0 until 3) {
            val rc = runCatching { cam.rcSetControlMode(false) }.getOrDefault(-1)
            devLog("SetControlMode(0) resp=0x%04X".format(rc and 0xFFFF))
            if (rc == Lab.OK) break
            if (attempt < 2) delay(300L)
        }
        return !cam.remoteControlModeSet
    }

    suspend fun returnUsbMovieSessionToStandby(cam: NikonCamera) {
        initialLoaded = false
        val rebuildLiveView = releaseUsbMovieSession(cam)
        if (cameraViewModel.getCamera() === cam) {
            if (rebuildLiveView) startSession(hdLiveView)
            // 即使释放失败也不能把事件轮询永久关掉；相机稍后自行结束录像时，
            // 完成事件仍有机会触发下一次清理。
            initialLoaded = true
        }
    }

    suspend fun refreshMovieMode(refreshExposureOnChange: Boolean = true) {
        val cam = cameraViewModel.getCamera() ?: return
        val mv = runCatching { cam.rcGetMovieMode() }.getOrNull() ?: return
        val was = movieMode
        movieMode = mv
        if (refreshExposureOnChange && mv && !was) {
            // 切入录像位：拉取录像侧独立参数组（照片/录像两套属性互不相通）
            MOVIE_EXPOSURE_PROPS.forEach { refreshParam(it) }
            // Auto ISO 的属性码在 Nikon Z 系与照片模式共用，但描述中的当前值/
            // 可写性会随拨杆和曝光模式变化，必须在切换后重新读取。
            refreshAutoIso()
        }
        if (!mv) {
            recording = false
            clearAppMode()
            // 切回照片位：照片侧值域/可写性可能在录像期间变过，重新拉一遍
            if (refreshExposureOnChange && was) {
                EXPOSURE_PROPS.forEach { refreshParam(it) }
                refreshAutoIso()
            }
        }
    }

    // 在页期间暂停后台缩略图填充：把 ioMutex 完全让给取帧与参数加载，
    // 否则每条启动命令都排在 GetThumb 后面，进页要等好几秒。退出自动恢复。
    DisposableEffect(Unit) {
        cameraViewModel.setRemoteActive(true)
        onDispose { cameraViewModel.setRemoteActive(false) }
    }

    // 进页/重连：先拉参数与模式（快速往返，胶囊和徽标立刻点亮）再启动监看——LV 首帧
    // 反正要等相机预热（DeviceReady 常见 1s+），参数若排在取帧流后面才真叫慢；
    // 型号是装饰信息，最后后台拉。
    LaunchedEffect(connected) {
        if (!connected) {
            // 掉线时暂停事件轮询（下面的 initialLoaded 门），重连后参数重读
            // 依然先于轮询，与首次进页同样不抢锁。
            initialLoaded = false
            movieMode = false
            return@LaunchedEffect
        }
        val sessionCamera = cameraViewModel.getCamera() ?: return@LaunchedEffect
        try {
            // 新连接不继承上一条连接的拨杆状态。首次读取失败时按照片模式处理，优先
            // 保证机身画面与快门不被错误锁进电脑控制模式。
            movieMode = false
            // 先确定照片/视频拨杆，再只读取对应的一组参数。旧流程先读照片组、随后切到
            // 视频组，会表现为参数出现、清空、再加载一遍。
            refreshMovieMode(refreshExposureOnChange = false)
            // USB 待机始终使用普通 PTP Live View，让机身拨杆保持可读；电脑远控只在
            // 用户真正开始录像时临时进入，停止后立即退出。
            val hadStaleUsbMovieSession = shouldReturnUsbMovieSessionToStandby(
                    sessionCamera.connectionType,
                    sessionCamera.remoteControlModeSet
                )
            if (hadStaleUsbMovieSession && releaseUsbMovieSession(sessionCamera)) {
                // 电脑控制中的 D1A6 可能仍是进入控制前的录像值；归还机身后立即重读，
                // 避免重进页面时先按错误模式加载整套参数。
                refreshMovieMode(refreshExposureOnChange = false)
            }
            val initialExposureProps =
                if (movieMode) MOVIE_EXPOSURE_PROPS else EXPOSURE_PROPS
            initialExposureProps.forEach { refreshParam(it) }
            refreshAutoIso()
            refreshMode()
            refreshFocusMode()
            initialLoaded = true
            startSession(hdLiveView)
            awaitCancellation()
        } finally {
            if (sessionCamera.connectionType == CameraConnectionType.USB &&
                sessionCamera.remoteControlModeSet
            ) {
                withContext(NonCancellable) {
                    // 异常退出兜底：正常停录已经归还控制，这里只处理页面在录像中退出。
                    if (recording) {
                        runCatching { sessionCamera.rcEndMovie() }
                        recording = false
                    }
                    val oldLvJob = lvJob
                    oldLvJob?.cancelAndJoin()
                    if (lvJob === oldLvJob) lvJob = null
                    clearAppMode(sessionCamera, force = true)
                    val rc = runCatching {
                        sessionCamera.rcSetControlMode(false)
                    }.getOrDefault(-1)
                    devLog("SetControlMode(0) resp=0x%04X".format(rc and 0xFFFF))
                }
            }
        }
    }

    val autoIsoParam = autoIsoProp?.let { params[it] }
    val autoIsoEnabled = autoIsoParam?.current?.let { it != 0L }
    // 不根据曝光模式字符串禁用：Z30 等机型会返回 0x8010 一类扩展枚举。
    // 可用性完全由当前拨杆位置下相机返回的可写二值属性决定。
    val autoIsoAvailable = autoIsoParam?.writable == true &&
        autoIsoEnabled != null
    val effectiveAutoIsoValue =
        params[Lab.PROP_NK_ISO_CONTROL_SENSITIVITY]?.current

    // AUTO 开启时，照片和录像都从只读 D0B5 取得相机当前实际采用的 ISO。
    // D1AA 是录像侧的用户设定/基础 ISO，开启自动后不会随测光持续变化，不能用于读数。
    // 这里只轮询标量值，500ms 一次足够跟随测光变化，也不会重复拉取属性描述。
    LaunchedEffect(connected, movieMode, autoIsoProp, autoIsoEnabled, liveViewStable) {
        if (!connected || !liveViewStable || autoIsoEnabled != true) {
            return@LaunchedEffect
        }
        val cam = cameraViewModel.getCamera() ?: return@LaunchedEffect
        val effectiveProp = Lab.PROP_NK_ISO_CONTROL_SENSITIVITY
        var initialEffective = params[effectiveProp]
        var acquireAttempts = 0
        while (isActive && initialEffective == null && acquireAttempts < 8) {
            initialEffective = runCatching { cam.rcGetParam(effectiveProp) }.getOrNull()
            if (initialEffective == null) delay(150)
            acquireAttempts++
        }
        var effective = initialEffective ?: return@LaunchedEffect
        params[effectiveProp] = effective
        while (isActive) {
            runCatching { cam.rcRefreshParam(effective) }.getOrNull()?.let {
                effective = it
                params[effectiveProp] = it
            }
            delay(500)
        }
    }

    // ---------- 电子水平仪（AngleLevel 0xD067）----------
    // 角度取自【相机机身】而非手机传感器：相机在架子上、手机在手里，只有相机自身姿态
    // 对构图有意义。只在水平仪打开时轮询，关掉就一条命令都不发——本页所有相机 I/O
    // 共用 ioMutex，多一个常驻轮询就是白占取帧通道。250ms 对水平指示足够跟手。
    // 机身不支持该属性（GetDevicePropDesc 失败）时把开关弹回去，绝不显示假角度。
    LaunchedEffect(showLevel, connected) {
        if (!showLevel || !connected) {
            levelRoll = null
            return@LaunchedEffect
        }
        // 与进页首批参数读取错开，别抢 ioMutex 拖慢参数首显（同事件轮询的处理）。
        while (isActive && !initialLoaded) delay(150)
        val cam = cameraViewModel.getCamera() ?: return@LaunchedEffect
        val described = runCatching { cam.rcGetAngleLevel() }.getOrNull()
        if (described == null) {
            levelRoll = null
            showLevel = false
            devLog("!! angle level unavailable (0xD067 poll)")
            return@LaunchedEffect
        }
        // 首次读到就把原始值打进开发者面板：编码（16.16 定点度数）与正负方向都要
        // 真机核对，日志里同时留 raw 和换算值才能对着机身自己的水平仪校准。
        var param: RcParam = described
        var loggedRoll = Float.NaN
        var failures = 0
        while (isActive) {
            val roll = rcAngleLevelRoll(param)?.let {
                // 量化到 0.1°：机身读数的细微抖动就不会每 250ms 触发一次无意义重组。
                (it * 10f).roundToInt() / 10f
            }
            if (roll != null) {
                if (levelRoll != roll) levelRoll = roll
                // 每次变化都打会刷爆 300 行的面板；变化超过 0.5° 才记一条。
                if (loggedRoll.isNaN() || abs(roll - loggedRoll) >= 0.5f) {
                    loggedRoll = roll
                    devLog(
                        "angle level 0xD067 poll type=0x%04X raw=%d roll=%+.1f°"
                            .format(param.dataType, param.current, roll)
                    )
                }
            }
            delay(250)
            // 偶发读失败（忙/抖动）留着上一次的角度继续试；连续失败则收回读数，
            // 不让画面停在一条早已过时的水平线上。
            val refreshed = runCatching { cam.rcRefreshParam(param) }.getOrNull()
            if (refreshed != null) {
                param = refreshed
                failures = 0
            } else if (++failures >= 3) {
                levelRoll = null
                devLog("!! angle level 0xD067 poll read failed 3x, stopping")
                break
            }
        }
    }

    // 事件轮询：唯一的 GetEvent 消费者。参数被机身侧改动（0x4006）时刷新对应值域。
    LaunchedEffect(Unit) {
        var pollTick = 0
        while (isActive) {
            // 让初始参数先加载完再开始轮询，避免抢锁拖慢进页
            if (!initialLoaded) { delay(150); continue }
            val cam = cameraViewModel.getCamera()
            if (cam == null) { delay(1500); continue }
            if (!liveViewStable) {
                // 正常停止后若退出电脑控制连续失败，在没有取帧任务争用时继续有界重试；
                // 一旦成功便重建普通 LV，避免一次瞬时忙永久锁住机身拨杆。
                if (!recording && !recBusy && shouldReturnUsbMovieSessionToStandby(
                        cam.connectionType,
                        cam.remoteControlModeSet
                    )
                ) {
                    delay(600)
                    returnUsbMovieSessionToStandby(cam)
                    continue
                }
                // 拨杆切换会先让旧 Live View 失效；此时仍须独立读取 D1A6 更新界面。
                // 录制/拍摄命令期间不读，避免抢占 USB 命令序列或误信电脑控制中的旧值。
                delay(600)
                if (shouldPollMovieModeDuringLiveViewRecovery(
                        initialLoaded = initialLoaded,
                        liveViewStable = liveViewStable,
                        cameraBusy = capturing || recording || recBusy
                    )
                ) {
                    refreshMovieMode()
                }
                continue
            }
            val polledEvents = runCatching { cam.rcPollEvents() }
            if (polledEvents.isFailure) {
                // GetEvent 异常不能连带禁用拨杆兜底；否则部分 USB 会话虽然仍能读取
                // D1A6，却会因为事件通道暂时失败而永远停留在旧模式界面。
                pollTick++
                if (pollTick % 5 == 0 && !capturing && !recording && !recBusy) {
                    refreshMovieMode()
                }
                delay(600)
                continue
            }
            val suppressStartupPropertyRefresh = startupEventBaselinePending
            startupEventBaselinePending = false
            val events = coalesceRemoteEvents(
                events = polledEvents.getOrDefault(emptyList()),
                suppressPropertyChanges = suppressStartupPropertyRefresh
            )
            var movieModeRefreshRequested = false
            for (e in events) {
                eventFlow.emit(e)
                when (e.first) {
                    // 新照片入卡(遥控拍摄或此刻按了机身快门都会到这):转交列表层插入,
                    // 用户退回照片列表就能看到。本页开着时 VM 的事件轮询是停的
                    //(GetEvent 取走即消费),转交是新照片进列表的唯一通路。
                    Lab.EVT_OBJECT_ADDED ->
                        cameraViewModel.onCameraObjectAdded(e.second.toInt())
                    // 录像状态以相机事件为准（卡满/过热等相机自行停录也能收到）。
                    // 例外：本地刚（2s 内）发过停止命令时忽略"已开始"——那是上一次开始
                    // 的迟到回声（开始+停止落在同一轮询窗口内），别把 UI 翻回录制中。
                    // 停止方向的事件永远接受：宁可误停（可再按开始），不可卡在录制态。
                    Lab.EVT_NK_MOVIE_REC_STARTED -> {
                        if (System.currentTimeMillis() - lastStopCmdAt > 2000) recording = true
                    }
                    Lab.EVT_NK_MOVIE_REC_COMPLETE, Lab.EVT_NK_MOVIE_REC_INTERRUPTED -> {
                        recording = false
                        // 用户主动停止时 toggleRecord 负责等完成事件并清理；相机因卡满、
                        // 过热等自行停止时事件循环必须接管，不能把应用模式留在机身上。
                        if (!recBusy) {
                            if (shouldReturnUsbMovieSessionToStandby(
                                    cam.connectionType,
                                    cam.remoteControlModeSet
                                )
                            ) {
                                returnUsbMovieSessionToStandby(cam)
                            } else {
                                clearAppMode()
                            }
                        }
                    }
                    Lab.EVT_DEVICE_PROP_CHANGED -> {
                        val reportedProp = e.second.toInt()
                        val prop = rcCanonicalExposureProp(reportedProp)
                        if (reportedProp in ALL_AUTO_ISO_PROPS) refreshAutoIso()
                        if (reportedProp == Lab.PROP_NK_ISO_CONTROL_SENSITIVITY &&
                            autoIsoProp?.let { params[it]?.current != 0L } == true
                        ) {
                            params[reportedProp]?.let { current ->
                                runCatching { cam.rcRefreshParam(current) }.getOrNull()?.let {
                                    params[reportedProp] = it
                                }
                            }
                        }
                        // 本地还有未发出的乐观值时不刷新——自己刚设的值触发的事件
                        // 会把正在连调的显示值拽回去。照片/录像两套参数都听。
                        if (prop in ALL_EXPOSURE_PROPS && pendingSets[prop]?.isActive != true) {
                            refreshParam(prop)
                        }
                        if (prop == Lab.PROP_EXPOSURE_PROGRAM) {
                            refreshMode()
                            // 曝光模式变化会连带改变各参数的可写性/值域（正在连调中的
                            // 除外，同上）。只刷当前拨杆位对应的那组。
                            val active = if (movieMode) MOVIE_EXPOSURE_PROPS else EXPOSURE_PROPS
                            active.forEach {
                                if (pendingSets[it]?.isActive != true) refreshParam(it)
                            }
                            refreshAutoIso()
                        }
                        if (prop == Lab.PROP_FOCUS_MODE || prop == Lab.PROP_NK_AF_MODE ||
                            prop == focusModeProp
                        ) {
                            refreshFocusMode()
                        }
                        if (prop == Lab.PROP_NK_LV_SELECTOR) {
                            // 先处理完同批录像完成/中断事件，再切换 USB 会话，避免在
                            // 当前事件消费者内部等待一个其实已经取到的完成事件。
                            movieModeRefreshRequested = true
                        }
                    }
                }
            }
            if (movieModeRefreshRequested && !recording && !recBusy) refreshMovieMode()
            // 照片/录像拨杆兜底轮询：拨杆切换不一定可靠地发 0x4006（机型差异），
            // 每 5 轮（约 3s）主动读一次——单条小命令，相对取帧流量可忽略。
            // 拍摄确认期间跳过：那时轮询提速到 150ms，通道要让给 ObjectAdded。
            pollTick++
            if (pollTick % 5 == 0 && !capturing && !recording && !recBusy &&
                !movieModeRefreshRequested
            ) {
                refreshMovieMode()
            }
            // 等拍摄确认期间加快轮询，快门转圈更快收到 ObjectAdded；平时 600ms 少占通道。
            delay(if (capturing) 150 else 600)
        }
    }

    // ---------- 调参 ----------
    // 步进采用"乐观更新 + 尾值合并"：本地值立即跟手（长按连调不卡），停手 160ms 后
    // 只把最终值发给相机——逐档发送会在 ioMutex 上排队，连调十几档要追几秒。
    fun sendValue(prop: Int, value: Long, immediate: Boolean) {
        val p = params[prop] ?: return
        params[prop] = p.copy(current = value)
        haptics.tick()
        pendingSets[prop]?.cancel()
        pendingSets[prop] = scope.launch {
            if (!immediate) delay(160)
            val cam = cameraViewModel.getCamera() ?: return@launch
            val result = try {
                cam.rcSetValueVerified(p, value)
            } catch (e: CancellationException) {
                throw e   // 被更新一步的 sendValue 顶掉，不是写失败：别记日志、别回读
            } catch (e: Exception) {
                null
            }
            result?.actual?.let { params[prop] = it }
            if (result?.confirmed != true) {
                val rc = result?.responseCode ?: -1
                val actual = result?.actual?.current?.toString() ?: "unreadable"
                devLog(
                    "!! set logical=0x%04X actual=0x%04X target=%d read=%s resp=0x%04X"
                        .format(prop, p.prop, value, actual, rc and 0xFFFF)
                )
                // 包括返回 OK 但机身没有采用的情况：重新读取描述和值域，显示真实状态。
                refreshParam(prop)
            }
        }
    }

    fun stepParam(prop: Int, delta: Int) {
        val p = params[prop] ?: return
        if (!p.writable || p.values.isEmpty()) return
        // 起点用共用锚点（精确命中或按物理量最近档）：当前值不在枚举里时哪怕 delta
        // 走不动也发一次，把值吸附回枚举，否则拖动完全失灵（indexOf 永远 -1）。
        val from = paramAnchorIdx(prop, p.values, p.current)
        val newIdx = (from + delta).coerceIn(0, p.values.size - 1)
        if (newIdx == from && p.values[from] == p.current) return
        sendValue(prop, p.values[newIdx], immediate = false)
    }

    // 拍摄：capturing 从触发一直保持到收到 ObjectAdded（相机确认新照片已生成）——
    // 快门键转圈即"正在等待拍摄确认"，收到确认/超时/失败即停。不读取也不展示缩略图。
    fun shoot(waitForFocus: Job? = null) {
        if (capturing || probing) return
        val expectedCamera = cameraViewModel.getCamera() ?: return
        // 在 launch 前同步置位，消除两次快速点按同时通过 capturing=false
        // 而启动两个拍摄事务的小窗口。
        capturing = true
        scope.launch {
            try {
                // 快速松手时 AF 可能仍在轮询 DeviceReady。先收完对焦事务，
                // 再开始 ObjectAdded 的 12s 倒计，避免把 AF 等待时间错算进拍摄超时。
                waitForFocus?.join()
                // 等待期间若发生了断线/重连，绝不把旧手势意外发给新会话。
                if (cameraViewModel.getCamera() !== expectedCamera) return@launch
                val cam = expectedCamera
                haptics.longPress()   // 快门触发反馈（经全局震动设置门控）
                // 先挂事件等待、再触发拍摄：ObjectAdded 是取走即消费的，
                // 订阅晚于轮询取走就永远等不到了。
                val pending = async {
                    withTimeoutOrNull(12_000) {
                        eventFlow.first {
                            it.first == Lab.EVT_OBJECT_ADDED || it.first == Lab.EVT_OBJECT_ADDED_SDRAM
                        }.second.toInt()
                    }
                }
                val rc = runCatching { cam.rcCapture() }.getOrDefault(-1)
                if (rc != Lab.OK) {
                    pending.cancel()
                    devLog("!! capture resp=0x%04X".format(rc and 0xFFFF))
                    return@launch
                }
                val handle = pending.await()   // 拍摄成功的确认信号
                if (handle == null) devLog("!! capture: no ObjectAdded in 12s")
                else devLog("shot ok: handle=0x%08X".format(handle))
            } finally {
                capturing = false
            }
        }
    }

    // 模拟半按对焦：按住快门键时在当前对焦点执行一次完整 AF，
    // 松开手指在按钮内 = 拍摄，手指移出按钮 = 取消不拍。对焦框在按住期间显示。
    // 抓包已证实 AfDrive 的立即 OK 只是“已开始”，需轮询 DeviceReady 才能
    // 区分合焦 OK 与 OutOfFocus；也不能循环重发 AfDrive。
    var afHeld by remember { mutableStateOf(false) }
    var afLocked by remember { mutableStateOf(false) }   // 当前是否已合焦（对焦框变绿）
    var afJob by remember { mutableStateOf<Job?>(null) }
    var tapFocusFeedback by remember { mutableStateOf(TapFocusFeedback.IDLE) }
    // tapFocusPoint 是本次点击的瞬时反馈位置；focusAreaPoint 只在相机确认
    // ChangeAfArea 成功后更新，供后续半按 AF 与安全回退使用。
    var tapFocusPoint by remember { mutableStateOf(Offset(0.5f, 0.5f)) }
    var focusAreaPoint by remember { mutableStateOf(Offset(0.5f, 0.5f)) }
    var tapFocusNonce by remember { mutableIntStateOf(0) }
    var tapFocusBusy by remember { mutableStateOf(false) }
    var tapFocusJob by remember { mutableStateOf<Job?>(null) }
    var tapFocusHideJob by remember { mutableStateOf<Job?>(null) }
    // 与瞬时蓝/绿反馈分离：AF 成功后保留细红框，并在合焦完成 3 秒后自动隐藏。
    // 相机帧头没有可信 AF 框时使用这里保存的应用请求点作为安全回退。
    var confirmedFocusMarker by remember { mutableStateOf<ConfirmedFocusMarker?>(null) }
    fun startFocus() {
        if (afHeld || tapFocusBusy || probing || focusModeManual || afJob?.isActive == true) return
        tapFocusHideJob?.cancel()
        tapFocusFeedback = TapFocusFeedback.IDLE
        confirmedFocusMarker = null
        afHeld = true
        afLocked = false
        val requestedPoint = focusAreaPoint
        haptics.tick()   // 开始半按的轻反馈
        afJob?.cancel()
        afJob = scope.launch {
            val cam = cameraViewModel.getCamera() ?: return@launch
            val result = try {
                cam.rcAfDriveAndWait()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (e is SocketTimeoutException) cameraViewModel.onCameraTransportLost(cam)
                devLog("!! AF exception: ${e.message}")
                return@launch
            }
            val stillHeld = afHeld
            afLocked = stillHeld && result.responseCode == Lab.OK
            val suffix = "polls=${result.polls} elapsed=${result.elapsedMs}ms"
            when {
                result.responseCode == Lab.OK -> {
                    devLog("AF locked ($suffix)")
                    confirmedFocusMarker = ConfirmedFocusMarker(
                        fallbackPoint = requestedPoint,
                        confirmedAtElapsedMs = SystemClock.elapsedRealtime()
                    )
                    // 用户已松手/滑出时仍把协议终态收完，但不再给迟到的
                    // 合焦震动，避免“取消后手机又震一下”。
                    if (stillHeld) haptics.tick()
                }
                result.responseCode == Lab.NK_OUT_OF_FOCUS ->
                    devLog("!! AF out of focus ($suffix)")
                result.timedOut -> devLog("!! AF timeout ($suffix)")
                else -> devLog(
                    "!! AF result=0x%04X ($suffix)".format(result.responseCode and 0xFFFF)
                )
            }
        }
    }
    fun endFocus(cancelPending: Boolean = false): Job? {
        val pending = afJob
        afHeld = false
        afLocked = false
        // 普通松手不取消协议等待：相机端 AF 已经开始，只取消本地协程
        // 会留下“UI 已结束、相机仍在对焦”的分裂状态。拍摄/录像命令会
        // 显式等待这个任务到达 AF 终态。只在断连时取消等待。
        if (cancelPending) {
            pending?.cancel()
            afJob = null
        }
        return pending
    }
    // 断连兜底：若在按住对焦期间相机掉线，快门键手势节点会被卸载、onRelease 不再执行，
    // 导致 afHeld/afJob 卡住（对焦框不消失、对空相机空转刷日志）。这里主动复位。
    // 录制状态一并复位（相机侧断线会自行停录）。
    LaunchedEffect(connected) {
        if (!connected) {
            endFocus(cancelPending = true)
            tapFocusJob?.cancel()
            tapFocusHideJob?.cancel()
            tapFocusBusy = false
            tapFocusFeedback = TapFocusFeedback.IDLE
            confirmedFocusMarker = null
            tapFocusPoint = Offset(0.5f, 0.5f)
            focusAreaPoint = Offset(0.5f, 0.5f)
            focusModeQueried = false
            recording = false
        }
    }

    fun runProbe() {
        if (probing) return
        val cam = cameraViewModel.getCamera() ?: return
        scope.launch {
            probing = true
            // 一次探测对应一份可直接回传的完整报告，避免混入旧会话日志。
            logLines.clear()
            try {
                lvJob?.cancelAndJoin()   // 探测自带 LV 测试，先停会话
                cam.runLabProbe({ devLog(it) }, { bytes -> decode(bytes)?.let { frame = it } })
            } catch (e: Exception) {
                devLog("!! probe: $e")
            } finally {
                probing = false
                startSession(hdLiveView)
            }
        }
    }

    // ---------- 提示条（首次进页的一次性机身锁定提示 + 录像失败等瞬时提示）----------
    // 传输中已在照片列表侧禁止进入本页，故不再需要"传输卡顿"提示。
    // nonce 方案（与照片列表页同款）：唯一的隐藏计时器跟着 nonce 重启，连续触发时
    // 后一条重新计满时长，不会被前一条的旧计时器提前掐掉。
    var hintText by remember { mutableStateOf("") }
    var hintVisible by remember { mutableStateOf(false) }
    var hintNonce by remember { mutableIntStateOf(0) }
    var hintDurationMs by remember { mutableLongStateOf(2500L) }
    fun showHint(text: String, durationMs: Long = 2500L) {
        hintText = text
        hintDurationMs = durationMs
        hintVisible = true
        hintNonce++
    }
    LaunchedEffect(hintNonce) {
        if (hintVisible) {
            delay(hintDurationMs)
            hintVisible = false
        }
    }
    // ---------- 录像开关 ----------
    // 开始：命令成功即乐观置位（UI 立即变停止键），事件 0xC10A 再确认；失败弹瞬时提示。
    // 停止：只有 EndMovieRec 成功才切换 UI；失败时保留录像态，避免 UI 与相机相反。
    // recBusy 防抖：命令往返期间忽略连点。
    var recSeconds by remember { mutableIntStateOf(0) }
    val recFailHint = stringResource(R.string.remote_rec_start_failed)
    val recStopFailHint = stringResource(R.string.remote_rec_stop_failed)
    val manualFocusHint = stringResource(R.string.remote_tap_focus_manual)

    fun focusAt(tap: ViewfinderTap) {
        if (!connected || capturing || tapFocusBusy || afHeld || probing || afJob?.isActive == true) return
        if (focusModeManual) {
            devLog("!! tap AF ignored: camera focus mode is MF")
            showHint(manualFocusHint)
            return
        }
        val cam = cameraViewModel.getCamera() ?: return
        tapFocusHideJob?.cancel()
        confirmedFocusMarker = null
        tapFocusPoint = tap.normalized
        tapFocusFeedback = TapFocusFeedback.FOCUSING
        tapFocusNonce++
        tapFocusBusy = true
        haptics.tick()
        devLog(
            "tap AF point=(${tap.focusX},${tap.focusY}) " +
                "grid=${tap.focusCoordinateWidth}x${tap.focusCoordinateHeight}"
        )
        tapFocusJob = scope.launch {
            try {
                val result = cam.rcFocusAt(tap.focusX, tap.focusY)
                val af = result.afResult
                if (result.moveResponseCode == Lab.OK) {
                    focusAreaPoint = tap.normalized
                }
                tapFocusFeedback = if (result.moveResponseCode != Lab.OK || af == null) {
                    devLog(
                        "!! ChangeAfArea resp=0x%04X".format(result.moveResponseCode and 0xFFFF)
                    )
                    TapFocusFeedback.FAILED
                } else {
                    val suffix = "polls=${af.polls} elapsed=${af.elapsedMs}ms"
                    when {
                        af.responseCode == Lab.OK -> {
                            devLog("tap AF locked ($suffix)")
                            haptics.tick()
                            confirmedFocusMarker = ConfirmedFocusMarker(
                                fallbackPoint = tap.normalized,
                                confirmedAtElapsedMs = SystemClock.elapsedRealtime()
                            )
                            TapFocusFeedback.LOCKED
                        }
                        af.responseCode == Lab.NK_OUT_OF_FOCUS -> {
                            devLog("!! tap AF out of focus ($suffix)")
                            TapFocusFeedback.FAILED
                        }
                        af.timedOut -> {
                            devLog("!! tap AF timeout ($suffix)")
                            TapFocusFeedback.FAILED
                        }
                        else -> {
                            devLog(
                                "!! tap AF result=0x%04X ($suffix)".format(
                                    af.responseCode and 0xFFFF
                                )
                            )
                            TapFocusFeedback.FAILED
                        }
                    }
                }
                val completedNonce = tapFocusNonce
                val focusLocked = tapFocusFeedback == TapFocusFeedback.LOCKED
                tapFocusHideJob = scope.launch {
                    delay(if (focusLocked) TAP_FOCUS_LOCKED_FEEDBACK_MS else 1_300L)
                    if (tapFocusNonce == completedNonce) {
                        tapFocusFeedback = TapFocusFeedback.IDLE
                    }
                    if (focusLocked) {
                        delay(TAP_FOCUS_MARKER_VISIBLE_MS - TAP_FOCUS_LOCKED_FEEDBACK_MS)
                        if (tapFocusNonce == completedNonce) {
                            confirmedFocusMarker = null
                        }
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (e is SocketTimeoutException) cameraViewModel.onCameraTransportLost(cam)
                tapFocusFeedback = TapFocusFeedback.FAILED
                confirmedFocusMarker = null
                devLog("!! tap AF exception: ${e.message}")
                val completedNonce = tapFocusNonce
                tapFocusHideJob = scope.launch {
                    delay(1_300)
                    if (tapFocusNonce == completedNonce) {
                        tapFocusFeedback = TapFocusFeedback.IDLE
                    }
                }
            } finally {
                tapFocusBusy = false
                tapFocusJob = null
            }
        }
    }

    fun setAutoIso(enabled: Boolean) {
        val p = autoIsoProp?.let { params[it] } ?: return
        if (!p.writable || autoIsoBusy) return
        val target = if (enabled) {
            p.values.firstOrNull { it != 0L } ?: 1L
        } else {
            p.values.firstOrNull { it == 0L } ?: 0L
        }
        val requestedMovieMode = movieMode
        if ((p.current != 0L) == enabled) return

        autoIsoBusy = true
        params[p.prop] = p.copy(current = target)
        params.remove(Lab.PROP_NK_ISO_CONTROL_SENSITIVITY)
        haptics.tick()
        scope.launch {
            try {
                val cam = cameraViewModel.getCamera()
                if (cam == null) {
                    params[p.prop] = p
                    return@launch
                }
                val candidates = buildList {
                    add(p)
                    if (requestedMovieMode) {
                        rcAutoIsoCandidateProps(movieMode = true)
                            .filterNot { it == p.prop }
                            .forEach { prop ->
                                runCatching { cam.rcGetParam(prop) }.getOrNull()
                                    ?.takeIf { it.rcIsBinaryToggle() }
                                    ?.let(::add)
                            }
                    }
                }
                var confirmedParam: RcParam? = null
                for (candidate in candidates) {
                    val candidateTarget = if (enabled) {
                        candidate.values.firstOrNull { it != 0L } ?: 1L
                    } else {
                        candidate.values.firstOrNull { it == 0L } ?: 0L
                    }
                    if ((candidate.current != 0L) == enabled) {
                        confirmedParam = candidate
                        break
                    }
                    val result = runCatching {
                        cam.rcSetValueVerified(candidate, candidateTarget)
                    }.getOrNull()
                    result?.actual?.let { params[candidate.prop] = it }
                    if (result?.confirmed == true) {
                        confirmedParam = result.actual ?: candidate.copy(current = candidateTarget)
                        devLog(
                            "Auto ISO prop=0x%04X set=%d confirmed".format(
                                candidate.prop,
                                candidateTarget
                            )
                        )
                        break
                    }
                    if (candidate.prop == p.prop && result?.actual == null) {
                        params[p.prop] = p
                    }
                    val rc = result?.responseCode ?: -1
                    devLog(
                        "!! Auto ISO prop=0x%04X set/readback resp=0x%04X".format(
                            candidate.prop,
                            rc and 0xFFFF
                        )
                    )
                }
                confirmedParam?.let {
                    autoIsoProp = it.prop
                    autoIsoPropMovieMode = requestedMovieMode
                    params[it.prop] = it
                }
                refreshAutoIso()
                if (movieMode) refreshParam(Lab.PROP_NK_MOVIE_ISO)
            } finally {
                autoIsoBusy = false
            }
        }
    }

    fun toggleRecord(waitForFocus: Job? = null) {
        if (recBusy || probing) return
        val expectedCamera = cameraViewModel.getCamera() ?: return
        recBusy = true
        scope.launch {
            try {
                waitForFocus?.join()
                if (cameraViewModel.getCamera() !== expectedCamera) return@launch
                val cam = expectedCamera
                haptics.longPress()   // 与拍照同级的触发反馈（经全局震动设置门控）
                if (!recording) {
                    var restartedLiveView = false
                    var adoptedLiveView: NikonCamera? = null
                    val preparedUsbSession = shouldPrepareUsbMovieSessionForRecord(
                        cam.connectionType,
                        cam.remoteControlModeSet
                    )
                    if (preparedUsbSession) {
                        // 录像待机保持普通会话以放行机身拨杆；只在用户真正按下录像时
                        // 临时进入已验证的 Nikon USB 电脑远控序列。
                        initialLoaded = false
                        adoptedLiveView = prepareUsbMovieSession(cam)
                        restartedLiveView = true
                    }
                    val usbRemoteSession =
                        cam.connectionType == CameraConnectionType.USB &&
                            cam.remoteControlModeSet
                    // USB 的应用模式、存储目标与开录必须是不可被事件轮询打断的连续序列；
                    // Wi-Fi 保留已经验证的直接路径及有界恢复。
                    var result = runCatching {
                        if (usbRemoteSession) {
                            cam.rcPrepareAndStartMovieDetailed { devLog(it) }
                        } else {
                            cam.rcStartMovieDetailed { devLog(it) }
                        }
                    }.getOrNull()

                    if (!usbRemoteSession && result?.let {
                        movieStartNeedsLiveViewRestart(
                            it.responseCode,
                            it.prohibitCondition
                        )
                    } == true) {
                        // 应用模式必须先于 Live View 生效的机型：只做一次有界恢复。
                        // 先让旧会话完整 EndLiveView，再以正确前置状态重启；存储卡类
                        // 禁止位已在判定函数中排除，不会用重启掩盖真实卡错误。
                        val oldLvJob = lvJob
                        oldLvJob?.cancelAndJoin()
                        if (lvJob === oldLvJob) lvJob = null
                        if (cameraViewModel.getCamera() === cam) {
                            ensureApplicationMode(cam)
                            runCatching { cam.rcSetLvSize(if (hdLiveView) 3 else 2) }
                            val liveViewStarted = runCatching {
                                cam.labStartLiveView { devLog(it) }
                            }.getOrDefault(false)
                            restartedLiveView = true
                            if (liveViewStarted) {
                                adoptedLiveView = cam
                                result = runCatching {
                                    cam.rcStartMovieDetailed { devLog(it) }
                                }.getOrNull()
                            }
                        }
                    }

                    if (restartedLiveView) {
                        startSession(hdLiveView, adoptedLiveView)
                    }
                    if (preparedUsbSession) initialLoaded = true

                    val rc = result?.responseCode ?: -1
                    if (rc == Lab.OK || movieProhibitIndicatesRecording(result?.prohibitCondition)) {
                        recording = true
                        if (rc == Lab.OK) {
                            devLog("movie rec started")
                        } else {
                            // 页面重进或开始事件丢失时，相机可能已经在录。禁止位 bit10
                            // 是可靠状态信号：接管为录像态，下一次点击即可正常停止。
                            devLog("movie rec already active; adopting camera state")
                        }
                    } else {
                        devLog("!! movie start resp=0x%04X".format(rc and 0xFFFF))
                        if (shouldReturnUsbMovieSessionToStandby(
                                cam.connectionType,
                                cam.remoteControlModeSet
                            )
                        ) {
                            // 开录失败也必须立即归还机身；否则录像待机仍会锁住拨杆。
                            returnUsbMovieSessionToStandby(cam)
                        } else {
                            clearAppMode()
                        }
                        val diagnostic = listOfNotNull(
                            result?.diagnosticSummary(),
                            movieUsbSessionDiagnostic
                        ).joinToString("\n").ifEmpty { null }
                        showHint(
                            if (diagnostic == null) recFailHint
                            else "$recFailHint\n$diagnostic",
                            durationMs = 12_000L
                        )
                    }
                } else {
                    lastStopCmdAt = System.currentTimeMillis()   // 之后 2s 内的"已开始"事件按迟到回声忽略
                    val needsFinalizationWait =
                        cam.remoteMovieApplicationPropSet || cam.remoteMovieApplicationOpSet
                    // 仅兼容恢复路径需要等相机写卡完成再退出应用模式。旧机型沿用原
                    // 即时停止路径，不因缺少 Nikon 完成事件而多等 8 秒。
                    val completion = if (needsFinalizationWait) {
                        async(start = CoroutineStart.UNDISPATCHED) {
                            withTimeoutOrNull(8_000) {
                                eventFlow.first {
                                    it.first == Lab.EVT_NK_MOVIE_REC_COMPLETE ||
                                        it.first == Lab.EVT_NK_MOVIE_REC_INTERRUPTED
                                }
                            }
                        }
                    } else null
                    val rc = runCatching { cam.rcEndMovie() }.getOrDefault(-1)
                    if (rc == Lab.OK) {
                        recording = false
                        if (completion != null) {
                            val event = completion.await()
                            if (event == null) {
                                devLog("!! movie completion event timeout")
                            } else {
                                devLog("movie rec ended")
                            }
                        } else {
                            devLog("movie rec ended")
                        }
                        // Z 系可能需要数秒写完长 GOP；完成/中断事件之后再恢复应用模式。
                        // USB 随即回到普通录像待机会话，机身拨杆重新可读；下一次开录
                        // 再按需进入电脑远控，不在两次录像之间长期锁住机身。
                        if (shouldReturnUsbMovieSessionToStandby(
                                cam.connectionType,
                                cam.remoteControlModeSet
                            )
                        ) {
                            returnUsbMovieSessionToStandby(cam)
                        } else {
                            clearAppMode()
                        }
                    } else {
                        completion?.cancel()
                        devLog("!! movie end resp=0x%04X".format(rc and 0xFFFF))
                        // 命令失败时不能假装已经停止，也不能清应用模式；相机若其实已
                        // 自行停止，随后到达的完成/中断事件会纠正 recording 并清理。
                        showHint(
                            "$recStopFailHint\nstop=0x%04X".format(rc and 0xFFFF),
                            durationMs = 6000L
                        )
                    }
                }
            } finally {
                recBusy = false
            }
        }
    }

    fun finishShutterGesture(fire: Boolean) {
        val shutterFocus = endFocus()
        if (!fire) return
        val pendingFocus = shutterFocus?.takeIf { it.isActive }
            ?: tapFocusJob?.takeIf { it.isActive }
        if (movieMode) toggleRecord(pendingFocus) else shoot(pendingFocus)
    }

    // 录制计时（REC 徽标显示）：以本地 recording 状态起停，秒级精度足够。
    LaunchedEffect(recording) {
        recSeconds = 0
        while (recording) {
            delay(1000)
            recSeconds++
        }
    }

    fun toggleFpsControl() {
        showFps = !showFps
        val now = System.currentTimeMillis()
        fpsTaps = if (now - lastFpsTapAt < 1500) fpsTaps + 1 else 1
        lastFpsTapAt = now
        if (fpsTaps >= 4) devUnlocked = true
    }

    // ---------- 取景器录像（画面录制为 MP4）----------
    val recOutputDir = File(context.filesDir, "recordings")

    fun stopRecorder() {
        val r = viewfinderRecorder ?: return
        // 先同步置空：界面立即回到待机态，也挡住快速双击带来的二次 stop。
        viewfinderRecorder = null
        recPaused = false
        recElapsed = 0
        recJob?.cancel()
        recJob = null
        recFinalizing = true
        scope.launch {
            // NonCancellable：用户停录后立刻退出页面时也要把 muxer 收尾写完，
            // 否则 mp4 缺 moov 无法播放。
            val name = withContext(Dispatchers.IO + NonCancellable) {
                runCatching { r.stop() }.getOrNull()
            }
            recFinalizing = false
            if (name != null) {
                // 保存成功不再弹系统 Toast：对号与“已保存”短标签留在用户刚操作的
                // 胶囊上，配合成功触感短暂停留后再自动收回。
                recSaveFeedbackJob?.cancel()
                haptics.success()
                recSaveSuccess = true
                recSaveFeedbackJob = scope.launch {
                    delay(1_800)
                    recSaveSuccess = false
                }
            } else {
                recSaveFeedbackJob?.cancel()
                recSaveSuccess = false
                android.widget.Toast.makeText(
                    context,
                    context.getString(R.string.cd_remote_rec_toast_failed),
                    android.widget.Toast.LENGTH_SHORT
                ).show()
            }
        }
    }

    // 真正开录（麦克风权限结果已知）。录像优先落到用户配置的 SAF 传输目录
    // （相册/文件管理器可见）；未配置或建档失败回退应用私有目录，录制照常。
    fun startRecorderResolved(withAudio: Boolean) {
        if (viewfinderRecorder != null) return   // 已在录制，忽略重复触发
        val f = frame
        if (f == null) {
            // 还没有取景画面（尺寸未知）就不开录，给提示而不是静默失败。
            showHint(context.getString(R.string.remote_rec_start_failed), durationMs = 3000L)
            return
        }
        val w = f.image.width
        val h = f.image.height

        // 解析输出去向：传输目录已配置时在该 SAF 树下建档并打开 "rw" 描述符，
        // 目录被撤销/已满等任何失败都回退 filesDir——录不进用户目录也要能录。
        var sink: RecordingSink = RecordingSink.AppDir(recOutputDir)
        var createdDocUri: Uri? = null
        val dirUriStr = transferState.transferDirUri
        if (dirUriStr != null) {
            try {
                val treeUri = Uri.parse(dirUriStr)
                val parentUri = DocumentsContract.buildDocumentUriUsingTree(
                    treeUri, DocumentsContract.getTreeDocumentId(treeUri)
                )
                val name = ViewfinderRecorder.newFileName()
                val docUri = DocumentsContract.createDocument(
                    context.contentResolver, parentUri, "video/mp4", name
                )
                if (docUri != null) {
                    val pfd = context.contentResolver.openFileDescriptor(docUri, "rw")
                    if (pfd != null) {
                        // pfd 所有权自此归 recorder：start 失败或 stop 收尾都由它关闭。
                        sink = RecordingSink.Saf(pfd, name)
                        createdDocUri = docUri
                    } else {
                        runCatching {
                            DocumentsContract.deleteDocument(context.contentResolver, docUri)
                        }
                    }
                }
            } catch (e: Exception) {
                android.util.Log.w("RemoteScreen", "SAF 录像建档失败，回退应用私有目录", e)
            }
        }
        android.util.Log.d("RemoteScreen",
            "录像输出：${if (sink is RecordingSink.Saf) "SAF 传输目录" else "应用私有目录"}")

        val builtInMic = if (withAudio) {
            context.getSystemService(AudioManager::class.java)
                ?.getDevices(AudioManager.GET_DEVICES_INPUTS)
                ?.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC }
        } else {
            null
        }
        val recorder = ViewfinderRecorder(
            sink = sink,
            srcWidth = w,
            srcHeight = h,
            withAudio = withAudio,
            preferredAudioInput = builtInMic
        )
        if (!recorder.start()) {
            // 开录失败：SAF 模式下把刚建的空文档删掉，别在用户目录留 0 字节垃圾。
            createdDocUri?.let { uri ->
                runCatching { DocumentsContract.deleteDocument(context.contentResolver, uri) }
            }
            showHint(context.getString(R.string.remote_rec_start_failed), durationMs = 3000L)
            return
        }
        recSaveFeedbackJob?.cancel()
        recFinalizing = false
        recSaveSuccess = false
        viewfinderRecorder = recorder
        recPaused = false
        recElapsed = 0
        recJob = scope.launch(Dispatchers.Default) {
            var failStreak = 0
            // 帧驱动 VFR：同一帧只编一次（按对象身份判新），PTS 用帧的真实到达
            // 时刻——有线 ~70fps 全收，无线 ~20fps 不再重复编码同帧浪费码率。
            var lastEncoded: RemoteLiveFrame? = null
            while (isActive && recorder.isRecording) {
                val currentFrame = frame
                if (currentFrame != null && currentFrame !== lastEncoded && !recorder.isPaused) {
                    if (recorder.encodeFrame(
                            currentFrame.image,
                            currentFrame.receivedAtElapsedMs * 1_000_000L
                        )
                    ) {
                        lastEncoded = currentFrame
                        failStreak = 0
                    } else if (++failStreak >= 30) {
                        // 连续编码失败（典型：录制中切换 HD 监看导致帧尺寸变化，编码器
                        // 从此整段拒收）——自动停录保存已有片段，避免"看着在录、
                        // 实际一帧没写"的死录制。注意只有真正的编码失败会累计，
                        // "暂无新帧"的空转轮询不进这个计数。
                        withContext(Dispatchers.Main) { stopRecorder() }
                        break
                    }
                }
                delay(5)   // 轻量轮询等新帧；仅比较引用，代价可忽略
            }
        }
    }

    // 麦克风权限：拒绝不阻断录像，降级为无声并提示一次。
    val micPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (!granted) {
            showHint(context.getString(R.string.remote_rec_no_audio), durationMs = 3000L)
        }
        startRecorderResolved(withAudio = granted)
    }

    fun startRecorder() {
        // isPro 门控：免费版绝无可能进入录制路径（RecControlBar 已压暗 + 拦截点击，
        // 此处为防御纵深——任何跳过 UI 直调本函数的路径仍被拦截）。
        if (!isPro) {
            showHint(context.getString(R.string.remote_rec_pro_only))
            return
        }
        if (viewfinderRecorder != null) return   // 已在录制，忽略重复触发
        val granted = ContextCompat.checkSelfPermission(
            context, Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            startRecorderResolved(withAudio = true)
        } else {
            // 弹系统权限框，结果回调里无论允许与否都开录（拒绝则无声）。
            micPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    fun togglePauseRecorder() {
        val r = viewfinderRecorder ?: return
        if (r.isPaused) r.resume() else r.pause()
        recPaused = r.isPaused
    }

    // 录像计时：每秒 +1，暂停时停表；开始/停止时由 start/stopRecorder 归零。
    LaunchedEffect(viewfinderRecorder) {
        val r = viewfinderRecorder ?: return@LaunchedEffect
        while (r.isRecording) {
            delay(1000)
            if (r.isRecording && !r.isPaused) recElapsed++
        }
    }

    // 离开页面自动停录：不停会泄漏 MediaCodec/MediaMuxer，且 mp4 不收尾无法播放。
    // 此时 scope 已随组合取消，收尾放到普通线程做（muxer 收尾不能在主线程）。
    DisposableEffect(Unit) {
        onDispose {
            recJob?.cancel()
            val r = viewfinderRecorder
            viewfinderRecorder = null
            if (r != null) Thread { runCatching { r.stop() } }.start()
        }
    }

    // ---------- 布局 ----------
    Box(modifier = Modifier.fillMaxSize().background(rememberAppBackgroundBrush())) {
        AnimatedContent(
            targetState = rotation != 0,  // landscape when rotated
            transitionSpec = {
                (fadeIn(tween(durationMillis = 190, delayMillis = 50)) +
                    scaleIn(initialScale = 0.97f, animationSpec = tween(240)))
                    .togetherWith(
                        fadeOut(tween(130)) +
                            scaleOut(targetScale = 1.02f, animationSpec = tween(160))
                    )
            },
            contentAlignment = Alignment.Center,
            label = "remoteLayoutOrientation",
            modifier = Modifier.fillMaxSize()
        ) { landscape ->
        if (!landscape) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .systemBarsPadding()
                .padding(horizontal = 12.dp, vertical = 8.dp)
        ) {
            // 顶栏返回常驻；信号随其他工具淡变，监看工具统一放到取景器下方。
            Row(verticalAlignment = Alignment.CenterVertically) {
                AnimatedVisibility(
                    visible = !immersiveFullscreen,
                    enter = fadeIn(tween(260, easing = FastOutSlowInEasing)),
                    exit = fadeOut(tween(180, easing = FastOutSlowInEasing))
                ) {
                    SignalPill(
                        rssi = camState.wifiRssi,
                        connected = connected,
                        connectionType = camState.connectionType
                    )
                }
                Spacer(Modifier.weight(1f))
                GlassButton(
                    onClick = {
                        if (immersiveFullscreen) {
                            immersiveFullscreen = false
                        } else {
                            onNavigateBack()
                        }
                    },
                    shape = RoundedCornerShape(22.dp),
                    showSheen = false,
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
                    modifier = Modifier.height(36.dp)
                ) {
                    Icon(
                        Icons.Default.ArrowForward,
                        contentDescription = stringResource(
                            if (immersiveFullscreen) {
                                R.string.cd_remote_fullscreen_exit
                            } else {
                                R.string.cd_back
                            }
                        ),
                        tint = colors.onBackground, modifier = Modifier.size(18.dp)
                    )
                }
            }
            Spacer(Modifier.height(12.dp))

            RemoteViewfinderPanel(
                frameProvider = { frame },
                grid = framingGrid,
                showHistogram = showHistogram,
                modeText = modeText,
                focusModeText = focusModeText,
                recording = recording,
                recSeconds = recSeconds,
                afHeld = afHeld,
                afLocked = afLocked,
                afFocusPoint = focusAreaPoint,
                tapFocusFeedback = tapFocusFeedback,
                tapFocusPoint = tapFocusPoint,
                tapFocusNonce = tapFocusNonce,
                confirmedFocusMarker = confirmedFocusMarker,
                onTapFocus = { focusAt(it) },
                showFps = showFps,
                fps = fps,
                connected = connected,
                showZebra = showZebra,
                showLevel = showLevel,
                levelRoll = levelRoll,
                trialLeftSeconds = trialLeftSeconds,
                modifier = Modifier.fillMaxWidth().aspectRatio(viewfinderAspect)
            )
            Spacer(Modifier.height(8.dp))
            // Row 1: overlay tools (left) + screen actions (right)
            // Row 不会自动折行，窄屏上这排按钮会直接顶出屏幕外。这里做一次「量宽再
            // 分行」：右端永久留给【进全屏 / 转屏】两颗，监看工具从左往右填第一行，
            // 填不下的整颗挪到第二行左对齐（仍与取景器同一左边界）。
            // 按钮宽度不能靠查表估算——GlassButton 底层的 M3 Surface 会把可点击
            // 宽度撑到至少 48dp 的无障碍下限，HD/FPS 又是文字标（宽度随系统字体
            // 缩放变化），估宽在部分机型上必然偏小、把右端两颗挤出屏幕。下面改用
            // 自定义 Layout 拿每颗按钮的真实测量宽度分行，任何字号/密度下都精确装填。
            val toolGap = 6.dp
            val overlayTools: List<@Composable () -> Unit> = buildList {
                if (devUnlocked) {
                    add(@Composable {
                        TopIconToggle(
                            active = false,
                            contentDescription = stringResource(R.string.cd_dev_panel),
                            onClick = { devPanel = true }
                        ) {
                            Icon(
                                Icons.Default.BugReport,
                                contentDescription = null,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    })
                }
                add(@Composable {
                    TopIconToggle(
                        active = hdLiveView,
                        contentDescription = stringResource(R.string.dev_hd_liveview),
                        onClick = {
                            hdLiveView = !hdLiveView
                            startSession(hdLiveView)
                        }
                    ) { HdMark() }
                })
                add(@Composable {
                    TopIconToggle(
                        active = showFps,
                        contentDescription = stringResource(R.string.dev_fps_overlay),
                        onClick = { toggleFpsControl() }
                    ) { FpsMark() }
                })
                add(@Composable {
                    TopIconToggle(
                        active = showHistogram,
                        contentDescription = stringResource(R.string.cd_remote_histogram),
                        onClick = { showHistogram = !showHistogram }
                    ) { HistogramMark(Modifier.size(19.dp)) }
                })
                add(@Composable {
                    TopIconToggle(
                        active = framingGrid != ViewfinderGrid.OFF,
                        contentDescription = stringResource(R.string.cd_remote_grid),
                        onClick = { framingGrid = framingGrid.next() }
                    ) {
                        GridMark(Modifier.size(18.dp))
                    }
                })
                add(@Composable {
                    TopIconToggle(
                        active = showZebra,
                        contentDescription = stringResource(R.string.cd_remote_zebra),
                        onClick = { showZebra = !showZebra }
                    ) { ZebraMark(Modifier.size(18.dp)) }
                })
                add(@Composable {
                    TopIconToggle(
                        active = showLevel,
                        contentDescription = stringResource(R.string.cd_remote_level),
                        onClick = { showLevel = !showLevel }
                    ) { LevelMark(Modifier.size(18.dp)) }
                })
                add(@Composable {
                    RecControlBar(
                        isRecording = viewfinderRecorder != null,
                        isPaused = recPaused,
                        elapsedSeconds = recElapsed,
                        onStart = { startRecorder() },
                        onPauseResume = { togglePauseRecorder() },
                        onStop = { stopRecorder() },
                        modifier = Modifier.height(36.dp),
                        enabled = isPro,
                        isFinalizing = recFinalizing,
                        showDone = recSaveSuccess
                    )
                })
            }
            // 所有按钮按真实固有宽度顺序折行；窄屏/大字体下宁可增加一行，
            // 也绝不压窄按钮或让文字换行。
            val toolRowGap = 4.dp
            AdaptiveRemoteToolBar(
                modifier = Modifier.fillMaxWidth(),
                horizontalGap = toolGap,
                verticalGap = toolRowGap,
                pinnedEndCount = 2,
                content = {
                    overlayTools.forEach { tool -> tool() }
                    TopIconToggle(
                        active = false,
                        contentDescription = stringResource(R.string.cd_remote_fullscreen_enter),
                        onClick = { enterFullscreen() }
                    ) { FullscreenEnterMark(Modifier.size(17.dp)) }
                    TopIconToggle(
                        active = false,
                        contentDescription = stringResource(R.string.cd_remote_rotate),
                        onClick = onCycleRotation
                    ) { RotateMark(Modifier.size(20.dp)) }
                }
            )
            Spacer(Modifier.height(12.dp))

            // 2×2 数值拨轮微调：读数即控件——在数值上【上下拖动】，数值列随手指 1:1
            // 同向滚动、跨档步进、松手吸附最近档（iOS 拨轮手感，无惯性甩动）；
            // 点一下弹全表直跳。只读参数整块压暗 + 锁。第一排 曝光补偿/ISO，第二排 光圈/快门。
            // 拨杆在录像位时绑定录像侧独立参数组（照片/录像两套属性）。
            val activeProps = if (movieMode) MOVIE_EXPOSURE_PROPS else EXPOSURE_PROPS
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                activeProps.chunked(2).forEach { rowProps ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        rowProps.forEach { prop ->
                            val isoProp =
                                if (movieMode) Lab.PROP_NK_MOVIE_ISO else Lab.PROP_ISO
                            val hasAutoIso =
                                prop == isoProp && autoIsoAvailable
                            ParamTile(
                                label = paramLabel(prop),
                                param = params[prop],
                                autoIsoEnabled = if (hasAutoIso) autoIsoEnabled else null,
                                autoIsoValue = if (hasAutoIso) effectiveAutoIsoValue else null,
                                autoIsoBusy = hasAutoIso && autoIsoBusy,
                                onAutoIsoToggle = if (hasAutoIso) ::setAutoIso else null,
                                modifier = Modifier.weight(1f),
                                onStep = { delta -> stepParam(prop, delta) },
                                onOpenList = {
                                    if (params[prop]?.values?.isNotEmpty() == true) listProp = prop
                                }
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.weight(1f))

            // 快门键：悬在参数区与屏底之间留白的正中（上下 weight 等分），典型长屏上
            // 约落在屏高 3/4 的拇指自然落点——比贴屏底好按，也离刚调完的参数更近；
            // 固定 padding 保证小屏上下限间距。快按=直接拍摄/切换录制；长按=半按对焦再拍；
            // 拍摄中转圈=正在等相机确认拍好。（不再显示拍摄缩略图）
            Box(
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp, bottom = 10.dp),
                contentAlignment = Alignment.Center
            ) {
                ShutterButton(
                    capturing = capturing,
                    focusing = afHeld,
                    enabled = connected && !probing,
                    movie = movieMode,
                    recording = recording,
                    onFocusStart = { startFocus() },
                    onRelease = ::finishShutterGesture,
                    onQuickTap = {
                        if (movieMode) toggleRecord() else shoot()
                    }
                )
            }
            Spacer(Modifier.weight(1f))
        }
        } else {
            BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
                val normalHorizontalPadding = 10.dp
                val normalVerticalPadding = 8.dp
                val controlsGap = 8.dp
                val parameterPanelWidth = 170.dp
                val fallbackToolBarHeight = 40.dp
                val toolRowGap = 4.dp
                val fullscreenVerticalBreathingRoom = 4.dp
                val density = LocalDensity.current
                var landscapeToolBarHeightPx by remember { mutableIntStateOf(0) }
                val landscapeToolBarHeight = if (landscapeToolBarHeightPx > 0) {
                    with(density) { landscapeToolBarHeightPx.toDp() }
                } else {
                    fallbackToolBarHeight
                }

                fun fitWithin(
                    availableWidth: androidx.compose.ui.unit.Dp,
                    availableHeight: androidx.compose.ui.unit.Dp
                ): Pair<androidx.compose.ui.unit.Dp, androidx.compose.ui.unit.Dp> {
                    val width = availableWidth.coerceAtLeast(0.dp)
                    val height = availableHeight.coerceAtLeast(0.dp)
                    if (width == 0.dp || height == 0.dp) return 0.dp to 0.dp
                    val heightAtFullWidth = width / viewfinderAspect
                    return if (heightAtFullWidth <= height) {
                        width to heightAtFullWidth
                    } else {
                        (height * viewfinderAspect) to height
                    }
                }

                // 常规横屏中，取景器位于左栏、工具行上方；全屏时用同一个实例扩展到整个
                // 安全区域。外层 RemoteScreen 已把状态栏、导航栏和挖孔映射成左右 inset，
                // 所以这里的 maxWidth/maxHeight 正是可以安全使用的最大画布。
                val normalLeftWidth = (
                    maxWidth -
                        normalHorizontalPadding * 2 -
                        parameterPanelWidth -
                        controlsGap
                    ).coerceAtLeast(0.dp)
                val normalViewfinderHeight = (
                    maxHeight -
                        normalVerticalPadding * 2 -
                        landscapeToolBarHeight -
                        toolRowGap
                    ).coerceAtLeast(0.dp)
                val (normalImageWidth, normalImageHeight) =
                    fitWithin(normalLeftWidth, normalViewfinderHeight)
                val normalImageX =
                    normalHorizontalPadding + (normalLeftWidth - normalImageWidth) / 2
                val normalImageY =
                    normalVerticalPadding + (normalViewfinderHeight - normalImageHeight) / 2

                val fullscreenAvailableHeight =
                    (maxHeight - fullscreenVerticalBreathingRoom * 2).coerceAtLeast(0.dp)
                val (fullscreenImageWidth, fullscreenImageHeight) =
                    fitWithin(maxWidth, fullscreenAvailableHeight)
                val targetImageX = if (immersiveFullscreen) 0.dp else normalImageX
                val targetImageY = if (immersiveFullscreen) {
                    fullscreenVerticalBreathingRoom +
                        (fullscreenAvailableHeight - fullscreenImageHeight) / 2
                } else {
                    normalImageY
                }
                val targetImageWidth =
                    if (immersiveFullscreen) fullscreenImageWidth else normalImageWidth
                val targetImageHeight =
                    if (immersiveFullscreen) fullscreenImageHeight else normalImageHeight
                val boundsDuration = if (immersiveFullscreen) 360 else 300
                val imageX by animateDpAsState(
                    targetValue = targetImageX,
                    animationSpec = tween(boundsDuration, easing = FastOutSlowInEasing),
                    label = "fullscreenViewfinderX"
                )
                val imageY by animateDpAsState(
                    targetValue = targetImageY,
                    animationSpec = tween(boundsDuration, easing = FastOutSlowInEasing),
                    label = "fullscreenViewfinderY"
                )
                val imageWidth by animateDpAsState(
                    targetValue = targetImageWidth,
                    animationSpec = tween(boundsDuration, easing = FastOutSlowInEasing),
                    label = "fullscreenViewfinderWidth"
                )
                val imageHeight by animateDpAsState(
                    targetValue = targetImageHeight,
                    animationSpec = tween(boundsDuration, easing = FastOutSlowInEasing),
                    label = "fullscreenViewfinderHeight"
                )

                RemoteViewfinderPanel(
                    frameProvider = { frame },
                    grid = framingGrid,
                    showHistogram = showHistogram,
                    modeText = modeText,
                    focusModeText = focusModeText,
                    recording = recording,
                    recSeconds = recSeconds,
                    afHeld = afHeld,
                    afLocked = afLocked,
                    afFocusPoint = focusAreaPoint,
                    tapFocusFeedback = tapFocusFeedback,
                    tapFocusPoint = tapFocusPoint,
                    tapFocusNonce = tapFocusNonce,
                    confirmedFocusMarker = confirmedFocusMarker,
                    onTapFocus = { focusAt(it) },
                    showFps = showFps,
                    fps = fps,
                    connected = connected,
                    showZebra = showZebra,
                    showLevel = showLevel,
                    levelRoll = levelRoll,
                    trialLeftSeconds = trialLeftSeconds,
                    modifier = Modifier
                        .offset(x = imageX, y = imageY)
                        .size(width = imageWidth, height = imageHeight)
                )

                // 操作区独立淡出/淡入，取景器尺寸动画不会重建或交叉切换帧画面。
                AnimatedVisibility(
                    visible = !immersiveFullscreen,
                    enter = fadeIn(
                        animationSpec = tween(
                            durationMillis = 260,
                            delayMillis = 70,
                            easing = FastOutSlowInEasing
                        )
                    ),
                    exit = fadeOut(
                        animationSpec = tween(
                            durationMillis = 180,
                            easing = FastOutSlowInEasing
                        )
                    ),
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(
                            horizontal = normalHorizontalPadding,
                            vertical = normalVerticalPadding
                        )
                ) {
                    Row(
                        modifier = Modifier.fillMaxSize(),
                        horizontalArrangement = Arrangement.spacedBy(controlsGap)
                    ) {
                        Column(modifier = Modifier.weight(1f).fillMaxHeight()) {
                            Spacer(Modifier.weight(1f))
                            Spacer(Modifier.height(toolRowGap))
                            AdaptiveRemoteToolBar(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .onSizeChanged {
                                        if (landscapeToolBarHeightPx != it.height) {
                                            landscapeToolBarHeightPx = it.height
                                        }
                                },
                                horizontalGap = 5.dp,
                                verticalGap = 4.dp,
                                pinnedEndCount = 2
                            ) {
                                if (devUnlocked) {
                                    TopIconToggle(
                                        active = false,
                                        contentDescription = stringResource(R.string.cd_dev_panel),
                                        onClick = { devPanel = true }
                                    ) {
                                        Icon(
                                            Icons.Default.BugReport,
                                            contentDescription = null,
                                            modifier = Modifier.size(18.dp)
                                        )
                                    }
                                }
                                TopIconToggle(
                                    active = hdLiveView,
                                    contentDescription = stringResource(R.string.dev_hd_liveview),
                                    onClick = {
                                        hdLiveView = !hdLiveView
                                        startSession(hdLiveView)
                                    }
                                ) { HdMark() }
                                TopIconToggle(
                                    active = showFps,
                                    contentDescription = stringResource(R.string.dev_fps_overlay),
                                    onClick = { toggleFpsControl() }
                                ) { FpsMark() }
                                TopIconToggle(
                                    active = showHistogram,
                                    contentDescription = stringResource(R.string.cd_remote_histogram),
                                    onClick = { showHistogram = !showHistogram }
                                ) { HistogramMark(Modifier.size(19.dp)) }
                                TopIconToggle(
                                    active = framingGrid != ViewfinderGrid.OFF,
                                    contentDescription = stringResource(R.string.cd_remote_grid),
                                    onClick = { framingGrid = framingGrid.next() }
                                ) { GridMark(Modifier.size(18.dp)) }
                                TopIconToggle(
                                    active = showZebra,
                                    contentDescription = stringResource(R.string.cd_remote_zebra),
                                    onClick = { showZebra = !showZebra }
                                ) { ZebraMark(Modifier.size(18.dp)) }
                                TopIconToggle(
                                    active = showLevel,
                                    contentDescription = stringResource(R.string.cd_remote_level),
                                    onClick = { showLevel = !showLevel }
                                ) { LevelMark(Modifier.size(18.dp)) }
                                RecControlBar(
                                    isRecording = viewfinderRecorder != null,
                                    isPaused = recPaused,
                                    elapsedSeconds = recElapsed,
                                    onStart = { startRecorder() },
                                    onPauseResume = { togglePauseRecorder() },
                                    onStop = { stopRecorder() },
                                    modifier = Modifier.height(36.dp),
                                    enabled = isPro,
                                    isFinalizing = recFinalizing,
                                    showDone = recSaveSuccess
                                )
                                TopIconToggle(
                                    active = false,
                                    contentDescription =
                                        stringResource(R.string.cd_remote_fullscreen_enter),
                                    onClick = { enterFullscreen() }
                                ) { FullscreenEnterMark(Modifier.size(17.dp)) }
                                TopIconToggle(
                                    active = false,
                                    contentDescription = stringResource(R.string.cd_remote_rotate),
                                    onClick = onCycleRotation
                                ) { RotateMark(Modifier.size(20.dp)) }
                            }
                        }

                        Column(
                            modifier = Modifier
                                .width(parameterPanelWidth)
                                .fillMaxHeight(),
                            verticalArrangement = Arrangement.Center
                        ) {
                            val activeProps =
                                if (movieMode) MOVIE_EXPOSURE_PROPS else EXPOSURE_PROPS
                            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                activeProps.chunked(2).forEach { rowProps ->
                                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        rowProps.forEach { prop ->
                                            val isoProp =
                                                if (movieMode) {
                                                    Lab.PROP_NK_MOVIE_ISO
                                                } else {
                                                    Lab.PROP_ISO
                                                }
                                            val hasAutoIso =
                                                prop == isoProp && autoIsoAvailable
                                            ParamTile(
                                                label = paramLabel(prop),
                                                param = params[prop],
                                                autoIsoEnabled =
                                                    if (hasAutoIso) autoIsoEnabled else null,
                                                autoIsoValue =
                                                    if (hasAutoIso) effectiveAutoIsoValue else null,
                                                autoIsoBusy = hasAutoIso && autoIsoBusy,
                                                onAutoIsoToggle =
                                                    if (hasAutoIso) ::setAutoIso else null,
                                                modifier = Modifier.weight(1f),
                                                onStep = { delta -> stepParam(prop, delta) },
                                                onOpenList = {
                                                    if (
                                                        params[prop]?.values?.isNotEmpty() == true
                                                    ) {
                                                        listProp = prop
                                                    }
                                                }
                                            )
                                        }
                                    }
                                }
                            }
                            Spacer(Modifier.height(18.dp))
                            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                                ShutterButton(
                                    capturing = capturing,
                                    focusing = afHeld,
                                    enabled = connected && !probing,
                                    movie = movieMode,
                                    recording = recording,
                                    onFocusStart = { startFocus() },
                                    onRelease = ::finishShutterGesture,
                                    onQuickTap = {
                                        if (movieMode) toggleRecord() else shoot()
                                    }
                                )
                            }
                        }
                    }
                }

                // 返回始终固定在右上角；信号随工具区淡变，全屏时返回只恢复常规横屏布局。
                Row(
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(
                            horizontal = normalHorizontalPadding,
                            vertical = normalVerticalPadding
                        ),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    AnimatedVisibility(
                        visible = !immersiveFullscreen,
                        enter = fadeIn(tween(260, easing = FastOutSlowInEasing)),
                        exit = fadeOut(tween(180, easing = FastOutSlowInEasing))
                    ) {
                        SignalPill(
                            rssi = camState.wifiRssi,
                            connected = connected,
                            connectionType = camState.connectionType
                        )
                    }
                    GlassButton(
                        onClick = {
                            if (immersiveFullscreen) {
                                immersiveFullscreen = false
                            } else {
                                onNavigateBack()
                            }
                        },
                        shape = RoundedCornerShape(22.dp),
                        showSheen = false,
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
                        modifier = Modifier.height(36.dp)
                    ) {
                        Icon(
                            Icons.Default.ArrowForward,
                            contentDescription = stringResource(
                                if (immersiveFullscreen) {
                                    R.string.cd_remote_fullscreen_exit
                                } else {
                                    R.string.cd_back
                                }
                            ),
                            tint = colors.onBackground,
                            modifier = Modifier.size(18.dp)
                        )
                    }
                }
            }
        }
        }

        // 顶部提示条：视觉与照片列表页的底部玻璃提示条同款（22dp 玻璃 Surface + 投影 +
        // labelLarge）；位置留在顶部——本页底部是快门键，提示不能压它。
        AnimatedVisibility(
            visible = hintVisible && !immersiveFullscreen,
            enter = fadeIn(tween(200)) + slideInVertically(tween(200)) { -it / 2 },
            exit = fadeOut(tween(300)),
            modifier = Modifier
                .align(Alignment.TopCenter)
                .statusBarsPadding()
                .padding(top = 60.dp)
        ) {
            Surface(
                shape = RoundedCornerShape(22.dp),
                color = colors.glassSurfaceHeavy,
                shadowElevation = 6.dp,
                border = BorderStroke(1.dp, colors.glassPanelBorder)
            ) {
                Text(
                    hintText,
                    style = MaterialTheme.typography.labelLarge,
                    color = colors.onBackground,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp)
                )
            }
        }

        // 完整值表（点胶囊中间值弹出）：呼出=缩放淡入、消失=淡出（item 9 动画）。
        // 用 lastListProp 记住最后一次的参数，让消失动画期间仍有数据可渲染。
        var lastListProp by remember { mutableStateOf<Int?>(null) }
        LaunchedEffect(listProp) { if (listProp != null) lastListProp = listProp }
        // 遮罩：淡入淡出（180/140，与面板本体及全局筛选面板同节奏）
        AnimatedVisibility(
            visible = listProp != null,
            enter = fadeIn(tween(180)),
            exit = fadeOut(tween(140)),
            modifier = Modifier.fillMaxSize()
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(colors.scrim)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null
                    ) { listProp = null }
            )
        }
        // 面板：缩放+淡入呼出、缩放+淡出消失
        AnimatedVisibility(
            visible = listProp != null,
            enter = fadeIn(tween(180)) + scaleIn(initialScale = 0.88f, animationSpec = tween(180)),
            exit = fadeOut(tween(140)) + scaleOut(targetScale = 0.9f, animationSpec = tween(140)),
            modifier = Modifier.fillMaxSize()
        ) {
            val prop = lastListProp
            val listParam = prop?.let { params[it] }
            if (prop != null && listParam != null) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    val valueListState = rememberLazyListState()
                    LaunchedEffect(prop) {
                        val idx = listParam.values.indexOf(listParam.current)
                        if (idx > 3) valueListState.scrollToItem(idx - 3)
                    }
                    // 面板走全局玻璃面板惯用法（Surface + 细描边 + 投影，同类型筛选面板）；
                    // 当前值行用全局选中语言：高亮底 + 蓝色加粗（同 FilterRow）。
                    Surface(
                        shape = RoundedCornerShape(16.dp),
                        color = colors.glassSurfaceHeavy,
                        border = BorderStroke(1.dp, colors.glassPanelBorder),
                        shadowElevation = 6.dp,
                        modifier = Modifier.width(190.dp)
                    ) {
                        LazyColumn(
                            state = valueListState,
                            modifier = Modifier
                                .heightIn(max = 340.dp)
                                .padding(horizontal = 6.dp, vertical = 6.dp)
                        ) {
                            items(listParam.values) { v ->
                                val isCurrent = v == listParam.current
                                Text(
                                    rcFormat(prop, v),
                                    color = if (isCurrent) colors.accentBlue else colors.onBackground,
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = 15.sp,
                                    fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                                    textAlign = TextAlign.Center,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clip(RoundedCornerShape(9.dp))
                                        .background(
                                            if (isCurrent) colors.accentBlue.copy(alpha = 0.18f)
                                            else Color.Transparent
                                        )
                                        .clickable {
                                            sendValue(prop, v, immediate = true)
                                            listProp = null
                                        }
                                        .padding(vertical = 10.dp)
                                )
                            }
                        }
                    }
                }
            }
        }

        // 开发者面板遮罩：淡入淡出，与面板本体同节奏（全局 overlay 规格）
        AnimatedVisibility(
            visible = devPanel,
            enter = fadeIn(Motion.overlayExpand),
            exit = fadeOut(Motion.overlayCollapse),
            modifier = Modifier.fillMaxSize()
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(colors.scrim)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null
                    ) { devPanel = false }
            )
        }
        AnimatedVisibility(
            visible = devPanel,
            // 底部面板出入场走全局 overlay 节奏（与设置面板一致）
            enter = slideInVertically(Motion.sheetSlideIn) { it } + fadeIn(Motion.overlayExpand),
            exit = slideOutVertically(Motion.sheetSlideOut) { it } + fadeOut(Motion.overlayCollapse),
            modifier = Modifier.align(Alignment.BottomCenter)
        ) {
            // 底板走全局面板惯用法：Surface + 细描边 + 投影 + 顶部 sheen 高光
            //（与设置面板同款），顶角 20dp 同设置面板。
            Surface(
                shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
                color = colors.glassSurfaceHeavy,
                border = BorderStroke(1.dp, colors.glassPanelBorder),
                shadowElevation = 6.dp,
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier
                        .background(
                            Brush.verticalGradient(listOf(colors.glassSheen, Color.Transparent))
                        )
                        .navigationBarsPadding()
                        .padding(14.dp)
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            stringResource(R.string.dev_panel_title),
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.SemiBold,
                            color = colors.onBackground
                        )
                        Spacer(Modifier.weight(1f))
                        GlassButton(
                            onClick = {
                                clipboard.setText(AnnotatedString(logLines.joinToString("\n")))
                            },
                            contentPadding = PaddingValues(8.dp)
                        ) {
                            Icon(
                                Icons.Default.ContentCopy,
                                contentDescription = stringResource(R.string.lab_copy_log),
                                tint = colors.onSurfaceVariant, modifier = Modifier.size(14.dp)
                            )
                        }
                        Spacer(Modifier.width(8.dp))
                        GlassButton(
                            onClick = { devPanel = false },
                            contentPadding = PaddingValues(8.dp)
                        ) {
                            Icon(
                                Icons.Default.Close,
                                contentDescription = stringResource(R.string.cd_close),
                                tint = colors.onSurfaceVariant, modifier = Modifier.size(14.dp)
                            )
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    // HD / FPS 开关已移到顶栏；此处只保留探测与日志。
                    GlassButton(onClick = ::runProbe, enabled = connected && !probing) {
                        Text(
                            stringResource(R.string.lab_run_probe),
                            style = MaterialTheme.typography.labelMedium,
                            color = colors.onBackground
                        )
                    }
                    Spacer(Modifier.height(8.dp))
                    // 日志跟尾：面板刚打开（尚无布局信息）直接跳到底；此后新行到来时，
                    // 停在底部附近才跟到底，用户上翻查看时不打扰。
                    val logState = rememberLazyListState()
                    LaunchedEffect(logLines.size) {
                        if (logLines.isEmpty()) return@LaunchedEffect
                        val lastVisible =
                            logState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1
                        if (lastVisible == -1 || lastVisible >= logLines.size - 3) {
                            logState.scrollToItem(logLines.size - 1)
                        }
                    }
                    LazyColumn(
                        state = logState,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(170.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(Color.Black.copy(alpha = 0.35f))
                            .padding(horizontal = 8.dp, vertical = 6.dp)
                    ) {
                        items(logLines) { line ->
                            Text(
                                line,
                                fontFamily = FontFamily.Monospace,
                                fontSize = 10.sp,
                                lineHeight = 14.sp,
                                color = if (line.startsWith("!!")) colors.accentOrange
                                else Color.White.copy(alpha = 0.76f)
                            )
                        }
                    }
                }
            }
            }
        }
    }

@Composable
private fun ViewfinderStatusBadge(text: String, weight: FontWeight) {
    Text(
        text = text,
        color = Color.White,
        fontSize = 11.sp,
        fontWeight = weight,
        modifier = Modifier
            .background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(8.dp))
            .padding(horizontal = 7.dp, vertical = 2.dp)
    )
}

/** 包含模式徽标、录制/FPS/对焦反馈的完整取景器；帧更新仍只落在其内部。 */
@Composable
private fun RemoteViewfinderPanel(
    frameProvider: () -> RemoteLiveFrame?,
    grid: ViewfinderGrid,
    showHistogram: Boolean,
    modeText: String?,
    focusModeText: String?,
    recording: Boolean,
    recSeconds: Int,
    afHeld: Boolean,
    afLocked: Boolean,
    afFocusPoint: Offset,
    tapFocusFeedback: TapFocusFeedback,
    tapFocusPoint: Offset,
    tapFocusNonce: Int,
    confirmedFocusMarker: ConfirmedFocusMarker?,
    onTapFocus: (ViewfinderTap) -> Unit,
    showFps: Boolean,
    fps: Float,
    connected: Boolean,
    showZebra: Boolean = false,
    showLevel: Boolean = false,
    /** 相机机身滚转角；null=没有可用角度，水平仪什么都不画。 */
    levelRoll: Float? = null,
    trialLeftSeconds: Int? = null,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF0D0D0D))
    ) {
        ViewfinderImage(
            frameProvider = frameProvider,
            grid = grid,
            showHistogram = showHistogram,
            tapFocusFeedback = tapFocusFeedback,
            tapFocusPoint = tapFocusPoint,
            tapFocusNonce = tapFocusNonce,
            afHeld = afHeld,
            afLocked = afLocked,
            afFocusPoint = afFocusPoint,
            confirmedFocusMarker = confirmedFocusMarker,
            onTapFocus = onTapFocus,
            showZebra = showZebra
        )

        if (showLevel) {
            ViewfinderLevelOverlay(rollDegrees = levelRoll, modifier = Modifier.matchParentSize())
        }

        if (trialLeftSeconds != null) {
            val sec = trialLeftSeconds
            Box(
                modifier = Modifier.align(Alignment.BottomStart).padding(8.dp)
                    .background(colors.glassSurfaceHeavy, RoundedCornerShape(7.dp))
                    .border(1.dp, colors.glassPanelBorder, RoundedCornerShape(7.dp))
                    .padding(horizontal = 7.dp, vertical = 2.dp)
            ) {
                Text(
                    stringResource(R.string.remote_trial_left, "%d:%02d".format(sec / 60, sec % 60)),
                    style = MaterialTheme.typography.labelSmall,
                    color = colors.onSurfaceVariant,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 10.sp
                )
            }
        }

        if (modeText != null || focusModeText != null) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(8.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                modeText?.let {
                    ViewfinderStatusBadge(it, FontWeight.Bold)
                }
                focusModeText?.let {
                    ViewfinderStatusBadge(it, FontWeight.SemiBold)
                }
            }
        }

        if (recording) {
            val recPulse = rememberInfiniteTransition(label = "recPulse")
            val dotAlpha by recPulse.animateFloat(
                initialValue = 1f,
                targetValue = 0.3f,
                animationSpec = infiniteRepeatable(tween(600), RepeatMode.Reverse),
                label = "recDot"
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(8.dp)
                    .background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(8.dp))
                    .padding(horizontal = 7.dp, vertical = 2.dp)
            ) {
                Box(
                    Modifier
                        .size(7.dp)
                        .graphicsLayer { alpha = dotAlpha }
                        .background(colors.statusError, CircleShape)
                )
                Spacer(Modifier.width(5.dp))
                Text(
                    "%d:%02d".format(recSeconds / 60, recSeconds % 60),
                    color = Color.White,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    fontFamily = FontFamily.Monospace
                )
            }
        }

        if (showFps && fps > 0f) {
            Text(
                "%.1f fps".format(fps),
                color = Color.White,
                fontSize = 10.sp,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(8.dp)
                    .background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(8.dp))
                    .padding(horizontal = 6.dp, vertical = 2.dp)
            )
        }
        if (!connected) {
            Text(
                stringResource(R.string.camera_not_connected),
                // 固定深色的取景器遮罩内始终使用亮字，不跟随页面浅色主题变暗。
                color = Color.White.copy(alpha = 0.78f),
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier
                    .align(Alignment.Center)
                    .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(8.dp))
                    .padding(horizontal = 12.dp, vertical = 6.dp)
            )
        }
    }
}

/**
 * 监看画面本体。[frameProvider] 延迟到此处才读 frame state——换帧重组被限制在
 * 这个小组件内，页面其余部分（tile/快门/顶栏）不随帧率重跑。
 */
@Composable
private fun ViewfinderImage(
    frameProvider: () -> RemoteLiveFrame?,
    grid: ViewfinderGrid,
    showHistogram: Boolean,
    tapFocusFeedback: TapFocusFeedback,
    tapFocusPoint: Offset,
    tapFocusNonce: Int,
    afHeld: Boolean,
    afLocked: Boolean,
    afFocusPoint: Offset,
    confirmedFocusMarker: ConfirmedFocusMarker?,
    onTapFocus: (ViewfinderTap) -> Unit,
    showZebra: Boolean
) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val liveFrame = frameProvider()
        if (liveFrame != null) {
            val imageWidth = liveFrame.image.width
            val imageHeight = liveFrame.image.height
            // ChangeAfArea 的坐标基准由增强帧头 +28/+30 声明，未必等于当前
            // 解码 JPEG 尺寸（例如低清监看仍可能沿用 XGA AF 网格）。
            val focusCoordinateWidth =
                liveFrame.metadata?.focusCoordinateWidth ?: imageWidth
            val focusCoordinateHeight =
                liveFrame.metadata?.focusCoordinateHeight ?: imageHeight
            val currentTapHandler by rememberUpdatedState(onTapFocus)
            Box(
                Modifier
                    .matchParentSize()
                    .pointerInput(
                        imageWidth,
                        imageHeight,
                        focusCoordinateWidth,
                        focusCoordinateHeight
                    ) {
                        detectTapGestures { tap ->
                            val imageRect = fitCenterRect(
                                size.width.toFloat(),
                                size.height.toFloat(),
                                imageWidth.toFloat() / imageHeight
                            )
                            if (tap.x in imageRect.left..imageRect.right &&
                                tap.y in imageRect.top..imageRect.bottom
                            ) {
                                val normalizedX =
                                    ((tap.x - imageRect.left) / imageRect.width).coerceIn(0f, 1f)
                                val normalizedY =
                                    ((tap.y - imageRect.top) / imageRect.height).coerceIn(0f, 1f)
                                currentTapHandler(
                                    ViewfinderTap(
                                        focusX = (
                                            normalizedX * (focusCoordinateWidth - 1)
                                            ).roundToInt(),
                                        focusY = (
                                            normalizedY * (focusCoordinateHeight - 1)
                                            ).roundToInt(),
                                        focusCoordinateWidth = focusCoordinateWidth,
                                        focusCoordinateHeight = focusCoordinateHeight,
                                        normalized = Offset(normalizedX, normalizedY)
                                    )
                                )
                            }
                        }
                    }
            ) {
                Image(
                    bitmap = liveFrame.image,
                    contentDescription = null,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize()
                )
            }
            // 暗角：四周极淡压暗，画面"坐进"边框（相机目镜语言），角标叠其上不受影响。
            // 半径必须取【半对角线】——默认的"短边一半"在 3:2 宽幅上圆罩不住左右两侧，
            // 半径之外会被涂成均匀实色（两条黑带而非渐晕）。drawWithCache 只在尺寸
            // 变化时重建 Brush，不随帧率重建。
            Box(
                Modifier
                    .matchParentSize()
                    .drawWithCache {
                        val brush = Brush.radialGradient(
                            0.72f to Color.Transparent,
                            1f to Color.Black.copy(alpha = 0.30f),
                            center = size.center,
                            radius = hypot(size.width, size.height) / 2f
                        )
                        onDrawBehind { drawRect(brush) }
                    }
            )
            FramingGridOverlay(
                grid = grid,
                imageAspectRatio = liveFrame.image.width.toFloat() / liveFrame.image.height,
                modifier = Modifier.matchParentSize()
            )
            // 斑马纹跟随帧上的掩码走：掩码在解码线程按节流计算，这里只做裁剪绘制。
            if (showZebra) {
                ViewfinderZebraOverlay(
                    mask = liveFrame.zebraMask,
                    imageAspectRatio = imageWidth.toFloat() / imageHeight,
                    modifier = Modifier.matchParentSize()
                )
            }
            if (tapFocusFeedback != TapFocusFeedback.IDLE) {
                TapFocusReticleOverlay(
                    feedback = tapFocusFeedback,
                    point = tapFocusPoint,
                    nonce = tapFocusNonce,
                    imageAspectRatio = imageWidth.toFloat() / imageHeight,
                    modifier = Modifier.matchParentSize()
                )
            } else if (afHeld) {
                TapFocusReticleOverlay(
                    feedback = if (afLocked) {
                        TapFocusFeedback.LOCKED
                    } else {
                        TapFocusFeedback.FOCUSING
                    },
                    point = afFocusPoint,
                    nonce = tapFocusNonce,
                    imageAspectRatio = imageWidth.toFloat() / imageHeight,
                    modifier = Modifier.matchParentSize()
                )
            } else if (confirmedFocusMarker != null) {
                val cameraFrame = liveFrame.metadata
                    ?.takeIf {
                        liveFrame.receivedAtElapsedMs >=
                            confirmedFocusMarker.confirmedAtElapsedMs &&
                            it.focusJudgement == LiveViewFocusJudgement.FOCUSED
                    }
                    ?.selectedFocusFrame
                ConfirmedFocusReticleOverlay(
                    fallbackPoint = confirmedFocusMarker.fallbackPoint,
                    cameraFrame = cameraFrame,
                    nonce = confirmedFocusMarker.confirmedAtElapsedMs,
                    imageAspectRatio = imageWidth.toFloat() / imageHeight,
                    modifier = Modifier.matchParentSize()
                )
            }
            if (showHistogram) {
                liveFrame.histogram?.let {
                    HistogramOverlay(
                        histogram = it,
                        modifier = Modifier.align(Alignment.BottomStart).padding(8.dp)
                    )
                }
            }
        } else {
            Icon(
                Icons.Default.Videocam, contentDescription = null,
                tint = Color.White.copy(alpha = 0.18f),
                modifier = Modifier.size(44.dp)
            )
        }
    }
}

// 参数拨轮行高：一行 = 一档，滚轮内容与手指位移 1:1（iOS 拨轮式跟手），
// 拖动灵敏度即由行高决定。18dp/档：相机 1/3 挡一步,一整挡(3 步)≈54dp,
// 跟手又能精确单步(> 触摸 slop);大跨度不靠拖,点数值弹全表直跳。太钝调小、太跳调大。
private val PARAM_WHEEL_ROW_DP = 18.dp

/** 参数在 tile 左上角的短标（相机通用符号，不进 i18n）。 */
private fun paramLabel(prop: Int): String = when (prop) {
    Lab.PROP_NK_SHUTTER, Lab.PROP_NK_MOVIE_SHUTTER -> "S"
    Lab.PROP_F_NUMBER, Lab.PROP_NK_MOVIE_F_NUMBER -> "f"
    Lab.PROP_ISO, Lab.PROP_NK_MOVIE_ISO -> "ISO"
    Lab.PROP_EXP_COMPENSATION, Lab.PROP_NK_MOVIE_EXP_COMP -> "EV"
    else -> ""
}

/**
 * 参数的"物理量"度量：数值越大 = 向下拖趋近的方向（用户定义的向下语义）。
 * 快门→速度(分母/分子,越快越大)、光圈→开口(用 -f,f 越小开口越大)、ISO→感光度、EV→补偿值。
 */
private fun paramMetric(prop: Int, raw: Long): Double = when (prop) {
    Lab.PROP_NK_SHUTTER, Lab.PROP_NK_MOVIE_SHUTTER -> when (raw) {
        0xFFFFFFFFL, 0xFFFFFFFEL, 0xFFFFFFFDL -> 0.0   // Bulb/x200/Time：当作极慢
        else -> {
            val num = ((raw ushr 16) and 0xFFFFL).toDouble()
            val den = (raw and 0xFFFFL).toDouble()
            if (num > 0) den / num else 0.0
        }
    }
    Lab.PROP_F_NUMBER, Lab.PROP_NK_MOVIE_F_NUMBER -> -raw.toDouble()   // f 越小开口越大
    Lab.PROP_ISO, Lab.PROP_NK_ISO_EX, Lab.PROP_NK_MOVIE_ISO -> raw.toDouble()  // ISO 越大越高
    Lab.PROP_EXP_COMPENSATION, Lab.PROP_NK_MOVIE_EXP_COMP -> raw.toDouble()    // EV（已带符号）
    else -> raw.toDouble()
}

/**
 * 向下拖对应的 enum 步进方向（+1 / -1）：使"向下拖 = 增大物理量"。
 * 通过比较枚举首尾值的度量得到，与枚举本身升/降序无关（换机型也稳）。
 */
private fun downStepSign(param: RcParam): Int {
    val vals = param.values
    if (vals.size < 2) return -1
    return if (paramMetric(param.prop, vals.last()) > paramMetric(param.prop, vals.first())) 1 else -1
}

/**
 * 当前值的锚点索引：优先精确命中；不在枚举里（非标准档位/值域刚随模式变化）时按
 * 物理量取最近档。拨轮定位与 stepParam 的步进起点共用，保证两者永不打架。
 * 仅在 [values] 为空时返回 -1。
 */
private fun paramAnchorIdx(prop: Int, values: List<Long>, current: Long): Int {
    val i = values.indexOf(current)
    if (i >= 0) return i
    val m = paramMetric(prop, current)
    return values.indices.minByOrNull { abs(paramMetric(prop, values[it]) - m) } ?: -1
}

/**
 * 参数微调 tile：iOS 拨轮式交互——数值列随手指 1:1 同向连续滚动（可停在档间），
 * 每跨过一档触感反馈（走 onStep→sendValue→haptics），松手平滑吸附最近档位，
 * 端点橡皮筋阻尼。无惯性甩动（有意为之：拖动只管微调，大跨度靠点数值弹全表直跳）。
 * 点一下打开完整值表。只读参数整块压暗 + 锁，拖动禁用。
 * 方向按物理量：向下拖 = 增大物理量（快门更快 / 光圈开口更大 / ISO 更高 / EV 更正），
 * 具体 enum 步进方向由 [downStepSign] 判定（不依赖枚举升/降序）。跟手滚动决定了
 * 向下拖趋近的档位显示在【上】缘、随手指落入中心（内容与手指同向，苹果拨轮语义）。
 */
@Composable
private fun ParamTile(
    label: String,
    param: RcParam?,
    autoIsoEnabled: Boolean?,
    autoIsoValue: Long?,
    autoIsoBusy: Boolean,
    onAutoIsoToggle: ((Boolean) -> Unit)?,
    modifier: Modifier = Modifier,
    onStep: (Int) -> Unit,
    onOpenList: () -> Unit
) {
    val colors = AppTheme.colors
    val density = LocalDensity.current
    val hasAutoIsoControl = autoIsoEnabled != null && onAutoIsoToggle != null
    val valueWritable = param != null && param.values.isNotEmpty() && param.writable
    val autoIsoOn = autoIsoEnabled == true
    val writable = valueWritable && !autoIsoOn
    var dragging by remember { mutableStateOf(false) }
    val rowPx = with(density) { PARAM_WHEEL_ROW_DP.toPx() }
    val scope = rememberCoroutineScope()

    // 向下拖对应的 enum 步进方向（向下=增大物理量）。
    val downSign = if (writable && param != null) downStepSign(param) else -1

    // 当前值的锚点索引（精确命中或按物理量最近档；remember 避免值不在枚举时每次重组
    // 都全表扫描）。与 stepParam 共用 paramAnchorIdx，保证拨轮位置和步进起点不打架。
    val values = param?.values ?: emptyList()
    val curIdx = if (param == null || values.isEmpty()) -1
        else remember(param) { paramAnchorIdx(param.prop, values, param.current) }

    // 拨轮位置：枚举索引空间的连续值，拖动/吸附过程中可停在档间，静止时必为整数档。
    val pos = remember { Animatable(0f) }
    // 拨轮与真值的唯一同步点：外部值变化（相机实体拨盘/全表直跳/模式切换）时滚过去；
    // 松手吸附也走这里——dragging 是 key，拖动一结束就重新对齐 curIdx，因此拖动期间
    // 发生的外部变化（写失败回读/机身侧改动）不会丢。拖动中不抢（期间的 current 变化
    // 是自己乐观步进出来的，pos 已在正确位置）。
    LaunchedEffect(curIdx, values, dragging) {
        if (curIdx < 0 || dragging) return@LaunchedEffect
        val target = curIdx.toFloat()
        if (abs(pos.value - target) > 2.5f) pos.snapTo(target)   // 大跳（全表直跳）不慢滚
        else if (pos.value != target) pos.animateTo(target, tween(180))
    }
    // 拖动手势内经 rememberUpdatedState 取最新值，避免 pointerInput 捕获过期的
    // 值域长度/锚点/回调（值域随模式变化时不必重启手势）。
    val valueCount = rememberUpdatedState(values.size)
    val anchorIdx = rememberUpdatedState(curIdx)
    val curOnStep = rememberUpdatedState(onStep)

    // 与 GlassButton 同族的玻璃质感：半透明底 + 自上而下高光渐变 + 上亮下暗渐变描边；
    // 拖动中描边整体换成主题蓝示意"正在调"。
    val tileShape = RoundedCornerShape(14.dp)
    BoxWithConstraints(
        modifier = modifier
            .height(54.dp)
            .clip(tileShape)
            .background(colors.glassSurface)
            .background(
                Brush.verticalGradient(
                    listOf(colors.glassHighlightTop, colors.glassHighlightBottom)
                )
            )
            .then(
                if (dragging && writable) Modifier.border(1.5.dp, colors.accentBlue, tileShape)
                else Modifier.border(
                    1.dp,
                    Brush.verticalGradient(
                        listOf(colors.glassBorderTop, colors.glassBorderBottom)
                    ),
                    tileShape
                )
            )
            // 拨轮拖动：内容随手指 1:1 同向滚动，跨档即步进（tick 在 sendValue 里），
            // 端点橡皮筋。无惯性（有意），大跳靠点全表。松手吸附不在这里做——只把
            // dragging 置回 false，由上面的同步 LaunchedEffect 统一滚到 curIdx
            //（正常松手 = 吸附最近档；拖动期间发生过外部变化 = 顺带对齐真值）。
            .pointerInput(writable, downSign, hasAutoIsoControl) {
                if (!writable) return@pointerInput
                var raw = 0f        // 未加阻尼的手指位置（索引空间），越界阻尼只作用于显示
                var lastDetent = 0
                try {
                    detectVerticalDragGestures(
                        onDragStart = {
                            // AUTO 角标只保留轻点切换；从其触控区起手并超过系统拖动阈值后，
                            // 与参数卡其他区域完全一样交给拨轮，避免右上区域拖动无响应。
                            dragging = true
                            // 锚定到当前真值索引而非 pos：半路抓住滚动中的拨轮时，
                            // 步进基点与 stepParam 的 current 起点保持一致，不会错档。
                            val anchor = anchorIdx.value.coerceAtLeast(0)
                            raw = anchor.toFloat()
                            lastDetent = anchor
                            scope.launch { pos.stop(); pos.snapTo(anchor.toFloat()) }
                        },
                        onDragEnd = { dragging = false },
                        onDragCancel = { dragging = false }
                    ) { change, dy ->
                        // 明确消费已成立的拖动，让 AUTO 的 toggleable 取消本次点击，
                        // 避免调完 ISO 松手时又顺带切换自动 ISO。
                        change.consume()
                        val last = valueCount.value - 1
                        if (last < 0) return@detectVerticalDragGestures   // 值域中途清空
                        // 值域中途收窄（模式切换）：把游标拉回新范围，不发巨幅补差步进
                        if (lastDetent > last) {
                            lastDetent = last
                            raw = raw.coerceAtMost(last.toFloat())
                        }
                        raw += downSign * dy / rowPx   // 手指向下 dy>0 → 朝 downSign 方向走档
                        // 未阻尼位置也封顶（±1.5 行）：大幅甩出端点后反向拖立即有响应，
                        // 不必先把看不见的越界量"还"完
                        raw = raw.coerceIn(-1.5f, last + 1.5f)
                        // 端点橡皮筋：越界部分打 3 折，最多探出 0.45 行
                        val shown = when {
                            raw < 0f -> -min(-raw * 0.3f, 0.45f)
                            raw > last -> last + min((raw - last) * 0.3f, 0.45f)
                            else -> raw
                        }
                        scope.launch { pos.snapTo(shown) }
                        val detent = shown.roundToInt().coerceIn(0, last)
                        if (detent != lastDetent) {
                            curOnStep.value(detent - lastDetent)
                            lastDetent = detent
                        }
                    }
                } finally {
                    // key（writable/downSign）变化重启 pointerInput 时，手势协程被静默
                    // 取消而【不】回调 onDragCancel——这里兜底复位，否则 dragging 卡在
                    // true：蓝框常亮、同步 LaunchedEffect 永远早退、拨轮再也不跟真值。
                    dragging = false
                }
            }
            // 单击打开完整值表（仅可写参数；只读已由锁图标表明不可调）。
            .pointerInput(writable, hasAutoIsoControl) {
                val autoTouchLeft = size.width - 44.dp.toPx()
                val autoTouchBottom = 30.dp.toPx()
                detectTapGestures { tap ->
                    val onAuto = hasAutoIsoControl &&
                        tap.x >= autoTouchLeft && tap.y <= autoTouchBottom
                    if (writable && !onAuto) onOpenList()
                }
            }
    ) {
        // AUTO 角标按参数卡实际宽度缩放：横屏右侧控制栏较窄时不再占掉近半张卡，
        // 竖屏空间充足时仍保持原来的上限尺寸。透明触控区继续保留 44×30dp。
        val autoBadgeWidth = (maxWidth * 0.32f).coerceIn(32.dp, 44.dp)
        val autoBadgeHeight = (autoBadgeWidth * 0.5f).coerceIn(17.dp, 22.dp)
        val autoBadgeFontSize = (
            7f + ((autoBadgeWidth.value - 32f) / 12f).coerceIn(0f, 1f) * 2f
        ).sp
        // 左上短标
        if (label.isNotEmpty()) {
            ControlTileFieldLabel(
                text = label,
                color = colors.onSurfaceVariant.copy(
                    alpha = if (valueWritable || hasAutoIsoControl) 0.85f else 0.4f
                ),
                modifier = Modifier.align(Alignment.TopStart).padding(start = 10.dp, top = 6.dp)
            )
        }
        if (hasAutoIsoControl) {
            // 与照片缩略图右上角标同形：贴住右上角，只保留左下圆角。
            val badgeShape = RoundedCornerShape(bottomStart = 6.dp)
            val description = stringResource(R.string.auto_iso)
            val interactionSource = remember { MutableInteractionSource() }
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    // 视觉保持小角标，透明触控区仍为 44×30dp；关闭 indication，
                    // 点击时不会在角标外画出矩形水波纹或阴影。
                    .width(44.dp)
                    .height(30.dp)
                    .semantics { contentDescription = description }
                    .toggleable(
                        value = autoIsoOn,
                        enabled = !autoIsoBusy,
                        role = Role.Switch,
                        interactionSource = interactionSource,
                        indication = null,
                        onValueChange = { enabled -> onAutoIsoToggle?.invoke(enabled) }
                    ),
                contentAlignment = Alignment.TopEnd
            ) {
                ControlTileCornerBadge(
                    text = "AUTO",
                    textColor = if (autoIsoOn) Color.Black.copy(alpha = 0.75f)
                    else colors.onSurfaceVariant,
                    backgroundColor = if (autoIsoOn) ProtectBadgeColor.copy(alpha = 0.90f)
                    else colors.surfaceVariant.copy(alpha = 0.85f),
                    borderColor = colors.glassPanelBorder,
                    shape = badgeShape,
                    modifier = Modifier
                        .width(autoBadgeWidth)
                        .height(autoBadgeHeight)
                        .graphicsLayer { alpha = if (autoIsoBusy) 0.5f else 1f },
                    fontSize = autoBadgeFontSize,
                    contentPadding = PaddingValues(0.dp),
                )
            }
        }
        // 只读锁（右上）
        if (param != null && !valueWritable && autoIsoEnabled == null) {
            Icon(
                Icons.Default.Lock, contentDescription = null,
                tint = colors.onSurfaceVariant.copy(alpha = 0.55f),
                modifier = Modifier.align(Alignment.TopEnd).padding(end = 8.dp, top = 6.dp).size(11.dp)
            )
        }
        // 每个参数项右下角固定保留小型上下调节提示；不可调或 AUTO 接管时压暗。
        if (param != null) {
            Text(
                "↕",
                color = colors.onSurfaceVariant.copy(alpha = if (writable) 0.35f else 0.16f),
                fontSize = 10.sp,
                lineHeight = 10.sp,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 8.dp, bottom = 5.dp)
            )
        }
        if (autoIsoOn) {
            Text(
                autoIsoValue?.let { rcFormat(Lab.PROP_ISO, it) } ?: "—",
                color = colors.onBackground,
                fontFamily = FontFamily.Monospace,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                modifier = Modifier.align(Alignment.Center)
            )
        } else if (writable && param != null) {
            // 数值拨轮：中心 ±2 行作为一列真实滚动。每帧位移/淡显在 graphicsLayer 里读
            // pos（绘制期读，页面不逐帧重组），跨档才经 derivedStateOf 重组换行。
            // 静止时只见中心行，拖动/吸附中相邻行淡入，离中心越远越淡越小（拨筒纵深感）。
            val neighborVis by animateFloatAsState(
                if (dragging || pos.isRunning) 1f else 0f,
                tween(150), label = "wheelNeighbors"
            )
            val centerRow by remember { derivedStateOf { pos.value.roundToInt() } }
            val propCode = param.prop
            for (i in (centerRow - 2)..(centerRow + 2)) {
                val v = values.getOrNull(i) ?: continue
                // 锚点行显示真实 current：值在枚举里时两者相同；不在枚举里（非标准
                // 档位）时读数不撒谎，显示真值而非最近档位。
                val shownValue = if (i == curIdx) param.current else v
                key(i) {
                    Text(
                        rcFormat(propCode, shownValue),
                        color = colors.onBackground,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        modifier = Modifier.align(Alignment.Center).graphicsLayer {
                            // 内容与手指同向：向下拖趋近的档位（i = pos+downSign 方向）
                            // 初始 rel<0 在上缘，随手指下移落入中心。
                            val rel = (pos.value - i) * downSign
                            translationY = rel * rowPx
                            val centered = (1f - abs(rel)).coerceIn(0f, 1f)
                            alpha = (1f - abs(rel) * 0.62f).coerceIn(0f, 1f) *
                                (centered + (1f - centered) * neighborVis)
                            val s = 1f - 0.15f * min(abs(rel), 2f)
                            scaleX = s
                            scaleY = s
                        }
                    )
                }
            }
        } else {
            // 只读/未加载：静态中心值。参数未到时"—"缓慢脉动，表达"正在加载"而非死值。
            val loadingAlpha = if (param == null) {
                val pulse = rememberInfiniteTransition(label = "paramLoading")
                pulse.animateFloat(
                    initialValue = 0.25f, targetValue = 0.55f,
                    animationSpec = infiniteRepeatable(tween(900), RepeatMode.Reverse),
                    label = "paramLoadingAlpha"
                ).value
            } else 1f
            Text(
                if (param != null) rcFormat(param.prop, param.current) else "—",
                color = if (param == null) colors.onSurfaceVariant.copy(alpha = loadingAlpha)
                        else colors.onSurfaceVariant.copy(alpha = 0.5f),
                fontFamily = FontFamily.Monospace,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                modifier = Modifier.align(Alignment.Center)
            )
        }
    }
}

/**
 * 大圆快门键（两段式 + 快拍）：
 * - 快速点击（按下后 ~300ms 内抬手，落点在键内）→ [onQuickTap] 直接拍摄/切换录制，
 *   跳过对焦阶段，无蓝框反馈。
 * - 长按（按住 >~300ms）→ 先触发 [onFocusStart] 半按对焦，边框转蓝 + 内圈收缩；
 *   抬手落点在键内 → onRelease(true) 拍摄；移出键外抬手/手势被取消 → onRelease(false) 取消。
 * - 拍摄中（capturing）转圈并禁手势。
 */
@Composable
private fun ShutterButton(
    capturing: Boolean,
    focusing: Boolean,
    enabled: Boolean,
    movie: Boolean,
    recording: Boolean,
    onFocusStart: () -> Unit,
    onRelease: (fire: Boolean) -> Unit,
    onQuickTap: () -> Unit
) {
    val colors = AppTheme.colors
    var heldDown by remember { mutableStateOf(false) }
    val coroutineScope = rememberCoroutineScope()
    val innerScale by animateFloatAsState(
        targetValue = if (focusing) 0.8f else 1f,
        animationSpec = tween(120),
        label = "shutterFocus"
    )
    // 按压下沉：按住期间轻微下沉，松开弹性回弹——与 GlassButton 同手感。
    // heldDown 覆盖 300ms 窗口（对焦尚未开始但手指已按下）；focusing 覆盖长按对焦期。
    val pressScale by animateFloatAsState(
        targetValue = if (heldDown || focusing) 0.95f else 1f,
        animationSpec = if (heldDown || focusing) tween(100) else Motion.bouncy(),
        label = "shutterPress"
    )
    val ringColor = when {
        !enabled -> colors.onBackground.copy(alpha = 0.3f)
        focusing -> colors.accentBlue
        else -> colors.onBackground.copy(alpha = 0.9f)
    }
    // 内芯形态：照片=白色大圆；录像待机=红色大圆；录制中=红色小圆角方块（通用停止
    // 语义），尺寸与圆角同步动画做圆→方块的连续变形。
    val innerColor = if (movie) colors.statusError else Color.White
    val innerSize by animateDpAsState(
        targetValue = if (recording) 28.dp else 60.dp,
        animationSpec = tween(160), label = "recInnerSize"
    )
    val innerCorner by animateDpAsState(
        targetValue = if (recording) 7.dp else 30.dp,
        animationSpec = tween(160), label = "recInnerCorner"
    )
    Box(
        modifier = Modifier
            .size(76.dp)
            .graphicsLayer {
                scaleX = pressScale
                scaleY = pressScale
            }
            .border(3.dp, ringColor, CircleShape)
            .then(
                // 照片拍摄确认中禁手势；录制中保持可用——停止靠的就是再按一下。
                if (enabled && !capturing)
                    Modifier.pointerInput(Unit) {
                        awaitEachGesture {
                            awaitFirstDown()
                            heldDown = true
                            var timerFired = false
                            // 300ms 计时器：超时后触发半按对焦；抬起在计时结束前=快拍。
                            val timerJob = coroutineScope.launch {
                                delay(300)
                                timerFired = true
                                onFocusStart()
                            }
                            val up = waitForUpOrCancellation()
                            heldDown = false
                            timerJob.cancel()
                            if (timerFired) {
                                // 长按：对焦已触发，抬手落点判定拍摄/取消
                                val fire = up != null &&
                                    up.position.x in 0f..size.width.toFloat() &&
                                    up.position.y in 0f..size.height.toFloat()
                                onRelease(fire)
                            } else {
                                // 快拍：无对焦，抬手在键内直接拍摄
                                val fire = up != null &&
                                    up.position.x in 0f..size.width.toFloat() &&
                                    up.position.y in 0f..size.height.toFloat()
                                if (fire) onQuickTap()
                            }
                        }
                    }
                else Modifier
            ),
        contentAlignment = Alignment.Center
    ) {
        if (capturing) {
            CircularProgressIndicator(
                modifier = Modifier.size(52.dp),
                color = colors.onBackground,
                strokeWidth = 3.dp
            )
        } else {
            Box(
                Modifier
                    .size(innerSize)
                    .graphicsLayer {
                        scaleX = innerScale
                        scaleY = innerScale
                    }
                    .background(
                        innerColor.copy(alpha = if (enabled) 1f else 0.3f),
                        RoundedCornerShape(innerCorner)
                    )
            )
        }
    }
}

@Composable
private fun TapFocusReticleOverlay(
    feedback: TapFocusFeedback,
    point: Offset,
    nonce: Int,
    imageAspectRatio: Float,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    val appearScale = remember { Animatable(1.45f) }
    LaunchedEffect(nonce) {
        appearScale.snapTo(1.45f)
        appearScale.animateTo(1f, tween(180))
    }
    val resultScale by animateFloatAsState(
        targetValue = if (feedback == TapFocusFeedback.FOCUSING) 1f else 0.9f,
        animationSpec = Motion.bouncy(),
        label = "tapAfResult"
    )
    val reticleColor = when (feedback) {
        TapFocusFeedback.LOCKED -> colors.statusConnected
        TapFocusFeedback.FAILED -> colors.statusError
        else -> colors.accentBlue
    }.copy(alpha = 0.95f)

    Canvas(modifier) {
        val imageRect = fitCenterRect(size.width, size.height, imageAspectRatio)
        val scale = appearScale.value * resultScale
        val half = 32.dp.toPx() * scale
        val len = 12.dp.toPx() * scale
        val stroke = 2.dp.toPx()
        val requestedCenter = Offset(
            imageRect.left + imageRect.width * point.x.coerceIn(0f, 1f),
            imageRect.top + imageRect.height * point.y.coerceIn(0f, 1f)
        )
        // 只约束反馈框的绘制位置，发给相机的坐标仍是用户真实点位。
        // 这样点画面边缘时框不会被圆角取景器裁掉一半。
        val center = Offset(
            if (imageRect.width >= half * 2f) {
                requestedCenter.x.coerceIn(imageRect.left + half, imageRect.right - half)
            } else imageRect.center.x,
            if (imageRect.height >= half * 2f) {
                requestedCenter.y.coerceIn(imageRect.top + half, imageRect.bottom - half)
            } else imageRect.center.y
        )
        drawFocusCornerReticle(
            center = center,
            halfSize = half,
            cornerLength = len,
            color = reticleColor,
            strokeWidth = stroke
        )
    }
}

/** AF 完成后的常驻红框；优先保留相机报告的尺寸与位置，未知头型退回应用请求点。 */
@Composable
private fun ConfirmedFocusReticleOverlay(
    fallbackPoint: Offset,
    cameraFrame: LiveViewFocusFrame?,
    nonce: Long,
    imageAspectRatio: Float,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    val appearScale = remember { Animatable(1.12f) }
    LaunchedEffect(nonce) {
        appearScale.snapTo(1.12f)
        appearScale.animateTo(1f, tween(160))
    }

    Canvas(modifier) {
        val imageRect = fitCenterRect(size.width, size.height, imageAspectRatio)
        if (imageRect.width <= 0f || imageRect.height <= 0f) return@Canvas
        val point = cameraFrame?.let { Offset(it.centerX, it.centerY) } ?: fallbackPoint
        val fallbackHalf = 25.dp.toPx()
        val minHalf = 13.dp.toPx()
        // 动画缩放后再封顶，确保全画幅/边缘 AF 框也不会产生反向 coerceIn 区间。
        val halfWidth = (
            (cameraFrame?.let { imageRect.width * it.width / 2f } ?: fallbackHalf) *
                appearScale.value
            ).coerceIn(minOf(minHalf, imageRect.width / 2f), imageRect.width / 2f)
        val halfHeight = (
            (cameraFrame?.let { imageRect.height * it.height / 2f } ?: fallbackHalf) *
                appearScale.value
            ).coerceIn(minOf(minHalf, imageRect.height / 2f), imageRect.height / 2f)
        val requestedCenter = Offset(
            imageRect.left + imageRect.width * point.x.coerceIn(0f, 1f),
            imageRect.top + imageRect.height * point.y.coerceIn(0f, 1f)
        )
        val center = Offset(
            if (imageRect.width >= halfWidth * 2f) {
                requestedCenter.x.coerceIn(
                    imageRect.left + halfWidth,
                    imageRect.right - halfWidth
                )
            } else {
                imageRect.center.x
            },
            if (imageRect.height >= halfHeight * 2f) {
                requestedCenter.y.coerceIn(
                    imageRect.top + halfHeight,
                    imageRect.bottom - halfHeight
                )
            } else {
                imageRect.center.y
            }
        )
        val cornerLength = minOf(10.dp.toPx(), halfWidth, halfHeight)
        drawFocusCornerReticle(
            center = center,
            halfWidth = halfWidth,
            halfHeight = halfHeight,
            cornerLength = cornerLength,
            color = colors.statusConnected.copy(alpha = 0.85f),   // green confirmation, not red
            strokeWidth = 1.8.dp.toPx()
        )
    }
}

/**
 * 监看工具栏：所有按钮按真实固有尺寸从左向右排列，按钮间距始终一致。
 * 空间不足时整颗按钮移到下一行，行数不设上限；任何一项都不会被 weight 或父级约束压窄。
 */
@Composable
private fun AdaptiveRemoteToolBar(
    modifier: Modifier = Modifier,
    horizontalGap: androidx.compose.ui.unit.Dp = 6.dp,
    verticalGap: androidx.compose.ui.unit.Dp = 4.dp,
    pinnedEndCount: Int = 0,
    content: @Composable () -> Unit
) {
    Layout(modifier = modifier, content = content) { measurables, constraints ->
        val gapPx = horizontalGap.roundToPx()
        val rowGapPx = verticalGap.roundToPx()
        val maxWidth = constraints.maxWidth
        // 无最小/最大宽度测量得到按钮真实固有宽度；TopIconToggle 只设最小尺寸，
        // HD/FPS 在字体放大后会自然变宽，然后由这里决定是否整颗换行。
        val placeables = measurables.map { it.measure(Constraints()) }
        val pinnedCount = pinnedEndCount.coerceIn(0, placeables.size)
        val regularEnd = placeables.size - pinnedCount
        val pinnedIndices = (regularEnd until placeables.size).toList()
        val pinnedWidth = pinnedIndices.sumOf { placeables[it].width } +
            gapPx * (pinnedIndices.size - 1).coerceAtLeast(0)

        // 第一行先为尾部固定项预留真实宽度，因此全屏和旋转永远处在第一行按钮组的
        // 最右端。这里是“紧跟普通工具后的行内尾部”，不是用空白把按钮撑到屏幕右缘。
        // 普通工具只使用剩余空间，放不下就整颗移到后续行。
        val firstRowCapacity = if (pinnedIndices.isEmpty()) {
            maxWidth
        } else {
            (maxWidth - pinnedWidth - gapPx).coerceAtLeast(0)
        }
        val firstRow = mutableListOf<Int>()
        var nextTool = 0
        var firstRowWidth = 0
        while (nextTool < regularEnd) {
            val placeable = placeables[nextTool]
            val candidateWidth =
                firstRowWidth + (if (firstRow.isEmpty()) 0 else gapPx) + placeable.width
            if (candidateWidth > firstRowCapacity) break
            firstRow += nextTool
            firstRowWidth = candidateWidth
            nextTool++
        }

        val rows = mutableListOf<MutableList<Int>>(firstRow)
        while (nextTool < regularEnd) {
            val row = mutableListOf<Int>()
            var rowWidth = 0
            while (nextTool < regularEnd) {
                val placeable = placeables[nextTool]
                val candidateWidth =
                    rowWidth + (if (row.isEmpty()) 0 else gapPx) + placeable.width
                if (row.isNotEmpty() && candidateWidth > maxWidth) break
                row += nextTool
                rowWidth = candidateWidth
                nextTool++
                // 单颗按钮理论上比整个窗口还宽时仍保持固有宽度，只独占一行。
                if (rowWidth > maxWidth) break
            }
            rows += row
        }

        val rowHeights = rows.mapIndexed { rowIndex, row ->
            val indices = if (rowIndex == 0) row + pinnedIndices else row
            indices.maxOfOrNull { placeables[it].height } ?: 0
        }
        val naturalHeight = rowHeights.sum() + rowGapPx * (rows.size - 1).coerceAtLeast(0)
        val layoutHeight = naturalHeight.coerceIn(constraints.minHeight, constraints.maxHeight)

        layout(maxWidth, layoutHeight) {
            var y = 0
            rows.forEachIndexed { rowIndex, row ->
                val rowHeight = rowHeights[rowIndex]
                var x = 0
                row.forEach { index ->
                    val placeable = placeables[index]
                    placeable.placeRelative(x, y + (rowHeight - placeable.height) / 2)
                    x += placeable.width + gapPx
                }
                if (rowIndex == 0 && pinnedIndices.isNotEmpty()) {
                    var pinnedX = if (row.isEmpty()) 0 else x
                    pinnedIndices.forEach { index ->
                        val placeable = placeables[index]
                        placeable.placeRelative(
                            pinnedX,
                            y + (rowHeight - placeable.height) / 2
                        )
                        pinnedX += placeable.width + gapPx
                    }
                }
                y += rowHeight + rowGapPx
            }
        }
    }
}

/** 顶栏紧凑切换按钮：保持最小点击尺寸，文字类标记可按固有宽度自然扩展。 */
@Composable
internal fun TopIconToggle(
    active: Boolean,
    contentDescription: String,
    onClick: () -> Unit,
    content: @Composable () -> Unit
) {
    val colors = AppTheme.colors
    GlassButton(
        onClick = onClick,
        active = active,
        shape = CircleShape,
        showSheen = false,
        shadowElevation = 0.dp,
        contentPadding = PaddingValues(8.dp),
        modifier = Modifier
            .defaultMinSize(minWidth = 36.dp, minHeight = 36.dp)
            .semantics { this.contentDescription = contentDescription }
    ) {
        CompositionLocalProvider(
            LocalContentColor provides if (active) colors.accentBlue else colors.onSurfaceVariant
        ) {
            Box(
                modifier = Modifier.defaultMinSize(minWidth = 20.dp, minHeight = 20.dp),
                contentAlignment = Alignment.Center
            ) {
                content()
            }
        }
    }
}
