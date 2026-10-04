package com.ztransfer.ui.screen

import com.ztransfer.protocol.probeMovieFormat
import com.ztransfer.protocol.probeLegacyVideoTime
import com.ztransfer.util.HistogramMode
import com.ztransfer.lut.LutFolderRepository
import com.ztransfer.lut.LutMonitorState
import com.ztransfer.lut.LutPreferences

import android.Manifest
import android.content.Context
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.hardware.SensorManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.SystemClock
import android.widget.Toast
import android.provider.DocumentsContract
import android.view.OrientationEventListener
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateColorAsState
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
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.CenterFocusStrong
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.outlined.AspectRatio
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.center
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.layoutId
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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.protocol.Lab
import com.ztransfer.protocol.LiveViewFocusFrame
import com.ztransfer.protocol.LiveViewFocusJudgement
import com.ztransfer.protocol.LiveViewMetadata
import com.ztransfer.protocol.LiveViewPacket
import com.ztransfer.protocol.LiveViewSoundLevels
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.PtpConstants
import com.ztransfer.protocol.RcParam
import com.ztransfer.protocol.RemoteCameraTool
import com.ztransfer.protocol.labEndLiveView
import com.ztransfer.protocol.labGrabFrame
import com.ztransfer.protocol.labStartLiveView
import com.ztransfer.protocol.liveViewWarmupRemainingMs
import com.ztransfer.protocol.rcAfDriveAndWait
import com.ztransfer.protocol.rcAngleLevelRoll
import com.ztransfer.protocol.rcAutoIsoCandidateProps
import com.ztransfer.protocol.NIKON_EXPOSURE_INDICATE
import com.ztransfer.protocol.NIKON_LIGHT_METER
import com.ztransfer.protocol.rcExposureMeterEv
import com.ztransfer.protocol.rcReadExposureMeter
import com.ztransfer.protocol.rcBatteryPercentage
import com.ztransfer.protocol.rcCapture
import com.ztransfer.protocol.rcFocusAt
import com.ztransfer.protocol.rcChangeApplicationMode
import com.ztransfer.protocol.rcCanonicalExposureProp
import com.ztransfer.protocol.rcEndMovie
import com.ztransfer.protocol.rcEndSubjectTracking
import com.ztransfer.protocol.rcFormat
import com.ztransfer.protocol.rcGetAngleLevel
import com.ztransfer.protocol.rcGetCompatibleParam
import com.ztransfer.protocol.focusModeProperties
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
import com.ztransfer.protocol.movieStartNeedsLiveViewRestart
import com.ztransfer.protocol.movieProhibitIndicatesRecording
import com.ztransfer.protocol.diagnosticSummary
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.LocalButtonTexturePalette
import com.ztransfer.ui.theme.Motion
import com.ztransfer.ui.theme.SkinPreset
import com.ztransfer.ui.theme.rememberAppBackgroundBrush
import com.ztransfer.ui.util.rememberHaptics
import com.ztransfer.viewmodel.presentationConnectionType
import com.ztransfer.viewmodel.presentationIsSta
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
private const val TRACKING_CANCEL_EXIT_MS = 220L
private const val REMOTE_ORIENTATION_STABLE_MS = 260L
private const val REMOTE_ROTATION_FADE_OUT_MS = 80
private const val REMOTE_ROTATION_FADE_IN_MS = 140

private data class RemoteRotationRequest(
    val rotation: Int,
)

/**
 * Keeps sensor callbacks out of Compose state. A manual rotation cancels only the pending
 * transition for the current physical direction; automatic following resumes after the phone
 * reaches a different stable direction.
 */
private class RemoteOrientationSession {
    var candidateRotation: Int? = null
    var manuallySuppressedRotation: Int? = null
    var pendingJob: Job? = null

    fun cancelPending() {
        pendingJob?.cancel()
        pendingJob = null
    }

    fun suppressCurrentDirection() {
        manuallySuppressedRotation = candidateRotation
        cancelPending()
    }

    fun pause() {
        candidateRotation = null
        cancelPending()
    }
}

/**
 * Maps only the centres of the three layouts supported by RemoteScreen. The gaps are deliberate
 * hysteresis zones, and upside-down portrait is ignored because the monitor has no 180° layout.
 */
internal fun remoteRotationForDeviceOrientation(orientation: Int): Int? = when (orientation) {
    in 0..30, in 330..359 -> 0
    in 60..120 -> 2
    in 240..300 -> 1
    else -> null
}

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
    remoteControlModeSet: Boolean,
    diagnosticControlModeSet: Boolean = false
): Boolean = connectionType == CameraConnectionType.USB && remoteControlModeSet &&
    !diagnosticControlModeSet

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
    val analysis: MonitorAnalysis?,
    val metadata: LiveViewMetadata?,
    val receivedAtElapsedMs: Long
)

private data class ConfirmedFocusMarker(
    val fallbackPoint: Offset,
    val confirmedAtElapsedMs: Long,
    /** true 时框的位置随每一帧的相机追踪结果更新，直到追踪会话结束。 */
    val subjectTracking: Boolean = false
)


private class HistogramThrottle {
    var lastCalculatedAtMs: Long = 0L
    var cached: LuminanceHistogram? = null
}

/** 斑马掩码最多 20Hz 更新，节流间隔内复用缓存实例。 */
private class ZebraThrottle {
    var lastCalculatedAtMs: Long = 0L
    var cached: ZebraMask? = null
}

private data class ViewfinderTap(
    val trackingX: Int,
    val trackingY: Int,
    val trackingCoordinateWidth: Int,
    val trackingCoordinateHeight: Int,
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
    val context = LocalContext.current
    val activity = context.findActivity()
    val originalOrientation = remember(activity) {
        activity?.requestedOrientation ?: ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    }
    val lifecycleOwner = LocalLifecycleOwner.current
    val screenScope = rememberCoroutineScope()
    val tools = remember(context) { RemoteToolPreferences(context.getSharedPreferences("ztransfer", Context.MODE_PRIVATE)) }
    var rotation by remember { mutableIntStateOf(if (tools.locked.value) tools.lockedRotation.value else 0) }
    val orientationLocked by tools.locked
    var editingTools by remember { mutableStateOf(false) }
    // Keep the portrait editor stable while the user rearranges tools.
    val orientationFrozen = orientationLocked || editingTools
    val currentOrientationLocked by rememberUpdatedState(orientationFrozen)
    var switchingRotation by remember { mutableStateOf(false) }
    val rotationFade = remember { Animatable(1f) }
    val rotationRequests = remember { Channel<RemoteRotationRequest>(Channel.CONFLATED) }
    val orientationSession = remember { RemoteOrientationSession() }
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

    LaunchedEffect(rotationRequests) {
        for (request in rotationRequests) {
            if (currentOrientationLocked || request.rotation == rotation) continue
            switchingRotation = true
            try {
                rotationFade.animateTo(
                    targetValue = 0f,
                    animationSpec = tween(REMOTE_ROTATION_FADE_OUT_MS),
                )
                if (!currentOrientationLocked) {
                    rotation = request.rotation
                }
                // Let the new constraints/layout reach composition while the host is invisible.
                withFrameNanos { }
                rotationFade.animateTo(
                    targetValue = 1f,
                    animationSpec = tween(REMOTE_ROTATION_FADE_IN_MS),
                )
            } finally {
                switchingRotation = false
            }
        }
    }

    DisposableEffect(context, lifecycleOwner, orientationSession, rotationRequests, orientationFrozen) {
        val listener = object : OrientationEventListener(context, SensorManager.SENSOR_DELAY_NORMAL) {
            override fun onOrientationChanged(orientation: Int) {
                if (currentOrientationLocked) return
                val candidate = remoteRotationForDeviceOrientation(orientation)
                if (candidate == orientationSession.candidateRotation) return

                orientationSession.candidateRotation = candidate
                orientationSession.cancelPending()
                if (candidate != null) {
                    if (candidate == orientationSession.manuallySuppressedRotation) return
                    orientationSession.manuallySuppressedRotation = null
                    orientationSession.pendingJob = screenScope.launch {
                        delay(REMOTE_ORIENTATION_STABLE_MS)
                        if (orientationSession.candidateRotation == candidate) {
                            rotationRequests.trySend(
                                RemoteRotationRequest(rotation = candidate)
                            )
                        }
                    }
                }
            }
        }
        val canDetectOrientation = listener.canDetectOrientation()
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> if (canDetectOrientation && !currentOrientationLocked) listener.enable()
                Lifecycle.Event.ON_PAUSE -> {
                    listener.disable()
                    orientationSession.pause()
                }
                else -> Unit
            }
        }

        if (orientationFrozen) {
            listener.disable()
            orientationSession.pause()
            while (rotationRequests.tryReceive().isSuccess) { /* discard queued rotations */ }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            listener.disable()
            lifecycleOwner.lifecycle.removeObserver(observer)
            orientationSession.pause()
        }
    }

    fun cycleRotation() {
        if (switchingRotation || currentOrientationLocked) return
        orientationSession.suppressCurrentDirection()
        rotationRequests.trySend(
            RemoteRotationRequest(rotation = (rotation + 1) % 3)
        )
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
            val hostModifier = if (rotation == 0) {
                Modifier.fillMaxSize().graphicsLayer { alpha = rotationFade.value }
            } else {
                Modifier
                    .requiredSize(width = maxHeight, height = maxWidth)
                    .graphicsLayer {
                        this.rotationZ = rotationZ
                        alpha = rotationFade.value
                    }
            }
            val contentInsets = when (rotation) {
                1 -> rotationLeftInset to rotationRightInset
                2 -> rotationRightInset to rotationLeftInset
                else -> 0.dp to 0.dp
            }
            Box(hostModifier.background(backgroundBrush)) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .absolutePadding(
                            left = contentInsets.first,
                            right = contentInsets.second,
                        )
                ) {
                    RemoteContent(
                        cameraViewModel = cameraViewModel,
                        transferViewModel = transferViewModel,
                        onNavigateBack = { if (editingTools) editingTools = false else onNavigateBack() },
                        rotation = rotation,
                        tools = tools,
                        editingTools = editingTools,
                        onEditingTools = { editing ->
                            orientationSession.pause()
                            while (rotationRequests.tryReceive().isSuccess) { }
                            editingTools = editing && rotation == 0
                        },
                        onLockRotation = { lock ->
                            orientationSession.pause()
                            while (rotationRequests.tryReceive().isSuccess) { }
                            if (lock) tools.lockedRotation.value = rotation
                            tools.locked.value = lock
                        },
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
private const val BATTERY_REFRESH_INTERVAL_MS = 120_000L
private val REMOTE_DESQUEEZE_OPTIONS = listOf(1f, 1.33f, 1.5f, 1.8f, 2f)

private fun desqueezeDisplayValue(value: Float): String =
    if (kotlin.math.abs(value - 1.33f) < 0.01f) "1.3" else value.toString()

@Composable
private fun RemoteContent(
    cameraViewModel: CameraViewModel,
    transferViewModel: TransferViewModel,
    onNavigateBack: () -> Unit,
    rotation: Int,
    tools: RemoteToolPreferences,
    editingTools: Boolean,
    onEditingTools: (Boolean) -> Unit,
    onLockRotation: (Boolean) -> Unit,
    onCycleRotation: () -> Unit,
    onReady: () -> Unit = {},
    trialLeftSeconds: Int? = null,
    isPro: Boolean = false
) {
    val colors = AppTheme.colors
    val camState by cameraViewModel.state.collectAsState()
    val transferState by transferViewModel.state.collectAsState()
    val services = rememberRemoteScreenServices(transferState.hapticsEnabled)
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
    // 只表示本页面成功启动且仍存续的主体追踪。协议端另有相机级状态负责成对结束命令；
    // 这里用于决定是否持续绘制相机每帧返回的移动框。
    var subjectTrackingActive by remember { mutableStateOf(false) }
    // 标准 PTP BatteryLevel(0x5001)：保留属性描述以便后续只读标量值，
    // 避免 120s 兜底刷新时重复拉取 DevicePropDesc。
    var batteryParam by remember { mutableStateOf<RcParam?>(null) }
    val params = remember { mutableStateMapOf<Int, RcParam>() }
    // 每个参数一个待发送任务：乐观更新后合并发送最终值（声明在前，事件循环要引用）
    val pendingSets = remember { mutableStateMapOf<Int, Job>() }
    var autoIsoProp by remember { mutableStateOf<Int?>(null) }
    var autoIsoPropMovieMode by remember { mutableStateOf<Boolean?>(null) }
    var autoIsoBusy by remember { mutableStateOf(false) }
    var autoIsoProbeLogKey by remember { mutableStateOf<String?>(null) }
    // 初始参数是否已加载完：用于把事件轮询推迟到之后开始，避免进页时 GetEvent 与
    // 曝光参数与模式读取抢 相机事务调度器、拖慢参数首次显示。
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
    val parameterAnchors = remember { mutableMapOf<Int, androidx.compose.ui.layout.LayoutCoordinates>() }

    // ---------- 开发者面板 ----------
    val diagnosticPreferences = remember(services.context) {
        services.context.getSharedPreferences("remote_diagnostics", Context.MODE_PRIVATE)
    }
    var focusModeReport by remember {
        mutableStateOf(diagnosticPreferences.getString("focus_mode_report_v1", "").orEmpty())
    }
    var devPanel by remember { mutableStateOf(false) }
    fun focusModeLog(line: String) {
        focusModeReport = (focusModeReport.lines() + line).takeLast(80).joinToString("\n")
    }
    fun startFocusModeReport() {
        val cam = cameraViewModel.getCamera()
        focusModeReport = "Focus mode v1 ${java.time.OffsetDateTime.now()} app=${BuildConfig.VERSION_NAME}(${BuildConfig.VERSION_CODE})\n" +
            "camera=${cam?.deviceModel} firmware=${cam?.cachedDeviceInfo?.deviceVersion} " +
            "transport=${cam?.connectionType} mode=${if (cam?.connectionType == CameraConnectionType.USB) "USB" else if (camState.isStaConnection) "STA" else "AP"}\n" +
            "movie=$movieMode current=$focusModeText"
    }
    DisposableEffect(Unit) {
        onDispose { diagnosticPreferences.edit().putString("focus_mode_report_v1", focusModeReport).apply() }
    }
    // 开发者入口默认隐藏：1.5s 内连按 4 次 FPS 键才现身（FPS 连按 4 次开关状态
    // 恰好复原，不留副作用）。仅本次进页有效，退页复位——这是诊断后门不是常驻功能。
    var devUnlocked by remember { mutableStateOf(false) }
    var fpsTaps by remember { mutableIntStateOf(0) }
    var lastFpsTapAt by remember { mutableLongStateOf(0L) }
    var showFps by tools.fps
    var hdLiveView by tools.hd
    var histogramMode by tools.histogram
    val showHistogram = histogramMode != HistogramMode.OFF
    var framingGrid by tools.grid
    var exposureAssist by tools.exposure
    val showZebra = exposureAssist == ExposureAssist.ZEBRA
    var showLevel by tools.level
    var showFocusFrame by tools.focusFrame
    var focusValidAfter by remember { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    LaunchedEffect(movieMode, connected, focusModeText) { focusValidAfter = SystemClock.elapsedRealtime() }
    var showMeter by tools.meter
    var meterSample by remember { mutableStateOf<Pair<Float, Long>?>(null) }
    val meterGeneration = remember { longArrayOf(0L) }
    var showAudioLevels by tools.audio
    var desqueezeMultiplier by tools.desqueeze
    var waveformMode by tools.waveform
    val showWaveform = waveformMode != WaveformMode.OFF
    var gridPanelOpen by remember { mutableStateOf(false) }
    var gridPanelCloseRequested by remember { mutableStateOf(false) }
    var gridAnchor by remember { mutableStateOf<androidx.compose.ui.layout.LayoutCoordinates?>(null) }
    var cameraToolPanel by remember { mutableStateOf<RemoteCameraTool?>(null) }
    val cameraToolUnavailableHint = stringResource(R.string.remote_camera_tool_unavailable)
    var cameraToolLoading by remember(cameraToolPanel) { mutableStateOf(cameraToolPanel != null) }
    var cameraToolCloseRequested by remember { mutableStateOf(false) }
    var toolOverlayCoordinates by remember { mutableStateOf<androidx.compose.ui.layout.LayoutCoordinates?>(null) }
    var whiteBalanceAnchor by remember { mutableStateOf<androidx.compose.ui.layout.LayoutCoordinates?>(null) }
    var focusModeAnchor by remember { mutableStateOf<androidx.compose.ui.layout.LayoutCoordinates?>(null) }
    var cameraToolWriting by remember { mutableStateOf(false) }
    var focusAreaAnchor by remember { mutableStateOf<androidx.compose.ui.layout.LayoutCoordinates?>(null) }
    fun setDesqueezeMultiplier(value: Float) { desqueezeMultiplier = value }
    fun toggleAudioLevels() { showAudioLevels = !showAudioLevels }
    // 相机机身的滚转角（0xD067），null=还没读到/机身不支持，此时水平仪一笔都不画
    var levelRoll by remember { mutableStateOf<Float?>(null) }
    var levelPitch by remember { mutableStateOf<Float?>(null) }

    val landscapeLayout = rotation != 0
    LaunchedEffect(rotation, editingTools) {
        gridPanelOpen = false
        gridPanelCloseRequested = false
        cameraToolPanel = null
        cameraToolCloseRequested = false
    }
    BackHandler(enabled = devPanel) { devPanel = false }
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
        // General camera diagnostics stay out of the focus report.
        if (BuildConfig.DEBUG) android.util.Log.d("RemoteControl", line)
    }

    // 事件总线：单一轮询协程独占 GetEvent（事件是取走即消费的，多处轮询会互相偷事件），
    // 拍摄流程从这里等 ObjectAdded。
    val eventFlow = remember { MutableSharedFlow<Pair<Int, Long>>(extraBufferCapacity = 32) }

    val currentHistogramMode = rememberUpdatedState(histogramMode)
    val histogramThrottle = remember { HistogramThrottle() }
    val currentZebraEnabled = rememberUpdatedState(showZebra)
    val currentFalseColorEnabled = rememberUpdatedState(exposureAssist == ExposureAssist.FALSE_COLOR)
    val currentWaveformMode = rememberUpdatedState(waveformMode)
    val analysisThrottle = remember { MonitorAnalysisThrottle() }
    val zebraThrottle = remember { ZebraThrottle() }
    suspend fun decode(
        bytes: ByteArray,
        offset: Int = 0,
        metadata: LiveViewMetadata? = null,
        receivedAtElapsedMs: Long = SystemClock.elapsedRealtime()
    ): RemoteLiveFrame? =
        withContext(Dispatchers.Default) {
            BitmapFactory.decodeByteArray(bytes, offset, bytes.size - offset)?.let { bitmap ->
                val histogram = if (currentHistogramMode.value != HistogramMode.OFF) {
                    val now = SystemClock.elapsedRealtime()
                    val includeRgb = currentHistogramMode.value == HistogramMode.RGB
                    if (histogramThrottle.cached == null ||
                        (includeRgb && histogramThrottle.cached?.rgb == null) ||
                        now - histogramThrottle.lastCalculatedAtMs >= 250L
                    ) {
                        histogramThrottle.cached = calculateLuminanceHistogram(bitmap, includeRgb = includeRgb)
                        histogramThrottle.lastCalculatedAtMs = now
                    }
                    histogramThrottle.cached
                } else {
                    histogramThrottle.cached = null
                    null
                }
                // 斑马掩码独立以最多 20Hz 更新，避免高光区域跟随动作明显滞后。
                val zebraMask = if (currentZebraEnabled.value) {
                    val now = SystemClock.elapsedRealtime()
                    if (zebraThrottle.cached == null ||
                        now - zebraThrottle.lastCalculatedAtMs >= 50L
                    ) {
                        zebraThrottle.cached = calculateZebraMask(bitmap)
                        zebraThrottle.lastCalculatedAtMs = now
                    }
                    zebraThrottle.cached
                } else {
                    zebraThrottle.cached = null
                    null
                }
                val falseColor = currentFalseColorEnabled.value
                val waveform = currentWaveformMode.value
                val analysis = analysisThrottle.analyze(bitmap, falseColor, waveform != WaveformMode.OFF, SystemClock.elapsedRealtime(), rgb = waveform == WaveformMode.RGB)
                RemoteLiveFrame(
                    image = bitmap.asImageBitmap(),
                    histogram = histogram,
                    zebraMask = zebraMask,
                    analysis = analysis,
                    metadata = metadata,
                    receivedAtElapsedMs = receivedAtElapsedMs
                )
            }
        }

    suspend fun refreshParam(prop: Int) {
        val cam = cameraViewModel.getCamera() ?: return
        val shutterLogical = prop == Lab.PROP_NK_SHUTTER || prop == Lab.PROP_NK_MOVIE_SHUTTER
        val selected = try {
            cam.rcGetCompatibleParam(prop, null)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            devLog("!! capability logical=0x%04X error=%s: %s".format(prop, e.javaClass.simpleName, e.message))
            null
        }
        if (shutterLogical) {
            devLog(
                "shutter selected=" + (selected?.let {
                    "prop=0x%04X writable=%s current=%d values=%d".format(
                        it.prop, it.writable, it.current, it.values.size
                    )
                } ?: "none")
            )
        }
        selected?.let { params[prop] = it }
    }

    suspend fun refreshBattery(forceDescribe: Boolean = false) {
        val cam = cameraViewModel.getCamera() ?: return
        val current = batteryParam
        val refreshed = if (current == null || forceDescribe) {
            runCatching { cam.rcGetParam(Lab.PROP_BATTERY_LEVEL) }.getOrNull()
        } else {
            runCatching { cam.rcRefreshParam(current) }.getOrNull()
        }
        // 瞬时忙/通信失败时保留上次有效读数，避免顶栏无意义闪烁。
        if (refreshed != null) batteryParam = refreshed
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
        val modeAtRead = movieMode
        val focus = runCatching { cam.rcGetFocusMode() }.getOrNull()
        if (cameraViewModel.getCamera() !== cam || movieMode != modeAtRead) return
        val changed = !focusModeQueried ||
            focusModeText != focus?.label || focusModeProp != focus?.prop
        focusModeQueried = true
        focusModeText = focus?.label
        focusModeProp = focus?.prop
        focusModeManual = focus?.manual == true
        if (focus != null && changed) {
            devLog("focus mode ${focus.label} prop=0x%04X raw=0x%X".format(focus.prop, focus.raw))
        } else if (focus == null && changed) {
            devLog("!! focus mode unavailable (0x500A/0xD061/0xD161)")
        }
    }

    // ---------- 照片/录像模式 ----------
    // movieMode 跟随相机的实体照片/录像拨杆（0xD1A6 LiveViewSelector）：录像位时
    // 快门键变成开始/停止录像。读不到该属性的机型永远按照片模式（优雅降级）。
    // recording 以事件为准（0xC10A 开始 / 0xC108 完成 / 0xC105 中断），发命令成功时
    // 乐观置位让 UI 立即响应；lastStopCmdAt 用于滤掉停止后才轮询到的迟到"已开始"回声。
    var recording by remember { mutableStateOf(false) }
    var movieFormatReport by remember { mutableStateOf("") }
    var legacyVideoReport by remember { mutableStateOf("") }
    var legacyVideoBusy by remember { mutableStateOf(false) }
    val videoProbeScope = rememberCoroutineScope()
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
        lvJob = services.scope.launch {
            prev?.cancelAndJoin()
            frame = null
            focusValidAfter = SystemClock.elapsedRealtime()
            subjectTrackingActive = false
            liveViewStable = false
            startupEventBaselinePending = suppressStartupPropertyEvents
            var adoptedCamera = adoptActiveLiveView
            var liveViewCamera: NikonCamera? = null
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
                    liveViewCamera = cam
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
                    var firstFrameLogged = false
                    var noFrameLogged = false
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
                            if (!firstFrameLogged && !noFrameLogged &&
                                SystemClock.elapsedRealtime() - stabilizationStartedAt >= 10_000L
                            ) {
                                noFrameLogged = true
                                devLog("!! LiveView no frame for 10s after start; camera remains busy")
                            }
                            recordStartupPoll(elapsedNanos = pollElapsedNanos, busy = true)
                            if (!liveViewStable) startupBusyResponses++
                            delay(40)
                            continue
                        }
                        recordStartupPoll(elapsedNanos = pollElapsedNanos, success = true)
                        errStreak = 0
                        if (!firstFrameLogged) {
                            firstFrameLogged = true
                            devLog("LiveView first frame received after ${SystemClock.elapsedRealtime() - stabilizationStartedAt}ms")
                        }
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
                    if (isActive) {
                        runCatching { cam.labEndLiveView() }
                        subjectTrackingActive = false
                    }
                    delay(2000)
                }
            } finally {
                liveViewStable = false
                withContext(NonCancellable) {
                    runCatching { liveViewCamera?.labEndLiveView() }
                        .onSuccess { rc -> if (rc != null) devLog("EndLiveView resp=0x%04X".format(rc and 0xFFFF)) }
                        .onFailure { devLog("!! EndLiveView error=${it.javaClass.simpleName}: ${it.message}") }
                }
                subjectTrackingActive = false
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
        // 恢复分支可能已在 delay 中，必须在真正执行前再检查调试模式的所有权。
        if (cam.remoteDiagnosticControlModeSet) return
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
        if (mv != was && refreshExposureOnChange) refreshFocusMode()
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

    // 在页期间暂停后台缩略图填充：把相机通道完全让给取帧与参数加载，
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
            batteryParam = null
            return@LaunchedEffect
        }
        val sessionCamera = cameraViewModel.getCamera() ?: return@LaunchedEffect
        try {
            // 新连接不继承上一条连接的拨杆状态。首次读取失败时按照片模式处理，优先
            // 保证机身画面与快门不被错误锁进电脑控制模式。
            movieMode = false
            batteryParam = null
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
            // 进页先读一次，电量能与曝光参数一起在首帧前显示。
            refreshBattery(forceDescribe = true)
            initialLoaded = true
            startSession(hdLiveView)
            awaitCancellation()
        } finally {
            withContext(NonCancellable) {
                // 先等调试切换完成记账，防止退页清理后才迟到地开启 PC 控制。
                initialLoaded = false
                if ((sessionCamera.connectionType == CameraConnectionType.USB ||
                        sessionCamera.remoteDiagnosticControlModeSet) &&
                    sessionCamera.remoteControlModeSet
                ) {
                    // USB 录像与手动调试（含 Wi-Fi）都必须成对归还机身控制。
                    if (recording) {
                        runCatching { sessionCamera.rcEndMovie() }
                        recording = false
                    }
                    val oldLvJob = lvJob
                    oldLvJob?.cancelAndJoin()
                    if (lvJob === oldLvJob) lvJob = null
                    if (oldLvJob == null) runCatching { sessionCamera.labEndLiveView() }
                    clearAppMode(sessionCamera, force = true)
                    for (attempt in 0 until 3) {
                        val rc = runCatching {
                            sessionCamera.rcSetControlMode(false)
                        }.getOrDefault(-1)
                        devLog("control mode exit SetControlMode(0) resp=0x%04X".format(rc and 0xFFFF))
                        if (rc == Lab.OK) break
                        if (attempt < 2) delay(300L)
                    }
                    if (sessionCamera.remoteControlModeSet) {
                        devLog("!! control mode release unconfirmed; reconnect or restart camera if body remains locked")
                    }
                }
                devLog("diagnostic monitor session ended connected=$connected")
            }
        }
    }

    // 部分机身不发 BatteryLevel 变更事件：每 120s 兜底刷新。首读失败时
    // 也会重新拉取属性描述，避免进页瞬间相机忙导致整次会话一直显示未知。
    // 拍摄/录像命令期间等忙状态结束再读，不抢占实时取景的共用相机事务调度器。
    LaunchedEffect(connected, initialLoaded) {
        if (!connected || !initialLoaded) return@LaunchedEffect
        while (isActive) {
            delay(BATTERY_REFRESH_INTERVAL_MS)
            while (isActive && (!liveViewStable || capturing || recording || recBusy)) {
                delay(1_000L)
            }
            refreshBattery()
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
    // 共用相机事务调度器，多一个常驻轮询就是白占取帧通道。250ms 对水平指示足够跟手。
    // 机身不支持时停止轮询、不显示假角度，保留用户偏好供下次连接使用。
    LaunchedEffect(showLevel, connected) {
        levelRoll = null
        levelPitch = null
        if (!showLevel || !connected) return@LaunchedEffect
        while (isActive && !initialLoaded) delay(150)
        val cam = cameraViewModel.getCamera() ?: return@LaunchedEffect
        var param: RcParam? = null
        var failures = 0
        var fallbackUnavailable = false
        var source = ""
        while (isActive && cameraViewModel.getCamera() === cam) {
            val current = frame
            val attitude = current?.metadata?.attitude?.takeIf {
                SystemClock.elapsedRealtime() - current.receivedAtElapsedMs in 0L..1500L
            }
            if (attitude != null) {
                levelRoll = (attitude.roll * 10f).roundToInt() / 10f
                levelPitch = (attitude.pitch * 10f).roundToInt() / 10f
                if (source != "header") {
                    devLog("angle source=liveview compact-v1 offsets=404/(408-or-412) roll=${attitude.roll} pitch=${attitude.pitch}; property polling suspended")
                    source = "header"
                }
            } else {
                levelPitch = null
                if (source == "header") levelRoll = null
                if (source != "property") {
                    devLog("angle source=0xD067 fallback; no valid fresh dual-axis header")
                    source = "property"
                }
                if (!fallbackUnavailable) {
                    val previous = param
                    param = try {
                        if (previous == null) cam.rcGetAngleLevel() else cam.rcRefreshParam(previous)
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) { null }
                    val roll = param?.let(::rcAngleLevelRoll)
                    if (roll != null) {
                        levelRoll = (roll * 10f).roundToInt() / 10f
                        failures = 0
                    } else if (++failures >= 3) {
                        levelRoll = null
                        fallbackUnavailable = true
                        devLog("!! angle property unavailable; still watching liveview attitude")
                    }
                }
            }
            delay(250)
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
                        cam.remoteControlModeSet,
                        cam.remoteDiagnosticControlModeSet
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
            // 切换开始前已发出的事件读取也不能在模式转换中触发 USB 自动恢复。
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
                                    cam.remoteControlModeSet,
                                    cam.remoteDiagnosticControlModeSet
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
                        if (reportedProp in listOf(0x501C, 0xD05D, 0xD1F8)) {
                            focusValidAfter = SystemClock.elapsedRealtime()
                        }
                        val prop = rcCanonicalExposureProp(reportedProp)
                        if (reportedProp == Lab.PROP_BATTERY_LEVEL) refreshBattery()
                        if (reportedProp in ALL_AUTO_ISO_PROPS) refreshAutoIso()
                        // D0B5 is owned by the 500ms effective-ISO poll above. Reading it
                        // again for property events only competes with live-view frame requests.
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
                        if (prop in focusModeProperties ||
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
    // 只把最终值发给相机——逐档发送会在相机事务调度器上排队，连调十几档要追几秒。
    fun sendValue(prop: Int, value: Long, immediate: Boolean) {
        val p = params[prop] ?: return
        params[prop] = p.copy(current = value)
        services.haptics.tick()
        pendingSets[prop]?.cancel()
        val job = services.scope.launch {
            if (!immediate) delay(160)
            val cam = cameraViewModel.getCamera() ?: return@launch
            val result = try {
                cam.rcSetValueVerified(p, value)
            } catch (e: CancellationException) {
                throw e   // 被更新一步的 sendValue 顶掉，不是写失败：别记日志、别回读
            } catch (e: Exception) {
                devLog("!! shutter write prop=0x%04X error=%s: %s".format(p.prop, e.javaClass.simpleName, e.message))
                null
            }
            result?.actual?.let { params[prop] = it }
            if (prop == Lab.PROP_NK_SHUTTER || prop == Lab.PROP_NK_MOVIE_SHUTTER) {
                devLog(
                    "shutter write prop=0x%04X target=%d confirmed=%s read=%s resp=0x%04X".format(
                        p.prop, value, result?.confirmed == true,
                        result?.actual?.current?.toString() ?: "unreadable",
                        (result?.responseCode ?: -1) and 0xFFFF
                    )
                )
            }
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
        pendingSets[prop] = job
        job.invokeOnCompletion {
            if (pendingSets[prop] === job) pendingSets.remove(prop)
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
        if (capturing || cameraToolWriting) return
        val expectedCamera = cameraViewModel.getCamera() ?: return
        // 在 launch 前同步置位，消除两次快速点按同时通过 capturing=false
        // 而启动两个拍摄事务的小窗口。
        capturing = true
        services.scope.launch {
            try {
                // 快速松手时 AF 可能仍在轮询 DeviceReady。先收完对焦事务，
                // 再开始 ObjectAdded 的 12s 倒计，避免把 AF 等待时间错算进拍摄超时。
                waitForFocus?.join()
                // 等待期间若发生了断线/重连，绝不把旧手势意外发给新会话。
                if (cameraViewModel.getCamera() !== expectedCamera) return@launch
                val cam = expectedCamera
                services.haptics.longPress()   // 快门触发反馈（经全局震动设置门控）
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
    // 没有有效相机框时，短暂保留 AF 成功的操作反馈。
    // 相机帧头没有可信 AF 框时使用这里保存的应用请求点作为安全回退。
    var confirmedFocusMarker by remember { mutableStateOf<ConfirmedFocusMarker?>(null) }
    fun startFocus() {
        if (cameraToolWriting || afHeld || tapFocusBusy || focusModeManual || afJob?.isActive == true) return
        tapFocusHideJob?.cancel()
        tapFocusNonce++ // A fresh half-press must not inherit the previous tap's result colour/handoff.
        tapFocusFeedback = TapFocusFeedback.IDLE
        confirmedFocusMarker = null
        subjectTrackingActive = false
        afHeld = true
        afLocked = false
        val requestedPoint = focusAreaPoint
        services.haptics.tick()   // 开始半按的轻反馈
        afJob?.cancel()
        afJob = services.scope.launch {
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
                    if (stillHeld) services.haptics.tick()
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
            subjectTrackingActive = false
            tapFocusPoint = Offset(0.5f, 0.5f)
            focusAreaPoint = Offset(0.5f, 0.5f)
            focusModeQueried = false
            recording = false
        }
    }

    // ---------- 提示条（首次进页的一次性机身锁定提示 + 录像失败等瞬时提示）----------
    // 传输中已在照片列表侧禁止进入本页，故不再需要"传输卡顿"提示。
    // nonce 方案（与照片列表页同款）：唯一的隐藏计时器跟着 nonce 重启，连续触发时
    // 后一条重新计满时长，不会被前一条的旧计时器提前掐掉。
    var hintText by remember { mutableStateOf("") }
    var hintVisible by remember { mutableStateOf(false) }
    var hintAnchor by remember { mutableStateOf<androidx.compose.ui.geometry.Rect?>(null) }
    val hintDensity = LocalDensity.current
    var hintHostActive by remember { mutableStateOf(true) }
    DisposableEffect(Unit) {
        hintHostActive = true
        onDispose { hintHostActive = false }
    }
    var recordingErrorReport by remember { mutableStateOf("") }
    fun recordHintDiagnostic(text: String) {
        recordingErrorReport = (recordingErrorReport + "\n" + text).lines().takeLast(24).joinToString("\n")
    }
    fun updateHintAnchor(coordinates: androidx.compose.ui.layout.LayoutCoordinates) {
        val root = toolOverlayCoordinates ?: return
        if (root.isAttached && coordinates.isAttached) {
            hintAnchor = root.localBoundingBoxOf(coordinates, clipBounds = false)
        }
    }
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
    val lutState = remember {
        LutMonitorState(
            repository = LutFolderRepository(services.context.applicationContext.contentResolver) { uri ->
                val photoFolders = com.ztransfer.lut.PhotoLutStore(services.context).folders
                (photoFolders.folder == uri).also { shared -> if (shared) photoFolders.markFolderGrantOwned() }
            },
            preferences = LutPreferences(services.context.getSharedPreferences("monitor_lut", Context.MODE_PRIVATE)),
            scope = services.scope,
            closeFalseColor = {
                if (tools.exposure.value == ExposureAssist.FALSE_COLOR) tools.exposure.value = ExposureAssist.OFF
            },
            notice = { showHint(services.context.getString(it)) },
        )
    }
    var lutAnchor by remember { mutableStateOf<androidx.compose.ui.layout.LayoutCoordinates?>(null) }
    val lutLifecycle = LocalLifecycleOwner.current
    var lutResumed by remember { mutableStateOf(lutLifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    DisposableEffect(lutLifecycle, lutState) {
        val observer = LifecycleEventObserver { _, _ ->
            lutResumed = lutLifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
            if (!lutResumed) lutState.suspendRendering()
        }
        lutLifecycle.lifecycle.addObserver(observer)
        onDispose { lutLifecycle.lifecycle.removeObserver(observer) }
    }
    DisposableEffect(lutState) { onDispose { lutState.close() } }
    var lutPickerActive by remember { mutableStateOf(false) }
    var lutPickedFolder by remember { mutableStateOf<Uri?>(null) }
    val lutFolderPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        lutPickedFolder = uri
        lutPickerActive = false
    }
    // Preserve the exact gate in diagnostics instead of collapsing four causes into "disabled".
    val focusDisplayBlock = when {
        !showFocusFrame -> "tool-off"
        !tools.layout(movieMode).visible(RemoteTool.FOCUS_FRAME) -> "tool-hidden"
        !connected -> "disconnected"
        !lutResumed -> "lifecycle-${lutLifecycle.lifecycle.currentState}"
        else -> null
    }
    val lutFrameReady = connected && initialLoaded && frame != null && lutResumed && !lutPickerActive
    val lutVisible = tools.layout(movieMode).visible(RemoteTool.LUT)
    LaunchedEffect(movieMode, lutFrameReady, lutVisible, lutResumed, lutPickedFolder) {
        lutState.environment(movieMode, lutFrameReady, lutVisible)
        if (lutResumed) lutPickedFolder?.let { uri ->
            lutPickedFolder = null
            lutState.changeFolder(uri)
        }
    }
    LaunchedEffect(rotation, editingTools) { lutState.dismissMenu() }

    // Read-only metering. No camera control-mode changes or per-frame protocol work.
    val meterEnabled = showMeter && tools.layout(movieMode).visible(RemoteTool.METER)
    LaunchedEffect(meterEnabled, connected, initialLoaded, liveViewStable, lutResumed, movieMode) {
        val generation = ++meterGeneration[0]
        meterSample = null
        if (!meterEnabled || !connected || !initialLoaded || !liveViewStable || !lutResumed) return@LaunchedEffect
        val cam = cameraViewModel.getCamera() ?: return@LaunchedEffect
        fun busy() = capturing || recBusy || autoIsoBusy ||
            afHeld || tapFocusBusy || afJob?.isActive == true || pendingSets.values.any { it.isActive }
        var capability: RcParam? = null
        try {
            for (attempt in 0 until 3) {
                while (busy()) delay(250)
                capability = cam.rcGetParam(NIKON_LIGHT_METER)
                if (capability != null) break
                delay(700)
            }
            var descriptor = capability
            if (descriptor == null || descriptor.dataType != 0x0001 || descriptor.writable) {
                while (busy()) delay(250)
                descriptor = cam.rcGetParam(NIKON_EXPOSURE_INDICATE)
            }
            if (descriptor == null || descriptor.dataType != 0x0001 || descriptor.writable) {
                return@LaunchedEffect
            }
            var failures = 0
            while (isActive) {
                if (busy()) {
                    // Preserve the last indicator while camera writes temporarily pause polling.
                    meterSample = meterSample?.let { it.first to SystemClock.elapsedRealtime() }
                    delay(500)
                    continue
                }
                val startedAt = SystemClock.elapsedRealtime()
                val value = cam.rcReadExposureMeter(descriptor)
                if (!isActive || meterGeneration[0] != generation) return@LaunchedEffect
                val ev = rcExposureMeterEv(value)
                val now = SystemClock.elapsedRealtime()
                val fresh = com.ztransfer.protocol.rcExposureMeterFresh(startedAt, now) && !busy()
                if (ev != null && fresh) meterSample = ev to startedAt
                failures = if (value == null) failures + 1 else 0
                if (failures >= 3) {
                    break
                }
                delay(500)
            }
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // Unsupported/interrupted reads leave the meter unavailable, never stale.
        } finally {
            if (meterGeneration[0] == generation) meterSample = null
        }
    }
    // Briefly retain the last reading between writes/reads; disconnect and terminal failure still clear it.
    LaunchedEffect(meterSample) {
        val sample = meterSample ?: return@LaunchedEffect
        delay((3_000L - (SystemClock.elapsedRealtime() - sample.second)).coerceAtLeast(0L))
        if (meterSample == sample) meterSample = null
    }

    // ---------- 录像开关 ----------
    // 开始：命令成功即乐观置位（UI 立即变停止键），事件 0xC10A 再确认；失败弹瞬时提示。
    // 停止：只有 EndMovieRec 成功才切换 UI；失败时保留录像态，避免 UI 与相机相反。
    // recBusy 防抖：命令往返期间忽略连点。
    var recSeconds by remember { mutableIntStateOf(0) }
    val recFailHint = stringResource(R.string.remote_rec_start_failed)
    val recStopFailHint = stringResource(R.string.remote_rec_stop_failed)
    val manualFocusHint = stringResource(R.string.remote_tap_focus_manual)
    val trackingAreaModeHint = stringResource(R.string.remote_tap_focus_area_retry)
    val tapFocusFailedHint = stringResource(R.string.remote_tap_focus_retry)
    val rotationStoppedHint = stringResource(R.string.remote_rotation_stopped)
    val rotationResumedHint = stringResource(R.string.remote_rotation_resumed)

    fun focusAt(tap: ViewfinderTap) {
        if (cameraToolWriting || !connected || capturing || tapFocusBusy || afHeld || afJob?.isActive == true) return
        if (focusModeManual) {
            devLog("!! tap AF ignored: camera focus mode is MF")
            showHint(manualFocusHint)
            return
        }
        val cam = cameraViewModel.getCamera() ?: return
        tapFocusHideJob?.cancel()
        if (subjectTrackingActive) {
            // 追踪中的再次点击定义为“取消”：先驱动 UI 退场，同时独立结束机身追踪，
            // 不在同一次手势中重新选择主体。
            subjectTrackingActive = false
            tapFocusFeedback = TapFocusFeedback.IDLE
            tapFocusNonce++
            tapFocusBusy = true
            services.haptics.tick()
            devLog("subject tracking cancel requested")
            val cancelNonce = tapFocusNonce
            tapFocusHideJob = services.scope.launch {
                delay(TRACKING_CANCEL_EXIT_MS)
                if (tapFocusNonce == cancelNonce && !subjectTrackingActive) {
                    confirmedFocusMarker = null
                }
            }
            tapFocusJob = services.scope.launch {
                try {
                    val rc = cam.rcEndSubjectTracking()
                    if (
                        rc == null || rc == Lab.OK ||
                        rc == PtpConstants.OPERATION_NOT_SUPPORTED ||
                        rc == Lab.NK_INVALID_STATUS
                    ) {
                        devLog("subject tracking cancelled")
                    } else {
                        devLog("!! EndTracking resp=0x%04X".format(rc and 0xFFFF))
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    if (e is SocketTimeoutException) cameraViewModel.onCameraTransportLost(cam)
                    devLog("!! EndTracking exception: ${e.message}")
                } finally {
                    tapFocusBusy = false
                    tapFocusJob = null
                }
            }
            return
        }
        confirmedFocusMarker = null
        tapFocusPoint = tap.normalized
        tapFocusFeedback = TapFocusFeedback.FOCUSING
        tapFocusNonce++
        tapFocusBusy = true
        services.haptics.tick()
        devLog(
            "tap tracking=(${tap.trackingX},${tap.trackingY})/" +
                "${tap.trackingCoordinateWidth}x${tap.trackingCoordinateHeight} " +
                "focus=(${tap.focusX},${tap.focusY})/" +
                "${tap.focusCoordinateWidth}x${tap.focusCoordinateHeight}"
        )
        tapFocusJob = services.scope.launch {
            try {
                val result = cam.rcFocusAt(
                    trackingX = tap.trackingX,
                    trackingY = tap.trackingY,
                    focusX = tap.focusX,
                    focusY = tap.focusY
                )
                val af = result.afResult
                if (result.trackingStarted || result.moveResponseCode == Lab.OK) {
                    focusAreaPoint = tap.normalized
                }
                tapFocusFeedback = if (result.trackingStarted) {
                    subjectTrackingActive = true
                    val suffix = af?.let { "polls=${it.polls} elapsed=${it.elapsedMs}ms" }
                    if (af?.responseCode == Lab.OK) {
                        devLog("subject tracking focused ($suffix)")
                        services.haptics.tick()
                        confirmedFocusMarker = ConfirmedFocusMarker(
                            fallbackPoint = tap.normalized,
                            confirmedAtElapsedMs = SystemClock.elapsedRealtime(),
                            subjectTracking = true
                        )
                        TapFocusFeedback.LOCKED
                    } else {
                        devLog(
                            "!! subject tracking AF " +
                                if (af == null) {
                                    "unavailable"
                                } else {
                                    "result=0x%04X ($suffix)".format(
                                        af.responseCode and 0xFFFF
                                    )
                                }
                        )
                        TapFocusFeedback.FAILED
                    }
                } else if (
                    result.trackingResponseCode != null &&
                    result.trackingResponseCode != PtpConstants.OPERATION_NOT_SUPPORTED
                ) {
                    devLog(
                        "!! StartTracking resp=0x%04X".format(
                            result.trackingResponseCode and 0xFFFF
                        )
                    )
                    TapFocusFeedback.FAILED
                } else if (result.moveResponseCode == null) {
                    result.endTrackingResponseCode?.let {
                        devLog("!! EndTracking resp=0x%04X".format(it and 0xFFFF))
                    }
                    TapFocusFeedback.FAILED
                } else if (result.moveResponseCode != Lab.OK) {
                    devLog(
                        "!! ChangeAfArea resp=0x%04X".format(result.moveResponseCode and 0xFFFF)
                    )
                    TapFocusFeedback.FAILED
                } else if (af == null) {
                    devLog("!! tap AF fallback unavailable")
                    TapFocusFeedback.FAILED
                } else {
                    val suffix = "polls=${af.polls} elapsed=${af.elapsedMs}ms"
                    when {
                        af.responseCode == Lab.OK -> {
                            devLog("tap AF locked ($suffix)")
                            services.haptics.tick()
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
                if (tapFocusFeedback == TapFocusFeedback.FAILED) {
                    // Area rejection differs from an accepted AF operation that could not lock.
                    showHint(if (!result.trackingStarted && result.moveResponseCode != Lab.OK) {
                        trackingAreaModeHint
                    } else tapFocusFailedHint)
                }
                val completedNonce = tapFocusNonce
                val focusLocked = tapFocusFeedback == TapFocusFeedback.LOCKED
                val trackingStarted = result.trackingStarted
                tapFocusHideJob = services.scope.launch {
                    delay(if (focusLocked) TAP_FOCUS_LOCKED_FEEDBACK_MS else 1_300L)
                    if (tapFocusNonce == completedNonce) {
                        tapFocusFeedback = TapFocusFeedback.IDLE
                    }
                    if (focusLocked && !trackingStarted) {
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
                subjectTrackingActive = false
                devLog("!! tap AF exception: ${e.message}")
                showHint(tapFocusFailedHint)
                val completedNonce = tapFocusNonce
                tapFocusHideJob = services.scope.launch {
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
        services.haptics.tick()
        services.scope.launch {
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
        if (recBusy || cameraToolWriting) return
        val expectedCamera = cameraViewModel.getCamera() ?: return
        recBusy = true
        services.scope.launch {
            try {
                waitForFocus?.join()
                if (cameraViewModel.getCamera() !== expectedCamera) return@launch
                val cam = expectedCamera
                services.haptics.longPress()   // 与拍照同级的触发反馈（经全局震动设置门控）
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
                                cam.remoteControlModeSet,
                                cam.remoteDiagnosticControlModeSet
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
                        recordHintDiagnostic("$recFailHint\n${diagnostic.orEmpty()}")
                        showHint(recFailHint, durationMs = 12_000L)
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
                                cam.remoteControlModeSet,
                                cam.remoteDiagnosticControlModeSet
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
                        recordHintDiagnostic("$recStopFailHint\nstop=0x%04X".format(rc and 0xFFFF))
                        showHint(recStopFailHint, durationMs = 6000L)
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
    val recOutputDir = File(services.context.filesDir, "recordings")
    val recordingDesqueeze = rememberUpdatedState(desqueezeMultiplier)

    fun stopRecorder() {
        val r = viewfinderRecorder ?: return
        // 先同步置空：界面立即回到待机态，也挡住快速双击带来的二次 stop。
        viewfinderRecorder = null
        recPaused = false
        recElapsed = 0
        recJob?.cancel()
        recJob = null
        recFinalizing = true
        services.scope.launch(NonCancellable) {
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
                services.haptics.success()
                recSaveSuccess = true
                recSaveFeedbackJob = services.scope.launch {
                    delay(1_800)
                    recSaveSuccess = false
                }
            } else {
                recSaveFeedbackJob?.cancel()
                recSaveSuccess = false
                val message = services.context.getString(R.string.cd_remote_rec_toast_failed)
                if (hintHostActive) showHint(message, durationMs = 3000L)
                else Toast.makeText(services.context, message, Toast.LENGTH_SHORT).show()
                // 保存可能在退出监看后完成；此时仍需把失败告知用户。
            }
        }
    }

    // 真正开录（麦克风权限结果已知）。录像优先落到用户配置的 SAF 传输目录
    // （相册/文件管理器可见）；未配置或建档失败回退应用私有目录，录制照常。
    fun startRecorderResolved(withAudio: Boolean) {
        if (viewfinderRecorder != null || recFinalizing || !tools.layout(movieMode).visible(RemoteTool.RECORD)) return
        val f = frame
        if (f == null) {
            // 还没有取景画面（尺寸未知）就不开录，给提示而不是静默失败。
            showHint(services.context.getString(R.string.remote_rec_start_failed), durationMs = 3000L)
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
                    services.context.contentResolver, parentUri, "video/mp4", name
                )
                if (docUri != null) {
                    val pfd = services.context.contentResolver.openFileDescriptor(docUri, "rw")
                    if (pfd != null) {
                        // pfd 所有权自此归 recorder：start 失败或 stop 收尾都由它关闭。
                        sink = RecordingSink.Saf(pfd, name)
                        createdDocUri = docUri
                    } else {
                        runCatching {
                            DocumentsContract.deleteDocument(services.context.contentResolver, docUri)
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
            services.context.getSystemService(AudioManager::class.java)
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
            preferredAudioInput = builtInMic,
            desqueezeMultiplier = desqueezeMultiplier
        )
        if (!recorder.start()) {
            // 开录失败：SAF 模式下把刚建的空文档删掉，别在用户目录留 0 字节垃圾。
            createdDocUri?.let { uri ->
                runCatching { DocumentsContract.deleteDocument(services.context.contentResolver, uri) }
            }
            showHint(services.context.getString(R.string.remote_rec_start_failed), durationMs = 3000L)
            return
        }
        recSaveFeedbackJob?.cancel()
        recFinalizing = false
        recSaveSuccess = false
        viewfinderRecorder = recorder
        recPaused = false
        recElapsed = 0
        recJob = services.scope.launch(Dispatchers.Default) {
            var failStreak = 0
            // 帧驱动 VFR：同一帧只编一次（按对象身份判新），PTS 用帧的真实到达
            // 时刻——有线 ~70fps 全收，无线 ~20fps 不再重复编码同帧浪费码率。
            var lastEncoded: RemoteLiveFrame? = null
            while (isActive && recorder.isRecording) {
                val currentFrame = frame
                if (currentFrame != null && currentFrame !== lastEncoded && !recorder.isPaused) {
                    if (recorder.encodeFrame(
                            currentFrame.image,
                            currentFrame.receivedAtElapsedMs * 1_000_000L,
                            recordingDesqueeze.value
                        )
                    ) {
                        lastEncoded = currentFrame
                        failStreak = 0
                    } else if (++failStreak >= 30) {
                        // 连续编码失败时自动停录保存已有片段，避免"看着在录、
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
            showHint(services.context.getString(R.string.remote_rec_no_audio), durationMs = 3000L)
        }
        startRecorderResolved(withAudio = granted)
    }

    fun startRecorder() {
        // isPro 门控：免费版绝无可能进入录制路径（RecControlBar 已压暗 + 拦截点击，
        // 此处为防御纵深——任何跳过 UI 直调本函数的路径仍被拦截）。
        if (!isPro) {
            showHint(services.context.getString(R.string.remote_rec_pro_only))
            return
        }
        if (viewfinderRecorder != null || recFinalizing || !tools.layout(movieMode).visible(RemoteTool.RECORD)) return
        val granted = ContextCompat.checkSelfPermission(
            services.context, Manifest.permission.RECORD_AUDIO
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
    // 此时 services.scope 已随组合取消，收尾放到普通线程做（muxer 收尾不能在主线程）。
    DisposableEffect(Unit) {
        onDispose {
            recJob?.cancel()
            val r = viewfinderRecorder
            viewfinderRecorder = null
            if (r != null) Thread { runCatching { r.stop() } }.start()
        }
    }

    fun setToolVisible(tool: RemoteTool, visible: Boolean) {
        if (!visible) {
            when (tool) {
                RemoteTool.RECORD -> if (viewfinderRecorder != null) stopRecorder()
                RemoteTool.HD -> if (hdLiveView) {
                    hdLiveView = false
                    startSession(false)
                }
                RemoteTool.LOCK -> onLockRotation(false)
                RemoteTool.LUT -> { lutState.off(); lutState.dismissMenu() }
                RemoteTool.GRID -> gridPanelOpen = false
                RemoteTool.WHITE_BALANCE -> if (cameraToolPanel == RemoteCameraTool.WHITE_BALANCE) cameraToolPanel = null
                RemoteTool.FOCUS_MODE -> if (cameraToolPanel == RemoteCameraTool.FOCUS_MODE) cameraToolPanel = null
                RemoteTool.FOCUS_AREA -> if (cameraToolPanel == RemoteCameraTool.FOCUS_AREA) cameraToolPanel = null
                else -> Unit
            }
        }
        tools.layout(movieMode).setVisible(tool, visible)
    }
    var dispMode by tools.disp
    val changeToolVisibility: (RemoteTool, Boolean) -> Unit = ::setToolVisible
    ApplyRemoteToolLayout(tools.layout(movieMode), changeToolVisibility, fixedRecorder = landscapeLayout)
    val renderTool: @Composable (RemoteTool?, Int) -> Unit = { tool, labelLines ->
        if (tool == RemoteTool.RECORD) {
            RecControlBar(viewfinderRecorder != null, recPaused, recElapsed,
                { startRecorder() }, { togglePauseRecorder() }, { stopRecorder() },
                modifier = Modifier.height(36.dp), enabled = isPro,
                isFinalizing = recFinalizing, showDone = recSaveSuccess, compactSaved = landscapeLayout)
        } else {
            val active = when (tool) {
                RemoteTool.HD -> hdLiveView
                RemoteTool.FPS -> showFps
                RemoteTool.AUDIO -> showAudioLevels
                RemoteTool.HISTOGRAM -> showHistogram
                RemoteTool.LUT -> lutState.active != null
                RemoteTool.GRID -> framingGrid != ViewfinderGrid.OFF
                RemoteTool.EXPOSURE -> exposureAssist != ExposureAssist.OFF
                RemoteTool.DESQUEEZE -> desqueezeMultiplier > 1.001f
                RemoteTool.FOCUS_FRAME -> showFocusFrame
                RemoteTool.METER -> showMeter
                RemoteTool.LEVEL -> showLevel
                RemoteTool.WAVEFORM -> showWaveform
                RemoteTool.LOCK -> tools.locked.value
                else -> false
            }
            val disabled = (tool?.fixed == true && editingTools) ||
                (tool == RemoteTool.ROTATE && tools.locked.value)
            val toolClick: () -> Unit = {
                when (tool) {
                    RemoteTool.HD -> { hdLiveView = !hdLiveView; startSession(hdLiveView) }
                    RemoteTool.FPS -> toggleFpsControl()
                    RemoteTool.AUDIO -> toggleAudioLevels()
                    RemoteTool.HISTOGRAM -> histogramMode = histogramMode.next()
                    RemoteTool.LUT -> {
                        listProp = null; devPanel = false; cameraToolPanel = null; gridPanelOpen = false
                        lutState.openMenu()
                    }
                    RemoteTool.GRID -> {
                        lutState.dismissMenu()
                        listProp=null; devPanel=false; cameraToolPanel=null
                        if(gridPanelOpen) gridPanelCloseRequested=true
                        else { gridPanelCloseRequested=false; gridPanelOpen=true }
                    }
                    RemoteTool.EXPOSURE -> {
                        val next = exposureAssist.next()
                        if (next == ExposureAssist.FALSE_COLOR) lutState.falseColorEnabled()
                        exposureAssist = next
                    }
                    RemoteTool.DESQUEEZE -> {
                        val i = REMOTE_DESQUEEZE_OPTIONS.indices.minByOrNull { abs(REMOTE_DESQUEEZE_OPTIONS[it] - desqueezeMultiplier) } ?: 0
                        setDesqueezeMultiplier(REMOTE_DESQUEEZE_OPTIONS[(i + 1) % REMOTE_DESQUEEZE_OPTIONS.size])
                    }
                    RemoteTool.FOCUS_FRAME -> showFocusFrame = !showFocusFrame
                    RemoteTool.METER -> showMeter = !showMeter
                    RemoteTool.LEVEL -> showLevel = !showLevel
                    RemoteTool.WAVEFORM -> waveformMode = waveformMode.next()
                    RemoteTool.LOCK -> {
                        val locked = !tools.locked.value
                        onLockRotation(locked)
                        showHint(if (locked) rotationStoppedHint else rotationResumedHint)
                    }
                    RemoteTool.ROTATE -> if (!disabled) onCycleRotation()
                    RemoteTool.WHITE_BALANCE -> { lutState.dismissMenu(); gridPanelOpen = false; listProp = null; devPanel = false; if (cameraToolPanel == RemoteCameraTool.WHITE_BALANCE) cameraToolCloseRequested = true else { cameraToolCloseRequested = false; cameraToolPanel = RemoteCameraTool.WHITE_BALANCE } }
                    RemoteTool.FOCUS_MODE -> { lutState.dismissMenu(); gridPanelOpen = false; listProp = null; devPanel = false; if (cameraToolPanel == RemoteCameraTool.FOCUS_MODE) cameraToolCloseRequested = true else { startFocusModeReport(); cameraToolCloseRequested = false; cameraToolPanel = RemoteCameraTool.FOCUS_MODE } }
                    RemoteTool.FOCUS_AREA -> { lutState.dismissMenu(); gridPanelOpen = false; listProp = null; devPanel = false; if (cameraToolPanel == RemoteCameraTool.FOCUS_AREA) cameraToolCloseRequested = true else { cameraToolCloseRequested = false; cameraToolPanel = RemoteCameraTool.FOCUS_AREA } }
                    else -> {
                        listProp = null
                        devPanel = false
                        cameraToolPanel = null
                        onEditingTools(!editingTools)
                    }
                }
            }
            Column(
                modifier = if (labelLines > 0) Modifier.clickable(
                    enabled = !disabled, indication = null,
                    interactionSource = remember { MutableInteractionSource() }, onClick = toolClick,
                ) else Modifier,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
            TopIconToggle(active, stringResource(tool?.title ?: if (editingTools) R.string.remote_tool_done else R.string.remote_tool_manage), toolClick,
            modifier = if (tool == RemoteTool.WHITE_BALANCE) Modifier.onGloballyPositioned {
                whiteBalanceAnchor = it
            } else if (tool == RemoteTool.FOCUS_AREA) Modifier.onGloballyPositioned {
                focusAreaAnchor = it
            } else if (tool == RemoteTool.FOCUS_MODE) Modifier.size(36.dp).onGloballyPositioned {
                focusModeAnchor = it
            } else if (tool == RemoteTool.LUT) Modifier.onGloballyPositioned {
                lutAnchor = it
            } else if (tool == RemoteTool.GRID) Modifier.onGloballyPositioned {
                gridAnchor = it
            } else Modifier, enabled = !disabled) {
                if (tool == null) Icon(if (editingTools) Icons.Default.Check else Icons.Default.Settings, null, Modifier.size(19.dp))
                else if (cameraToolLoading && (
                    (tool == RemoteTool.WHITE_BALANCE && cameraToolPanel == RemoteCameraTool.WHITE_BALANCE) ||
                    (tool == RemoteTool.FOCUS_AREA && cameraToolPanel == RemoteCameraTool.FOCUS_AREA) ||
                    (tool == RemoteTool.FOCUS_MODE && cameraToolPanel == RemoteCameraTool.FOCUS_MODE))) {
                    androidx.compose.material3.CircularProgressIndicator(
                        modifier=Modifier.size(18.dp),strokeWidth=1.5.dp,color=colors.accentBlue)
                } else if (tool == RemoteTool.FOCUS_MODE) {
                    Text(if (focusModeManual) "MF" else if (focusModeText == "AF Macro") "AF-M" else focusModeText ?: "MODE", fontSize = 8.sp, maxLines = 1, softWrap = false, fontWeight = FontWeight.Bold)
                } else RemoteToolMark(tool, tools)
            }
            if (labelLines > 0 && tool != null) {
                Spacer(Modifier.height(4.dp))
                Text(
                    stringResource(tool.title), style = MonitorToolLabelStyle,
                    color = if (active) colors.accentBlue else colors.onSurfaceVariant,
                    minLines = labelLines, maxLines = labelLines,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            }
        }
    }


    val renderTools: @Composable (androidx.compose.ui.unit.Dp, Modifier) -> Unit = { gap, modifier ->
        RemoteToolBar(tools, editingTools, movieMode, changeToolVisibility,
            modifier.fillMaxWidth(), gap,
            leading = {
                if (devUnlocked && !editingTools) TopIconToggle(false, stringResource(R.string.cd_dev_panel), { devPanel = true }) {
                    Icon(Icons.Default.BugReport, null, Modifier.size(18.dp))
                }
            }, button = { renderTool(it, 0) })
    }

    // ---------- 布局 ----------
    Box(modifier = Modifier.fillMaxSize().background(rememberAppBackgroundBrush())
        .onGloballyPositioned { toolOverlayCoordinates = it }) {
        AnimatedContent(
            targetState = rotation,
            transitionSpec = {
                // The host is fully transparent while this layout switches. Keep the child swap
                // effectively immediate so rotation has one animation only: fade out, then in.
                fadeIn(tween(1)).togetherWith(fadeOut(tween(1)))
            },
            contentAlignment = Alignment.Center,
            label = "remoteLayoutOrientation",
            modifier = Modifier.fillMaxSize()
        ) { renderedRotation ->
        val landscape = renderedRotation != 0
        if (!landscape) {
        PortraitMonitorLayout(
            aspectRatio = viewfinderAspect * desqueezeMultiplier,
            modifier = Modifier
                .fillMaxSize()
                .systemBarsPadding()
                .padding(horizontal = 12.dp, vertical = 6.dp),
            header = {
            // 顶栏返回常驻；信号随其他工具淡变，监看工具统一放到取景器下方。
            Row(verticalAlignment = Alignment.CenterVertically) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    SignalPill(
                        rssi = camState.wifiRssi,
                        connected = connected,
                        connectionType = camState.presentationConnectionType,
                        staMode = camState.presentationIsSta,
                        onStaDisconnectedClick = cameraViewModel::retryStaConnection,
                    )
                    BatteryPill(percent = rcBatteryPercentage(batteryParam))
                }
                Box(Modifier.weight(1f).height(40.dp).padding(horizontal = 6.dp)
                    .onGloballyPositioned { updateHintAnchor(it) })
                GlassBackButton(
                    onClick = onNavigateBack,
                    forward = true,
                )
            }
            },
            viewfinder = {
            RemoteViewfinderPanel(
                frameProvider = { frame },
                lutState = lutState,
                grid = framingGrid,
                histogramMode = histogramMode,
                modeText = modeText,
                focusModeText = focusModeText,
                movieMode = movieMode,
                showAudioLevels = showAudioLevels,
                recording = recording,
                recSeconds = recSeconds,
                afHeld = afHeld,
                afLocked = afLocked,
                afFocusPoint = focusAreaPoint,
                tapFocusFeedback = tapFocusFeedback,
                tapFocusPoint = tapFocusPoint,
                tapFocusNonce = tapFocusNonce,
                confirmedFocusMarker = confirmedFocusMarker,
                focusDisplayBlock = focusDisplayBlock,
                focusValidAfter = focusValidAfter,
                onFocusDisplay = null,
                onTapFocus = { focusAt(it) },
                showFps = showFps,
                fps = fps,
                connected = connected,
                showZebra = showZebra,
                    showFalseColor = exposureAssist == ExposureAssist.FALSE_COLOR,
                    showWaveform = showWaveform,
                showLevel = showLevel,
                showMeter = meterEnabled,
                meterEv = meterSample?.first,
                levelRoll = levelRoll,
                levelPitch = levelPitch,
                desqueezeMultiplier = desqueezeMultiplier,
                modifier = Modifier.fillMaxSize()
            )
            },
            tools = {
            // 竖屏按实际按钮宽度换行，旋转固定在第一行右端。
            // HD/FPS 字号和录制控件宽度变化仍由同一套列轨道处理。
            renderTools(6.dp, Modifier)
            },
            parameters = {
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
                                modifier = Modifier.weight(1f).onGloballyPositioned { parameterAnchors[prop] = it },
                                onStep = { delta -> stepParam(prop, delta) },
                                onOpenList = {
                                    if (params[prop]?.values?.isNotEmpty() == true) listProp = prop
                                }
                            )
                        }
                    }
                }
            }

            },
            shutter = {
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
                    enabled = connected && !cameraToolWriting,
                    movie = movieMode,
                    recording = recording,
                    onFocusStart = { startFocus() },
                    onRelease = ::finishShutterGesture,
                    onQuickTap = {
                        if (movieMode) toggleRecord() else shoot()
                    }
                )
            }
            },
        )
        } else {
            BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
                val monitorLayout = landscapeMonitorLayout(maxWidth.value, maxHeight.value,
                    viewfinderAspect * desqueezeMultiplier)
                val imageX = monitorLayout.image.x.dp
                val imageY = monitorLayout.image.y.dp
                val imageWidth = monitorLayout.image.width.dp
                val imageHeight = monitorLayout.image.height.dp
                val landscapeShutterSize = monitorLayout.shutterSize.dp
                val landscapeMeterTop = if (movieMode) 34.dp else MonitorInfoTopInset
                val audioTop = landscapeMeterTop + if (meterEnabled) MonitorExposureMeterHeight + MonitorMeterStackGap else 0.dp
                val audioHeight = (imageHeight - audioTop - 8.dp).coerceIn(0.dp, 88.dp)

                RemoteViewfinderPanel(
                    frameProvider = { frame },
                    lutState = lutState,
                    grid = framingGrid,
                    histogramMode = histogramMode,
                    modeText = null,
                    focusModeText = null,
                    movieMode = movieMode,
                    showAudioLevels = showAudioLevels,
                    recording = recording,
                    recSeconds = recSeconds,
                    afHeld = afHeld,
                    afLocked = afLocked,
                    afFocusPoint = focusAreaPoint,
                    tapFocusFeedback = tapFocusFeedback,
                    tapFocusPoint = tapFocusPoint,
                    tapFocusNonce = tapFocusNonce,
                    confirmedFocusMarker = confirmedFocusMarker,
                focusDisplayBlock = focusDisplayBlock,
                focusValidAfter = focusValidAfter,
                onFocusDisplay = null,
                        onTapFocus = { focusAt(it) },
                    showFps = showFps,
                    fps = fps,
                    connected = connected,
                    showZebra = showZebra,
                    showFalseColor = exposureAssist == ExposureAssist.FALSE_COLOR,
                    showWaveform = showWaveform,
                    showLevel = showLevel,
                showMeter = meterEnabled,
                meterEv = meterSample?.first,
                    levelRoll = levelRoll,
                levelPitch = levelPitch,
                    showEmbeddedAudioMeter = false,
                    informationBottomInset = if (dispMode == MonitorDispMode.CAMERA && connected)
                        MonitorDispInformationInset else 0.dp,
                    // Sit directly below STBY; navigation stays outside the image.
                    meterTopInset = landscapeMeterTop,
                    desqueezeMultiplier = desqueezeMultiplier,
                    modifier = Modifier
                        .offset(x = imageX, y = imageY)
                        .size(width = imageWidth, height = imageHeight)
                )

                // Same right-edge column as the exposure meter, below its 120dp ruler.
                ViewfinderSoundMeterOverlay(
                    enabled = connected && movieMode && showAudioLevels,
                    frameProvider = { frame },
                    bottomInset = 0.dp,
                    startInset = 0.dp,
                    modifier = Modifier
                        .offset(x = imageX + imageWidth - MonitorMeterEndInset - MonitorMeterWidth, y = imageY + audioTop.coerceAtMost(imageHeight))
                        .size(width = MonitorMeterWidth, height = audioHeight)
                )


                Box(
                    Modifier.offset(x = imageX, y = imageY + imageHeight * .20f)
                        .width(imageWidth).height(40.dp).padding(horizontal = 12.dp)
                        .onGloballyPositioned { updateHintAnchor(it) },
                )

                val cameraDisp = dispMode == MonitorDispMode.CAMERA
                val detailValues = rememberMonitorDetails(
                    cameraViewModel.getCamera(), movieMode,
                    enabled = connected && initialLoaded && cameraDisp,
                    pollingAllowed = !recBusy && !capturing && !recording,
                )
                val storageValues = rememberMonitorStorage(
                    cameraViewModel.getCamera(), camState.storageIds,
                    enabled = connected && initialLoaded && cameraDisp,
                    pollingAllowed = !recBusy && !capturing && !recording,
                )
                val movieFormat = rememberMonitorMovieFormat(
                    cameraViewModel.getCamera(),
                    enabled = connected && initialLoaded && cameraDisp && movieMode,
                    pollingAllowed = lutResumed && !recBusy && !capturing && !recording,
                )
                if (cameraDisp && connected) {
                    val cells = listOfNotNull(modeText?.let { "MODE" to it }) + listOfNotNull(
                            detailValues[RemoteCameraTool.WHITE_BALANCE]?.let { "WB" to it },
                            focusModeText?.let { "AF" to it })
                    CameraMonitorDisp(cells, storageValues, movieMode,
                        rcBatteryPercentage(batteryParam), recording,
                        Modifier.offset(x = imageX, y = imageY).size(imageWidth, imageHeight),
                        storageSlotCount = camState.storageIds.filter { it != 0 && it != -1 }.distinct().size,
                        remainingVideoMs = { frame?.metadata?.remainingVideoTimeMs }, movieFormat = movieFormat)
                }
                MonitorDispSummary(
                    if (cameraDisp && connected) MonitorDispMode.CLEAN else dispMode, listOfNotNull(modeText), connected,
                    Modifier.offset(x = imageX + 8.dp, y = imageY + 9.dp)
                        .width((imageWidth - if (recording) 104.dp else 16.dp).coerceAtLeast(0.dp)),
                )
                LandscapeMonitorControls(
                    layout = monitorLayout,
                    tools = tools.layout(movieMode).shownTools.filter { it != RemoteTool.RECORD },
                    onPanelChange = {
                        gridPanelOpen = false
                        cameraToolPanel = null
                        lutState.dismissMenu()
                        listProp = null
                        devPanel = false
                    },
                    dockButton = { active, click, modifier ->
                        MonitorHeaderButton({ services.haptics.tick(); click() }, modifier.semantics { contentDescription = services.context.getString(R.string.remote_tool_dock) }, active) {
                            DockToolMark()
                        }
                    },
                    rotateButton = { renderTool(RemoteTool.ROTATE, 0) },
                    backButton = {
                        GlassBackButton(onClick = onNavigateBack, forward = true)
                    },
                    dispButton = {
                        TopIconToggle(false, "DISP", { dispMode = dispMode.next() }) {
                            Text("DISP", fontSize = 8.sp, maxLines = 1, softWrap = false)
                        }
                    },
                    shutter = {
                        ShutterButton(capturing = capturing, focusing = afHeld,
                            enabled = connected && !cameraToolWriting, movie = movieMode, recording = recording,
                            onFocusStart = { startFocus() }, onRelease = ::finishShutterGesture,
                            onQuickTap = { if (movieMode) toggleRecord() else shoot() },
                            diameter = landscapeShutterSize)
                    },
                    localRecorder = { renderTool(RemoteTool.RECORD, 0) },
                    parameter = { index, modifier ->
                        val prop = (if (movieMode) MOVIE_EXPOSURE_PROPS else EXPOSURE_PROPS)[index]
                        val isoProp = if (movieMode) Lab.PROP_NK_MOVIE_ISO else Lab.PROP_ISO
                        val hasAutoIso = prop == isoProp && autoIsoAvailable
                        ParamTile(label = paramLabel(prop), param = params[prop],
                            autoIsoEnabled = if (hasAutoIso) autoIsoEnabled else null,
                            autoIsoValue = if (hasAutoIso) effectiveAutoIsoValue else null,
                            autoIsoBusy = hasAutoIso && autoIsoBusy,
                            onAutoIsoToggle = if (hasAutoIso) ::setAutoIso else null,
                            modifier = modifier.onGloballyPositioned { parameterAnchors[prop] = it }, tileHeight = monitorLayout.parameterHeight.dp,
                            onStep = { stepParam(prop, it) },
                            onOpenList = { if (params[prop]?.values?.isNotEmpty() == true) listProp = prop })
                    },
                    tool = { entry, lines -> renderTool(entry, lines) },
                    modifier = Modifier.offset(monitorLayout.interactionBounds.x.dp, monitorLayout.interactionBounds.y.dp)
                        .size(monitorLayout.interactionBounds.width.dp, monitorLayout.interactionBounds.height.dp),
                )
            }
        }
        }

        // 免费监看余量属于整页状态，不跟随 Dock 内容切换。竖屏避开系统
        // 导航栏；横屏安全区已由外层旋转容器换算成左右 inset，无需重复留白。
        if (trialLeftSeconds != null) {
            RemoteTrialTimeBadge(
                seconds = trialLeftSeconds,
                compact = landscapeLayout,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .then(
                        if (rotation == 0) Modifier.navigationBarsPadding() else Modifier
                    )
                    .padding(
                        end = if (landscapeLayout) 6.dp else 16.dp,
                        bottom = if (landscapeLayout) 4.dp else 12.dp,
                    )
            )
        }

        listProp?.let { prop ->
            val listParam = params[prop]
            val localAnchor = toolOverlayCoordinates?.takeIf { it.isAttached }?.let { root ->
                parameterAnchors[prop]?.takeIf { it.isAttached }?.let {
                    root.localBoundingBoxOf(it, clipBounds = false)
                }
            }
            if (listParam != null) key(prop) {
                RemoteParameterPanel(listParam, localAnchor, rotation != 0,
                    onSelect = { sendValue(prop, it, immediate = true) },
                    onDismiss = { listProp = null })
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
                                services.clipboard.setText(AnnotatedString(recordingErrorReport + "\n\n" + movieFormatReport + "\n\n" + legacyVideoReport + "\n\n" + focusModeReport))
                                showHint(services.context.getString(R.string.code_copied))
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
                    GlassButton(
                        enabled = connected && !legacyVideoBusy,
                        onClick = {
                            val cam = cameraViewModel.getCamera() ?: return@GlassButton
                            legacyVideoBusy = true
                            val context = "${java.time.OffsetDateTime.now()} movie=$movieMode recording=$recording"
                            videoProbeScope.launch {
                                try {
                                    val result = cam.probeLegacyVideoTime()
                                    legacyVideoReport = (legacyVideoReport.split("\n\n").filter { it.isNotBlank() } +
                                        "$context\n$result").takeLast(4).joinToString("\n\n")
                                } catch (e: CancellationException) {
                                    throw e
                                } catch (e: Exception) {
                                    legacyVideoReport = "$context\nlegacy read failed: ${e.javaClass.simpleName}: ${e.message}"
                                } finally { legacyVideoBusy = false }
                            }
                        },
                        contentPadding = PaddingValues(8.dp)
                    ) {
                        Text(stringResource(R.string.probe_video_remaining))
                    }
                    GlassButton(
                        enabled = connected && !legacyVideoBusy,
                        onClick = {
                            val cam = cameraViewModel.getCamera() ?: return@GlassButton
                            legacyVideoBusy = true
                            val context = "${java.time.OffsetDateTime.now()} movie=$movieMode recording=$recording"
                            movieFormatReport = "Movie format: reading…"
                            videoProbeScope.launch {
                                try {
                                    movieFormatReport = "$context\n${cam.probeMovieFormat()}"
                                } catch (e: CancellationException) {
                                    throw e
                                } catch (e: Exception) {
                                    movieFormatReport = "$context\nformat read failed: ${e.javaClass.simpleName}: ${e.message}"
                                } finally { legacyVideoBusy = false }
                            }
                        },
                        contentPadding = PaddingValues(8.dp)
                    ) {
                        Text(stringResource(R.string.probe_movie_format))
                    }
                    Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState())) {
                        Spacer(Modifier.height(8.dp))
                        val logLines = (recordingErrorReport + "\n\n" + movieFormatReport + "\n\n" + legacyVideoReport + "\n\n" + focusModeReport).lines()
                        // 日志跟尾：面板刚打开（尚无布局信息）直接跳到底；此后新行到来时，
                        // 停在底部附近才跟到底，用户上翻查看时不打扰。
                        val logState = rememberLazyListState()
                        LaunchedEffect(logLines.lastOrNull()) {
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
                                    color = if ("!!" in line) colors.accentOrange
                                    else Color.White.copy(alpha = 0.76f)
                                )
                            }
                        }
                    }
                }
            }
            }
    if (lutState.menuOpen) {
        val localAnchor = toolOverlayCoordinates?.takeIf { it.isAttached }?.let { root ->
            lutAnchor?.takeIf { it.isAttached }?.let { root.localBoundingBoxOf(it, clipBounds = false) }
        }
        RemoteLutPanel(lutState, localAnchor, rotation != 0,
            onFolder = {
                lutState.prepareFolderPicker()
                lutPickerActive = true
                try {
                    lutFolderPicker.launch(lutState.folder)
                } catch (_: android.content.ActivityNotFoundException) {
                    lutPickerActive = false
                    showHint(services.context.getString(R.string.lut_folder_denied))
                } catch (_: SecurityException) {
                    lutPickerActive = false
                    showHint(services.context.getString(R.string.lut_folder_denied))
                }
            }, onFeedback = { services.haptics.tick() })
    }
    if(gridPanelOpen) {
        val localAnchor=toolOverlayCoordinates?.takeIf { it.isAttached }?.let { root ->
            gridAnchor?.takeIf { it.isAttached }?.let { root.localBoundingBoxOf(it,clipBounds=false) }
        }
        RemoteGridPanel(framingGrid,localAnchor,rotation!=0,gridPanelCloseRequested,
            onSelect={ framingGrid=it },onDismiss={gridPanelOpen=false;gridPanelCloseRequested=false})
    }
    cameraToolPanel?.let { selectedTool ->
        val panelCamera = cameraViewModel.getCamera()
        val panelMovie = movieMode
        val buttonCoordinates = when (selectedTool) {
            RemoteCameraTool.WHITE_BALANCE -> whiteBalanceAnchor
            RemoteCameraTool.FOCUS_AREA -> focusAreaAnchor
            RemoteCameraTool.FOCUS_MODE -> focusModeAnchor
        }
        val localAnchor = toolOverlayCoordinates?.takeIf { it.isAttached }?.let { root ->
            buttonCoordinates?.takeIf { it.isAttached }?.let { root.localBoundingBoxOf(it, clipBounds = false) }
        }
        key(panelCamera, movieMode, selectedTool) { RemoteCameraToolPanel(panelCamera, movieMode, selectedTool,
            closeRequested = cameraToolCloseRequested,
            onLoadingChanged = { cameraToolLoading = it },
            onWriteBusyChanged = { busy ->
                if (busy && cameraToolWriting) false
                else { cameraToolWriting = busy; true }
            },
            onUnavailable = { showHint(cameraToolUnavailableHint) },
            landscape = rotation != 0,
            anchor = localAnchor,
            canWrite = connected && initialLoaded && !capturing && !recBusy && !afHeld && !tapFocusBusy && afJob?.isActive != true,
            isCurrentCamera = { panelCamera != null && cameraViewModel.getCamera() === panelCamera && movieMode == panelMovie },
            beforeWrite = {
                if (selectedTool != RemoteCameraTool.WHITE_BALANCE && subjectTrackingActive && panelCamera != null) {
                    val rc = panelCamera.rcEndSubjectTracking()
                    devLog("focus area EndTracking resp=${rc?.let { "0x%04X".format(it and 0xFFFF) } ?: "unavailable"}")
                    if (rc != null && rc != Lab.OK && rc != PtpConstants.OPERATION_NOT_SUPPORTED && rc != Lab.NK_INVALID_STATUS) false else {
                        subjectTrackingActive = false
                        confirmedFocusMarker = null
                        true
                    }
                } else true
            },
            onApplied = {
                if (selectedTool != RemoteCameraTool.WHITE_BALANCE) {
                    tapFocusHideJob?.cancel()
                    focusValidAfter = SystemClock.elapsedRealtime()
                    confirmedFocusMarker = null
                    tapFocusFeedback = TapFocusFeedback.IDLE
                    afLocked = false
                    refreshFocusMode()
                }
            }, log = { if (selectedTool == RemoteCameraTool.FOCUS_MODE) focusModeLog(it); devLog(it) }, onDismiss = { cameraToolPanel = null; cameraToolCloseRequested = false }) }
    }
        // 独立于所有菜单开关：点按对焦失败等提示在菜单关闭时也必须显示。
        // 单一提示层位于页内菜单和日志之上；锚点只在布局变化时更新，不参与取帧。
        hintAnchor?.let { anchor ->
            Box(
                Modifier.offset { androidx.compose.ui.unit.IntOffset(anchor.left.roundToInt(), anchor.top.roundToInt()) }
                    .width(with(hintDensity) { anchor.width.toDp() })
                    .height(with(hintDensity) { anchor.height.toDp() }),
                contentAlignment = Alignment.Center,
            ) {
                MonitorHintBubble(hintVisible, hintText, compact = rotation == 0)
            }
        }
    BackHandler(enabled = editingTools) { onEditingTools(false) }
        }
    }

@Composable
private fun BatteryPill(percent: Int?) {
    val colors = AppTheme.colors
    var expanded by remember { mutableStateOf(false) }
    val level = when {
        percent == null || percent <= 0 -> 0
        percent <= 33 -> 1
        percent <= 66 -> 2
        else -> 3
    }
    val color = when {
        percent == null -> colors.onSurfaceVariant
        percent <= 20 -> colors.statusError
        percent <= 50 -> colors.accentOrange
        else -> colors.statusConnected
    }
    val skin = LocalButtonTexturePalette.current?.skin ?: SkinPreset.FROSTED_GLASS
    val dark = colors.background.luminance() < 0.5f
    val bars = remember(skin, dark, level, color, colors.onSurfaceVariant) {
        if (percent == null) {
            SignalBarPalette(
                lit = colors.onSurfaceVariant,
                unlit = colors.onSurfaceVariant.copy(alpha = 0.28f)
            )
        } else {
            signalBarPalette(
                skin = skin,
                dark = dark,
                // 木纹调色器以 4 为强、2 为中、0 为弱；电池图标本身仍画 3 格。
                level = when (level) {
                    3 -> 4
                    2 -> 2
                    else -> 0
                },
                defaultLit = color,
                defaultUnlit = colors.onSurfaceVariant.copy(alpha = 0.28f)
            )
        }
    }
    val valueText = percent?.let { "$it%" } ?: "--"
    val batteryContentDescription = "${stringResource(R.string.cd_camera_battery)} $valueText"

    GlassButton(
        onClick = { expanded = !expanded },
        shape = RoundedCornerShape(22.dp),
        // Match the 40 × 36dp back/idle queue button without an extra layout touch inset.
        contentPadding = PaddingValues(horizontal = 9.5.dp, vertical = 7.dp),
        enforceMinimumTouchTarget = false,
        modifier = Modifier
            .height(36.dp)
            .semantics {
                contentDescription = batteryContentDescription
            }
    ) {
        Row(
            modifier = Modifier.height(15.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // 收起时只留电池轮廓和 3 格电量；未知值画空格，不从其他状态反推。
            Row(
                modifier = Modifier
                    .width(21.dp)
                    .height(14.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(
                    modifier = Modifier
                        .width(18.dp)
                        .fillMaxHeight()
                        .border(1.dp, bars.lit, RoundedCornerShape(2.5.dp))
                        .padding(2.dp),
                    horizontalArrangement = Arrangement.spacedBy(1.dp)
                ) {
                    repeat(3) { index ->
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .fillMaxHeight()
                                .clip(RoundedCornerShape(1.dp))
                                .background(if (index < level) bars.lit else bars.unlit)
                        )
                    }
                }
                Box(
                    modifier = Modifier
                        .width(3.dp)
                        .height(6.dp)
                        .clip(RoundedCornerShape(topEnd = 1.5.dp, bottomEnd = 1.5.dp))
                        .background(bars.lit)
                )
            }
            // 与 SignalPill 使用同一套展开弹性和收起时序，宽度随百分比自然过渡。
            AnimatedVisibility(
                visible = expanded,
                enter = expandHorizontally(
                    animationSpec = Motion.bouncy(),
                    expandFrom = Alignment.Start
                ) + fadeIn(),
                exit = shrinkHorizontally(
                    animationSpec = tween(220, easing = FastOutSlowInEasing),
                    shrinkTowards = Alignment.Start
                ) + fadeOut(tween(160))
            ) {
                Text(
                    text = valueText,
                    style = MaterialTheme.typography.labelMedium.copy(
                        fontFeatureSettings = "tnum"
                    ),
                    fontWeight = FontWeight.Medium,
                    color = bars.lit,
                    maxLines = 1,
                    softWrap = false,
                    modifier = Modifier
                        .padding(start = 6.dp)
                        .wrapContentHeight(unbounded = true)
                )
            }
        }
    }
}

/** 免费监看余量固定在整页右下角，不占用取景器内的状态叠层空间。 */
@Composable
private fun RemoteTrialTimeBadge(
    seconds: Int,
    compact: Boolean = false,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    val safeSeconds = seconds.coerceAtLeast(0)
    val shape = RoundedCornerShape(9.dp)
    Box(
        modifier = modifier.then(
            if (compact) Modifier else Modifier
                .background(colors.glassSurfaceHeavy, shape)
                .border(1.dp, colors.glassPanelBorder, shape)
                .padding(horizontal = 10.dp, vertical = 5.dp)
        )
    ) {
        val countdown = "%d:%02d".format(safeSeconds / 60, safeSeconds % 60)
        Text(
            text = countdown,
            style = MaterialTheme.typography.labelMedium,
            color = colors.onSurfaceVariant,
            fontFamily = FontFamily.Monospace,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
            softWrap = false
        )
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
            .background(MonitorOverlayBackground, RoundedCornerShape(8.dp))
            .padding(horizontal = 7.dp, vertical = 2.dp)
    )
}

/** 包含模式徽标、录制/FPS/对焦反馈的完整取景器；帧更新仍只落在其内部。 */
@Composable
private fun RemoteViewfinderPanel(
    lutState: LutMonitorState,
    frameProvider: () -> RemoteLiveFrame?,
    grid: ViewfinderGrid,
    histogramMode: HistogramMode,
    modeText: String?,
    focusModeText: String?,
    movieMode: Boolean,
    showAudioLevels: Boolean,
    recording: Boolean,
    recSeconds: Int,
    afHeld: Boolean,
    afLocked: Boolean,
    afFocusPoint: Offset,
    tapFocusFeedback: TapFocusFeedback,
    tapFocusPoint: Offset,
    tapFocusNonce: Int,
    confirmedFocusMarker: ConfirmedFocusMarker?,
    focusDisplayBlock: String?,
    focusValidAfter: Long,
    onFocusDisplay: ((String) -> Unit)?,
    onTapFocus: (ViewfinderTap) -> Unit,
    showFps: Boolean,
    fps: Float,
    connected: Boolean,
    showZebra: Boolean = false,
    showFalseColor: Boolean = false,
    showWaveform: Boolean = false,
    showLevel: Boolean = false,
    showMeter: Boolean = false,
    meterEv: Float? = null,
    meterTopInset: Dp = if (movieMode) 34.dp else MonitorInfoTopInset,
    /** 相机机身滚转角；null=没有可用角度，水平仪什么都不画。 */
    levelRoll: Float? = null,
    levelPitch: Float? = null,
    showEmbeddedAudioMeter: Boolean = true,
    informationBottomInset: Dp = 0.dp,
    desqueezeMultiplier: Float = 1f,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    val animatedInformationInset by animateDpAsState(
        informationBottomInset, tween(180), label = "dispInformationInset")
    val recordingBorder by animateColorAsState(
        targetValue = if (connected && movieMode && recording) Color(0xFFFF424D) else Color.Transparent,
        animationSpec = tween(280),
        label = "cameraRecordingBorder",
    )
    val soundMeterEnabled = connected && movieMode && showAudioLevels
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF0D0D0D))
            .border(2.dp, recordingBorder, RoundedCornerShape(14.dp))
    ) {
        ViewfinderImage(
            lutState = lutState,
            frameProvider = frameProvider,
            grid = grid,
            histogramMode = histogramMode,
            tapFocusFeedback = tapFocusFeedback,
            tapFocusPoint = tapFocusPoint,
            tapFocusNonce = tapFocusNonce,
            afHeld = afHeld,
            afLocked = afLocked,
            afFocusPoint = afFocusPoint,
            confirmedFocusMarker = confirmedFocusMarker,
            focusDisplayBlock = focusDisplayBlock ?: if (!connected) "disconnected" else null,
            focusValidAfter = focusValidAfter,
            onFocusDisplay = onFocusDisplay,
            onTapFocus = onTapFocus,
            showZebra = showZebra,
            showFalseColor = showFalseColor,
            showWaveform = showWaveform,
            scopeStartInset = if (soundMeterEnabled && showEmbeddedAudioMeter) 48.dp else 8.dp,
            informationBottomInset = animatedInformationInset,
            scopeBottomInset = 8.dp,
            desqueezeMultiplier = desqueezeMultiplier
        )

        if (showEmbeddedAudioMeter) {
            ViewfinderSoundMeterOverlay(
                enabled = soundMeterEnabled,
                frameProvider = frameProvider,
                bottomInset = 8.dp + animatedInformationInset,
                modifier = Modifier.matchParentSize()
            )
        }

        if (showMeter) {
            ExposureMeterOverlay(meterEv, Modifier.align(Alignment.TopEnd)
                .padding(top = meterTopInset, end = MonitorMeterEndInset))
        }

        if (showLevel) {
            ViewfinderLevelOverlay(rollDegrees = levelRoll, pitchDegrees = levelPitch, modifier = Modifier.matchParentSize())
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

        if (connected && movieMode && recording) {
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
                    .background(MonitorOverlayBackground, RoundedCornerShape(8.dp))
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
                    .background(MonitorOverlayBackground, RoundedCornerShape(8.dp))
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
                    .background(MonitorOverlayBackground, RoundedCornerShape(8.dp))
                    .padding(horizontal = 12.dp, vertical = 6.dp)
            )
        }
    }
}

/**
 * 取景器内的机内双声道电平。只有本组件读取逐帧 metadata，外层页面和工具栏不会
 * 跟随 Live View 帧率重组；相机已经提供 current/peak 两组值，本地只做很短的视觉插值。
 */
@Composable
private fun ViewfinderSoundMeterOverlay(
    enabled: Boolean,
    frameProvider: () -> RemoteLiveFrame?,
    bottomInset: androidx.compose.ui.unit.Dp = 8.dp,
    startInset: androidx.compose.ui.unit.Dp = 8.dp,
    modifier: Modifier = Modifier
) {
    BoxWithConstraints(modifier) {
        val levels = if (enabled) frameProvider()?.metadata?.soundLevels else null
        // 短竖条高度封顶，避免横屏时向挖孔侧延伸。
        // 横屏由调用方限定在右侧曝光尺下方，竖屏沿用左下角位置。
        val availableHeight = (maxHeight - 16.dp).coerceAtLeast(0.dp)
        val targetMeterHeight = (maxHeight * 0.24f)
            .coerceIn(56.dp, 72.dp)
            .coerceAtMost(availableHeight)
        val meterHeight by animateDpAsState(
            targetValue = targetMeterHeight,
            animationSpec = tween(220, easing = FastOutSlowInEasing),
            label = "audioMeterHeight"
        )
        AnimatedVisibility(
            visible = levels != null,
            enter = fadeIn(tween(160, easing = FastOutSlowInEasing)) +
                scaleIn(tween(180, easing = FastOutSlowInEasing), initialScale = 0.97f),
            exit = fadeOut(tween(140, easing = FastOutSlowInEasing)),
            modifier = Modifier
                .align(Alignment.BottomStart)
                .padding(start = startInset, bottom = bottomInset)
        ) {
            StereoSoundMeter(
                levels = levels ?: LiveViewSoundLevels(0, 0, 0, 0),
                modifier = Modifier.height(meterHeight)
            )
        }
    }
}

@Composable
private fun StereoSoundMeter(
    levels: LiveViewSoundLevels,
    modifier: Modifier = Modifier
) {
    val leftLevel by animateFloatAsState(
        targetValue = levels.currentLeft.toFloat(),
        animationSpec = tween(80, easing = FastOutSlowInEasing),
        label = "audioLevelLeft"
    )
    val rightLevel by animateFloatAsState(
        targetValue = levels.currentRight.toFloat(),
        animationSpec = tween(80, easing = FastOutSlowInEasing),
        label = "audioLevelRight"
    )
    val leftPeak by animateFloatAsState(
        targetValue = levels.peakLeft.toFloat(),
        animationSpec = tween(90, easing = FastOutSlowInEasing),
        label = "audioPeakLeft"
    )
    val rightPeak by animateFloatAsState(
        targetValue = levels.peakRight.toFloat(),
        animationSpec = tween(90, easing = FastOutSlowInEasing),
        label = "audioPeakRight"
    )
    val shape = RoundedCornerShape(7.dp)
    Row(
        modifier = modifier
            .width(MonitorMeterWidth)
            .background(MonitorOverlayBackground, shape)
            .border(0.5.dp, Color.White.copy(alpha = 0.14f), shape)
            .padding(horizontal = 3.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp)
    ) {
        SoundMeterChannel(
            label = "L",
            level = { leftLevel },
            peak = { leftPeak },
            modifier = Modifier.weight(1f).fillMaxHeight()
        )
        SoundMeterChannel(
            label = "R",
            level = { rightLevel },
            peak = { rightPeak },
            modifier = Modifier.weight(1f).fillMaxHeight()
        )
    }
}

@Composable
private fun SoundMeterChannel(
    label: String,
    level: () -> Float,
    peak: () -> Float,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Canvas(Modifier.fillMaxWidth().weight(1f)) {
            // Read animation state only while drawing, avoiding per-tick layout recomposition.
            val currentLevel = level()
            val currentPeak = peak()
            val segmentCount = 15
            val gap = 1.dp.toPx()
            val segmentHeight =
                ((size.height - gap * (segmentCount - 1)) / segmentCount).coerceAtLeast(0f)
            val activeCount = (
                currentLevel.coerceIn(0f, LiveViewSoundLevels.MAX_SEGMENT.toFloat()) /
                    LiveViewSoundLevels.MAX_SEGMENT * segmentCount
                ).roundToInt().coerceIn(0, segmentCount)
            val peakIndex = if (currentPeak > 0f) {
                (
                    currentPeak.coerceIn(0f, LiveViewSoundLevels.MAX_SEGMENT.toFloat()) /
                        LiveViewSoundLevels.MAX_SEGMENT * (segmentCount - 1)
                    ).roundToInt().coerceIn(0, segmentCount - 1)
            } else {
                -1
            }
            val yellow = Color(0xFFFFC247)
            val red = Color(0xFFFF4D55)
            val radius = CornerRadius(segmentHeight / 2f, segmentHeight / 2f)
            repeat(segmentCount) { index ->
                val zoneColor = when {
                    index >= 13 -> red
                    index >= 11 -> yellow
                    else -> Color.White
                }
                val color = when {
                    index < activeCount -> zoneColor.copy(alpha = 0.94f)
                    index == peakIndex -> zoneColor.copy(alpha = 0.68f)
                    else -> Color.White.copy(alpha = 0.14f)
                }
                // index=0 从最底部开始，形成由下向上点亮的横杠堆栈。
                val y = size.height - segmentHeight - index * (segmentHeight + gap)
                drawRoundRect(
                    color = color,
                    topLeft = Offset(0f, y),
                    size = Size(size.width, segmentHeight),
                    cornerRadius = radius
                )
            }
        }
        Spacer(Modifier.height(2.dp))
        Text(
            text = label,
            color = Color.White.copy(alpha = 0.86f),
            fontSize = 7.sp,
            fontWeight = FontWeight.Bold,
            lineHeight = 7.sp,
            textAlign = TextAlign.Center,
            modifier = Modifier.width(9.dp)
        )
    }
}

/**
 * 监看画面本体。[frameProvider] 延迟到此处才读 frame state——换帧重组被限制在
 * 这个小组件内，页面其余部分（tile/快门/顶栏）不随帧率重跑。
 */
@Composable
private fun ViewfinderImage(
    lutState: LutMonitorState,
    frameProvider: () -> RemoteLiveFrame?,
    grid: ViewfinderGrid,
    histogramMode: HistogramMode,
    tapFocusFeedback: TapFocusFeedback,
    tapFocusPoint: Offset,
    tapFocusNonce: Int,
    afHeld: Boolean,
    afLocked: Boolean,
    afFocusPoint: Offset,
    confirmedFocusMarker: ConfirmedFocusMarker?,
    focusDisplayBlock: String?,
    focusValidAfter: Long,
    onFocusDisplay: ((String) -> Unit)?,
    onTapFocus: (ViewfinderTap) -> Unit,
    showZebra: Boolean,
    showFalseColor: Boolean,
    showWaveform: Boolean,
    scopeStartInset: androidx.compose.ui.unit.Dp = 8.dp,
    scopeBottomInset: Dp = 26.dp,
    informationBottomInset: Dp = 0.dp,
    desqueezeMultiplier: Float = 1f
) {
    val viewport = remember { ViewfinderViewport() }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val liveFrame = frameProvider()
        if (liveFrame != null) {
            val imageWidth = liveFrame.image.width
            val imageHeight = liveFrame.image.height
            val displayAspectRatio = imageWidth.toFloat() / imageHeight * desqueezeMultiplier
            // StartTracking 使用增强帧头 +16/+18 的完整画面坐标；普通 ChangeAfArea
            // 使用 +28/+30 的显示 AF 网格。两套坐标纵横比接近但量级完全不同，不能混用。
            val trackingCoordinateWidth =
                liveFrame.metadata?.trackingCoordinateWidth ?: imageWidth
            val trackingCoordinateHeight =
                liveFrame.metadata?.trackingCoordinateHeight ?: imageHeight
            val focusCoordinateWidth =
                liveFrame.metadata?.focusCoordinateWidth ?: imageWidth
            val focusCoordinateHeight =
                liveFrame.metadata?.focusCoordinateHeight ?: imageHeight
            val currentTapHandler by rememberUpdatedState(onTapFocus)
            ZoomableViewfinder(viewport, displayAspectRatio, Modifier.matchParentSize()) {
            Box(
                Modifier
                    .matchParentSize()
                    .pointerInput(
                        imageWidth,
                        imageHeight,
                        displayAspectRatio,
                        trackingCoordinateWidth,
                        trackingCoordinateHeight,
                        focusCoordinateWidth,
                        focusCoordinateHeight
                    ) {
                        detectTapGestures(
                            onDoubleTap = { viewport.reset() },
                            onTap = { tap ->
                            val imageRect = fitCenterRect(
                                size.width.toFloat(),
                                size.height.toFloat(),
                                displayAspectRatio
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
                                        trackingX = (
                                            normalizedX * (trackingCoordinateWidth - 1)
                                            ).roundToInt(),
                                        trackingY = (
                                            normalizedY * (trackingCoordinateHeight - 1)
                                            ).roundToInt(),
                                        trackingCoordinateWidth = trackingCoordinateWidth,
                                        trackingCoordinateHeight = trackingCoordinateHeight,
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
                        })
                    },
                contentAlignment = Alignment.Center
            ) {
                RemoteLutImage(
                    image = liveFrame.image,
                    state = lutState,
                    modifier = Modifier
                        // 与参考线共用 Fit 居中规则。尺寸动画期间也允许按高度适配，
                        // 不强制占满宽度，避免宽幅反挤压画面溢出或与网格错位。
                        .aspectRatio(displayAspectRatio)
                        .graphicsLayer {
                            // An anamorphic frame is encoded horizontally compressed. Fit it
                            // into the corrected viewport first, then restore its pixel width.
                            scaleX = desqueezeMultiplier
                        }
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
            if (showFalseColor) liveFrame.analysis?.falseColor?.let {
                FalseColorOverlay(it, displayAspectRatio, Modifier.matchParentSize())
            }
            FramingGridOverlay(
                grid = grid,
                imageAspectRatio = displayAspectRatio,
                modifier = Modifier.matchParentSize()
            )
            // 斑马纹跟随帧上的掩码走：掩码在解码线程按节流计算，这里只做裁剪绘制。
            if (showZebra) {
                ViewfinderZebraOverlay(
                    mask = liveFrame.zebraMask,
                    imageAspectRatio = displayAspectRatio,
                    modifier = Modifier.matchParentSize()
                )
            }
            val currentFrameState = rememberUpdatedState(liveFrame)
            var expiredFrameAt by remember { mutableLongStateOf(Long.MIN_VALUE) }
            LaunchedEffect(focusDisplayBlock) {
                if (focusDisplayBlock != null) return@LaunchedEffect
                while (isActive) {
                    val latest = currentFrameState.value.receivedAtElapsedMs
                    val age = SystemClock.elapsedRealtime() - latest
                    if (age >= 500L) expiredFrameAt = latest
                    delay(if (age < 500L) (500L - age).coerceAtLeast(16L) else 500L)
                }
            }
            val focusBlock = when {
                focusDisplayBlock != null -> focusDisplayBlock
                liveFrame.receivedAtElapsedMs <= focusValidAfter -> "before-mode-change"
                liveFrame.receivedAtElapsedMs <= expiredFrameAt ||
                    SystemClock.elapsedRealtime() - liveFrame.receivedAtElapsedMs >= 500L -> "stale-frame"
                liveFrame.metadata?.focusFrames.isNullOrEmpty() -> "no-box ${liveFrame.metadata?.focusFrameStatus}"
                else -> null
            }
            val cameraFocus = liveFrame.metadata?.focusFrames.takeIf { focusBlock == null }
            val marker = confirmedFocusMarker
            val fallback = marker?.takeIf {
                !it.subjectTracking && SystemClock.elapsedRealtime() - it.confirmedAtElapsedMs < TAP_FOCUS_MARKER_VISIBLE_MS
            }
            val feedback = when {
                tapFocusFeedback != TapFocusFeedback.IDLE -> tapFocusFeedback
                afHeld -> if (afLocked) TapFocusFeedback.LOCKED else TapFocusFeedback.FOCUSING
                fallback != null -> TapFocusFeedback.LOCKED
                else -> TapFocusFeedback.IDLE
            }
            FocusReticleOverlay(
                cameraFrames = cameraFocus,
                cameraFocused = liveFrame.metadata?.focusJudgement == LiveViewFocusJudgement.FOCUSED,
                allowHandoff = marker != null && liveFrame.receivedAtElapsedMs >= marker.confirmedAtElapsedMs,
                feedback = feedback,
                point = if (tapFocusFeedback != TapFocusFeedback.IDLE) tapFocusPoint
                    else if (afHeld) afFocusPoint else fallback?.fallbackPoint ?: tapFocusPoint,
                nonce = tapFocusNonce,
                imageAspectRatio = displayAspectRatio,
                zoom = viewport.scale,
                modifier = Modifier.matchParentSize(),
            )
            androidx.compose.runtime.SideEffect {
                if (focusBlock != null) onFocusDisplay?.invoke("blocked=$focusBlock age=${SystemClock.elapsedRealtime() - liveFrame.receivedAtElapsedMs}ms")
                else onFocusDisplay?.invoke("drawn boxes=${cameraFocus?.size ?: 0}")
            }
            } // Only image-space layers zoom; scopes remain anchored to the panel.
            // Stable composition keeps the outgoing scope alive for its exit animation and
            // lets a surviving waveform slide to the same left anchor used by a lone histogram.
            MonitorAnalysisOverlays(
                histogram = liveFrame.histogram.takeIf { histogramMode != HistogramMode.OFF },
                waveform = liveFrame.analysis?.waveform.takeIf { showWaveform },
                falseColor = showFalseColor, modifier = Modifier.matchParentSize().padding(bottom = informationBottomInset),
                histogramMode = histogramMode,
                waveformMode = liveFrame.analysis?.waveformMode ?: WaveformMode.LUMA,
                startInset = scopeStartInset,
                bottomInset = scopeBottomInset,
            )

        } else {
            Icon(
                Icons.Default.Videocam, contentDescription = null,
                tint = Color.White.copy(alpha = 0.18f),
                modifier = Modifier.size(44.dp)
            )
            // 首帧到达前也可预览参考线，比例与外层占位取景器及反挤压保持一致。
            FramingGridOverlay(
                grid = grid,
                imageAspectRatio = DEFAULT_VIEWFINDER_ASPECT * desqueezeMultiplier,
                modifier = Modifier.matchParentSize()
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
    onOpenList: () -> Unit,
    tileHeight: androidx.compose.ui.unit.Dp = 54.dp,
) {
    val compact = tileHeight < 44.dp
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
            .height(tileHeight)
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
                modifier = Modifier.align(Alignment.TopStart).padding(start = 10.dp, top = if (compact) 2.dp else 6.dp)
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
                modifier = Modifier.align(Alignment.TopEnd).padding(end = 8.dp, top = if (compact) 2.dp else 6.dp).size(11.dp)
            )
        }
        // 仅在可调且超过三档时提示拖动；锁定和 AUTO 接管时不显示。
        if (writable && wheelDragEnabled(values.size)) {
            WheelDragHint(
                color = colors.onSurfaceVariant.copy(alpha = 0.42f),
                modifier = Modifier.align(Alignment.CenterEnd).padding(end = 8.dp),
            )
        }
        if (autoIsoOn) {
            Text(
                autoIsoValue?.let { rcFormat(Lab.PROP_ISO, it) } ?: "—",
                color = colors.onBackground,
                fontFamily = FontFamily.Monospace,
                fontSize = if (compact) 14.sp else 16.sp,
                lineHeight = if (compact) 16.sp else 20.sp,
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
                        fontSize = if (compact) 14.sp else 16.sp,
                lineHeight = if (compact) 16.sp else 20.sp,
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
                fontSize = if (compact) 14.sp else 16.sp,
                lineHeight = if (compact) 16.sp else 20.sp,
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
    onQuickTap: () -> Unit,
    diameter: androidx.compose.ui.unit.Dp = 76.dp,
) {
    val longPressFeedback = com.ztransfer.ui.util.rememberLongPressFeedback(durationMs = 300L)
    val colors = AppTheme.colors
    var heldDown by remember { mutableStateOf(false) }
    val currentFocusStart by rememberUpdatedState(onFocusStart)
    val currentRelease by rememberUpdatedState(onRelease)
    val currentQuickTap by rememberUpdatedState(onQuickTap)
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
        targetValue = if (recording) diameter * (28f / 76f) else diameter * (60f / 76f),
        animationSpec = tween(160), label = "recInnerSize"
    )
    val innerCorner by animateDpAsState(
        targetValue = if (recording) diameter * (7f / 76f) else diameter * (30f / 76f),
        animationSpec = tween(160), label = "recInnerCorner"
    )
    Box(
        modifier = Modifier
            .size(diameter)
            .graphicsLayer {
                scaleX = pressScale
                scaleY = pressScale
            }
            .border(3.dp, ringColor, CircleShape)
            .then(
                // 照片拍摄确认中禁手势；录制中保持可用——停止靠的就是再按一下。
                if (enabled && !capturing)
                    Modifier.pointerInput(longPressFeedback) {
                        awaitEachGesture {
                            awaitFirstDown()
                            heldDown = true
                            longPressFeedback.start()
                            var timerFired = false
                            // 300ms 计时器：超时后触发半按对焦；抬起在计时结束前=快拍。
                            val timerJob = coroutineScope.launch {
                                delay(300)
                                timerFired = true
                                longPressFeedback.trigger { currentFocusStart() }
                            }
                            val up = try {
                                waitForUpOrCancellation()
                            } finally {
                                heldDown = false
                                timerJob.cancel()
                                longPressFeedback.cancel()
                            }
                            if (timerFired) {
                                // 长按：对焦已触发，抬手落点判定拍摄/取消
                                val fire = up != null &&
                                    up.position.x in 0f..size.width.toFloat() &&
                                    up.position.y in 0f..size.height.toFloat()
                                currentRelease(fire)
                            } else {
                                // 快拍：无对焦，抬手在键内直接拍摄
                                val fire = up != null &&
                                    up.position.x in 0f..size.width.toFloat() &&
                                    up.position.y in 0f..size.height.toFloat()
                                if (fire) currentQuickTap()
                            }
                        }
                    }
                else Modifier
            ),
        contentAlignment = Alignment.Center
    ) {
        if (capturing) {
            CircularProgressIndicator(
                modifier = Modifier.size(diameter * (52f / 76f)),
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

/** Focus hints stay outside the portrait image and use a translucent plate over landscape video. */
@Composable
private fun MonitorHintBubble(visible: Boolean, text: String, compact: Boolean) {
    val colors = AppTheme.colors
    AnimatedVisibility(visible, enter = fadeIn(tween(160)), exit = fadeOut(tween(200))) {
        Surface(
            shape = RoundedCornerShape(12.dp),
            color = if (compact) colors.glassSurfaceHeavy.copy(alpha = .60f) else Color.Black.copy(alpha = .42f),
            border = BorderStroke(.5.dp, if (compact) colors.glassPanelBorder else Color.White.copy(alpha = .15f)),
            modifier = Modifier.widthIn(max = 280.dp),
        ) {
            Text(text,
                color = if (compact) colors.onBackground else Color.White.copy(alpha = .95f),
                style = MaterialTheme.typography.labelMedium,
                fontSize = if (compact) 11.sp else 12.sp,
                lineHeight = if (compact) 13.sp else 16.sp,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                maxLines = 2,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = if (compact) 8.dp else 12.dp, vertical = 5.dp),
            )
        }
    }
}

/** Stable layers: packet gaps never recreate the tap animation or turn failure back into focusing. */
@Composable
private fun FocusReticleOverlay(
    cameraFrames: List<LiveViewFocusFrame>?,
    cameraFocused: Boolean,
    allowHandoff: Boolean,
    feedback: TapFocusFeedback,
    point: Offset,
    nonce: Int,
    imageAspectRatio: Float,
    zoom: Float,
    modifier: Modifier,
) {
    var handedOff by remember(nonce, feedback == TapFocusFeedback.FOCUSING) { mutableStateOf(false) }
    val handoff = feedback == TapFocusFeedback.LOCKED && allowHandoff && !cameraFrames.isNullOrEmpty()
    LaunchedEffect(handoff, nonce) {
        if (handoff) {
            delay(120) // Let the success colour settle before yielding to fresh camera geometry.
            handedOff = true
        }
    }
    val suppressCamera = feedback == TapFocusFeedback.FOCUSING || feedback == TapFocusFeedback.FAILED ||
        (feedback == TapFocusFeedback.LOCKED && !handedOff)
    val cameraVisible = !suppressCamera && !cameraFrames.isNullOrEmpty()
    val tapVisible = feedback != TapFocusFeedback.IDLE && !handedOff
    var lastFrames by remember { mutableStateOf(emptyList<LiveViewFocusFrame>()) }
    var lastFocused by remember { mutableStateOf(false) }
    SideEffect {
        if (!cameraFrames.isNullOrEmpty()) {
            lastFrames = cameraFrames
            lastFocused = cameraFocused
        }
    }
    val cameraAlpha = animateFloatAsState(if (cameraVisible) 1f else 0f, tween(160), label = "cameraAfAlpha")
    val tapAlpha = animateFloatAsState(if (tapVisible) 1f else 0f, tween(160), label = "tapAfAlpha")
    val appearScale = remember { Animatable(1f) }
    LaunchedEffect(nonce, feedback == TapFocusFeedback.FOCUSING) {
        if (feedback == TapFocusFeedback.FOCUSING) {
            appearScale.snapTo(1.12f)
        }
        appearScale.animateTo(1f, tween(180, easing = FastOutSlowInEasing))
    }
    // Keep the outgoing result's colour while fading; IDLE must not flash white.
    var lastFeedback by remember { mutableStateOf(TapFocusFeedback.FOCUSING) }
    var lastPoint by remember { mutableStateOf(point) }
    SideEffect {
        if (feedback != TapFocusFeedback.IDLE) {
            lastFeedback = feedback
            lastPoint = point
        }
    }
    val displayPoint = if (feedback == TapFocusFeedback.IDLE) lastPoint else point
    val effectiveFeedback = if (feedback == TapFocusFeedback.IDLE) lastFeedback else feedback
    val tapColor = key(nonce) {
        // New requests start neutral rather than briefly inheriting the previous red/green.
        animateColorAsState(when (effectiveFeedback) {
            TapFocusFeedback.LOCKED -> Color(0xFF67E58B)
            TapFocusFeedback.FAILED -> Color(0xFFFF7777)
            else -> Color.White
        }, tween(150), label = "tapAfColor")
    }
    val cameraColor = animateColorAsState(
        if (lastFrames.size > 1) Color(0xFFFFDEA0) else if (lastFocused) Color(0xFF67E58B) else Color.White,
        tween(150), label = "cameraAfColor")
    val outline = remember { androidx.compose.ui.graphics.Path() }
    Canvas(modifier) {
        val image = fitCenterRect(size.width, size.height, imageAspectRatio)
        if (image.width <= 0f || image.height <= 0f) return@Canvas
        val scale = zoom.coerceAtLeast(1f)
        fun corners(center: Offset, halfWidth: Float, halfHeight: Float) {
            val arm = minOf(5.dp.toPx() / scale, halfWidth * .65f, halfHeight * .65f)
            val radius = minOf(1.4.dp.toPx() / scale, arm * .45f)
            for (xSign in -1..1 step 2) for (ySign in -1..1 step 2) {
                val x = center.x + xSign * halfWidth
                val y = center.y + ySign * halfHeight
                outline.moveTo(x - xSign * arm, y)
                outline.lineTo(x - xSign * radius, y)
                outline.quadraticBezierTo(x, y, x, y - ySign * radius)
                outline.lineTo(x, y - ySign * arm)
            }
        }
        fun paint(color: Color, alpha: Float) {
            drawPath(outline, Color.Black.copy(alpha = .24f * alpha),
                style = androidx.compose.ui.graphics.drawscope.Stroke(2.1.dp.toPx() / scale, cap = StrokeCap.Round))
            drawPath(outline, color.copy(alpha = .94f * alpha),
                style = androidx.compose.ui.graphics.drawscope.Stroke(1.15.dp.toPx() / scale, cap = StrokeCap.Round))
        }
        if (cameraAlpha.value > 0f) {
            outline.reset()
            for (frame in cameraFrames ?: lastFrames) {
                corners(Offset(image.left + image.width * frame.centerX, image.top + image.height * frame.centerY),
                    image.width * frame.width / 2f, image.height * frame.height / 2f)
            }
            paint(cameraColor.value, cameraAlpha.value)
        }
        if (tapAlpha.value > 0f) {
            outline.reset()
            val half = minOf(22.dp.toPx() / scale * appearScale.value, image.width / 2f, image.height / 2f)
            // Reserve the largest entrance footprint: shrinking must not slide edge taps sideways.
            val inset = minOf(22.dp.toPx() / scale * 1.12f, image.width / 2f, image.height / 2f)
            val center = Offset(
                (image.left + image.width * displayPoint.x).coerceIn(image.left + inset, image.right - inset),
                (image.top + image.height * displayPoint.y).coerceIn(image.top + inset, image.bottom - inset))
            corners(center, half, half)
            paint(tapColor.value, tapAlpha.value)
        }
    }
}

/** Shared column tracks distribute spare width evenly and align all toolbar rows. */
@Composable
internal fun AdaptiveRemoteToolBar(
    modifier: Modifier = Modifier,
    horizontalGap: androidx.compose.ui.unit.Dp = 6.dp,
    verticalGap: androidx.compose.ui.unit.Dp = 4.dp,
    pinnedEndCount: Int = 0,
    secondRowFirstId: String? = null,
    content: @Composable () -> Unit
) {
    Layout(modifier = modifier, content = content) { measurables, constraints ->
        val gapPx = horizontalGap.roundToPx()
        val rowGapPx = verticalGap.roundToPx()
        val maxWidth = constraints.maxWidth
        val placeables = measurables.map { it.measure(Constraints()) }
        val regularEnd = placeables.size - pinnedEndCount.coerceIn(0, placeables.size)
        val visibleIndices = placeables.indices.filter { placeables[it].width > 0 && placeables[it].height > 0 }
        val regular = visibleIndices.filter { it < regularEnd }.toMutableList()
        val pinned = visibleIndices.filter { it >= regularEnd }
        // Wide recording capsules and enlarged text occupy whole columns, without shrinking.
        // Text tools can be a little wider than icon tools (font scale / fractional density).
        // Using the narrowest button made HD/FPS occupy two tracks and left alternating holes.
        // Only the recording capsule is intentionally multi-column.
        val cellWidth = maxOf(
            36.dp.roundToPx(),
            visibleIndices.filter { measurables[it].layoutId != RemoteTool.RECORD.id }
                .maxOfOrNull { placeables[it].width } ?: 0,
        )
        val capacity = ((maxWidth + gapPx) / (cellWidth + gapPx)).coerceAtLeast(1)
        fun span(index: Int) = ((placeables[index].width + gapPx + cellWidth + gapPx - 1) /
            (cellWidth + gapPx)).coerceIn(1, capacity)
        // Keep the full set of column tracks even when most tools are hidden.
        // Otherwise three remaining buttons spread across the row and put full screen
        // in its center instead of beside rotation at the trailing edge.
        val columns = capacity
        val pitch = if (columns > 1) ((maxWidth - cellWidth).toFloat() / (columns - 1)) else 0f
        val pinnedSpans = pinned.sumOf(::span)
        val firstCapacity = (columns - pinnedSpans).coerceAtLeast(0)
        val defaultLock = regular.firstOrNull { secondRowFirstId != null && measurables[it].layoutId == secondRowFirstId }
        // If visible tools fit on the first row, leave the lock in their normal sequence;
        // never put hidden tools ahead of it just to force the default second-row position.
        val rowTwoLock = defaultLock?.takeIf { regular.takeWhile { index -> index != it }.sumOf(::span) >= firstCapacity }
        if (rowTwoLock != null) regular.remove(rowTwoLock)
        val rows = mutableListOf<MutableList<Pair<Int, Int>>>(mutableListOf())
        var next = 0
        var used = 0
        while (next < regular.size && used + span(regular[next]) <= firstCapacity) {
            val index = regular[next++]
            rows[0] += index to used
            used += span(index)
        }
        var pinnedColumn = (columns - pinnedSpans).coerceAtLeast(0)
        pinned.forEach { index -> rows[0] += index to pinnedColumn; pinnedColumn += span(index) }
        val remaining = (if (rowTwoLock != null) listOf(rowTwoLock) else emptyList()) + regular.drop(next)
        var row: MutableList<Pair<Int, Int>>? = null
        used = columns
        for (index in remaining) {
            val size = span(index)
            if (row == null || used + size > columns) {
                row = mutableListOf()
                rows += row
                used = 0
            }
            row += index to used
            used += size
        }
        val rowHeights = rows.map { r -> r.maxOfOrNull { placeables[it.first].height } ?: 0 }
        val naturalHeight = rowHeights.sum() + rowGapPx * (rows.size - 1).coerceAtLeast(0)
        layout(maxWidth, naturalHeight.coerceIn(constraints.minHeight, constraints.maxHeight)) {
            var y = 0
            rows.forEachIndexed { rowIndex, items ->
                items.forEach { (index, column) ->
                    val item = placeables[index]
                    val slotWidth = cellWidth + (span(index) - 1) * pitch
                    val x = (column * pitch + (slotWidth - item.width) / 2).roundToInt().coerceAtLeast(0)
                    item.placeRelative(x, y + (rowHeights[rowIndex] - item.height) / 2)
                }
                y += rowHeights[rowIndex] + rowGapPx
            }
        }
    }
}

/** 棋子式圆润工具按钮：沿用主题材质，以低矮弧面表达微凸。 */
/** Shared portrait/landscape navigation style. */
@Composable
private fun MonitorHeaderButton(onClick: () -> Unit, modifier: Modifier = Modifier,
    active: Boolean = false, content: @Composable () -> Unit) {
    val colors = AppTheme.colors
    GlassButton(onClick = onClick, active = active, shape = RoundedCornerShape(22.dp),
        showSheen = false, contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
        modifier = modifier.size(width = 42.dp, height = 36.dp)) {
        CompositionLocalProvider(LocalContentColor provides if (active) colors.accentBlue else colors.onBackground) {
            content()
        }
    }
}

@Composable
internal fun TopIconToggle(
    active: Boolean,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable () -> Unit
) {
    val colors = AppTheme.colors
    val skin = LocalButtonTexturePalette.current?.skin ?: SkinPreset.FROSTED_GLASS
    val dark = colors.background.luminance() < 0.5f
    // Solid materials redraw the icon; pass the same tint to both drawing layers.
    val inactiveColor = when (skin) {
        SkinPreset.TITANIUM -> if (dark) Color(0xFFE4ECEF) else Color(0xFF344149)
        SkinPreset.WOOD -> if (dark) Color(0xFFF1D6A7) else Color(0xFF472A18)
        SkinPreset.CAMERA_CONTROLS -> Color(0xFFD5D8DA)
        SkinPreset.FROSTED_GLASS -> colors.onSurfaceVariant
    }
    val activeColor = when (skin) {
        SkinPreset.TITANIUM, SkinPreset.WOOD ->
            if (dark) Color(0xFF80D8FF) else Color(0xFF005B83)
        SkinPreset.CAMERA_CONTROLS -> Color(0xFF80D8FF)
        SkinPreset.FROSTED_GLASS -> colors.accentBlue
    }
    val markColor by animateColorAsState(
        if (active) activeColor else inactiveColor,
        animationSpec = tween(180), label = "monitorToolTint"
    )
    GlassButton(
        onClick = onClick,
        enabled = enabled,
        active = active,
        activeOutline = true,
        materialContentColor = markColor,
        shape = CircleShape,
        raised = true,
        showSheen = true,
        enforceMinimumTouchTarget = false,
        contentPadding = PaddingValues(8.dp),
        modifier = modifier
            .defaultMinSize(minWidth = 36.dp, minHeight = 36.dp)
            .semantics { this.contentDescription = contentDescription }
    ) {
        CompositionLocalProvider(
            LocalContentColor provides markColor
        ) {
            Box(
                modifier = Modifier.defaultMinSize(minWidth = 20.dp, minHeight = 20.dp),
                contentAlignment = Alignment.Center
            ) { content() }
        }
    }
}


/** Four rounded tiles distinguish the landscape tool drawer from portrait editing. */
@Composable
private fun DockToolMark() {
    val color = LocalContentColor.current
    Canvas(Modifier.size(19.dp)) {
        val stroke = 1.6.dp.toPx()
        val inset = stroke / 2f
        val gap = 3.dp.toPx()
        val tile = (size.width - stroke - gap) / 2f
        for (row in 0..1) for (column in 0..1) {
            drawRoundRect(
                color = color,
                topLeft = Offset(inset + column * (tile + gap), inset + row * (tile + gap)),
                size = androidx.compose.ui.geometry.Size(tile, tile),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(1.5.dp.toPx()),
                style = androidx.compose.ui.graphics.drawscope.Stroke(stroke),
            )
        }
    }
}

/** Shared by the actual toolbar and its manager; there is no second icon set. */
@Composable
internal fun RemoteToolMark(tool: RemoteTool, preferences: RemoteToolPreferences) {
    val mark = Modifier.size(19.dp)
    when (tool) {
        RemoteTool.LUT -> Text("LUT", fontSize = 10.sp, fontWeight = FontWeight.Bold)
        RemoteTool.HD -> HdMark()
        RemoteTool.FPS -> FpsMark()
        RemoteTool.AUDIO -> Icon(Icons.Default.VolumeUp, null, mark)
        RemoteTool.HISTOGRAM -> HistogramMark(mark, rgb = preferences.histogram.value == HistogramMode.RGB)
        RemoteTool.GRID -> GridMark(preferences.grid.value.takeUnless { it == ViewfinderGrid.OFF } ?: ViewfinderGrid.THIRDS, mark)
        RemoteTool.EXPOSURE -> if (preferences.exposure.value == ExposureAssist.FALSE_COLOR) FalseColorMark(mark) else ZebraMark(mark)
        RemoteTool.DESQUEEZE -> if (preferences.desqueeze.value > 1.001f) {
            Text(desqueezeDisplayValue(preferences.desqueeze.value), fontSize = 12.sp, fontWeight = FontWeight.Bold)
        } else Icon(Icons.Outlined.AspectRatio, null, mark)
        RemoteTool.METER -> Text("±EV", fontSize = 10.sp, fontWeight = FontWeight.Bold)
        RemoteTool.LEVEL -> LevelMark(mark)
        RemoteTool.RECORD -> Icon(Icons.Default.Videocam, null, mark)
        RemoteTool.ROTATE -> RotateMark(mark)
        RemoteTool.LOCK -> Icon(if (preferences.locked.value) Icons.Default.Lock else Icons.Default.LockOpen, null, mark)
        RemoteTool.WHITE_BALANCE -> Text("WB", fontSize = 11.sp, fontWeight = FontWeight.Bold)
        RemoteTool.FOCUS_MODE -> Text("MODE", fontSize = 9.sp, fontWeight = FontWeight.Bold)
        RemoteTool.FOCUS_FRAME -> FocusFrameMark()
        RemoteTool.FOCUS_AREA -> Icon(Icons.Default.CenterFocusStrong, null, mark)
        RemoteTool.WAVEFORM -> WaveformMark(mark, rgb = preferences.waveform.value == WaveformMode.RGB)
    }
}

/** AF inside a focus rectangle, shared by the toolbar and edit mode. */
@Composable
private fun FocusFrameMark() {
    Box(
        modifier = Modifier.size(width = 20.dp, height = 18.dp)
            .border(1.4.dp, LocalContentColor.current, RoundedCornerShape(3.dp)),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            "AF", fontSize = 8.sp, lineHeight = 10.sp, fontWeight = FontWeight.Bold,
            maxLines = 1, softWrap = false,
            style = androidx.compose.ui.text.TextStyle(
                platformStyle = androidx.compose.ui.text.PlatformTextStyle(includeFontPadding = false)
            ),
        )
    }
}
