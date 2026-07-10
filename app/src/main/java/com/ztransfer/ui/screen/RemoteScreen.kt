package com.ztransfer.ui.screen

import android.content.Context
import android.graphics.BitmapFactory
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.keyframes
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ztransfer.R
import com.ztransfer.protocol.Lab
import com.ztransfer.protocol.RcParam
import com.ztransfer.protocol.labEndLiveView
import com.ztransfer.protocol.labGrabFrame
import com.ztransfer.protocol.labStartLiveView
import com.ztransfer.protocol.rcAfDrive
import com.ztransfer.protocol.rcCapture
import com.ztransfer.protocol.rcChangeAfArea
import com.ztransfer.protocol.rcFormat
import com.ztransfer.protocol.rcGetParam
import com.ztransfer.protocol.rcModelName
import com.ztransfer.protocol.rcPollEvents
import com.ztransfer.protocol.rcSetLvSize
import com.ztransfer.protocol.rcSetValue
import com.ztransfer.protocol.runLabProbe
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.DarkAppColors
import com.ztransfer.ui.theme.LocalAppColors
import com.ztransfer.ui.util.Haptics
import com.ztransfer.ui.util.rememberHaptics
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferViewModel
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

// 读数条/拨轮覆盖的四个曝光参数（顺序即读数条顺序）
private val EXPOSURE_PROPS = listOf(
    Lab.PROP_NK_SHUTTER, Lab.PROP_F_NUMBER, Lab.PROP_ISO, Lab.PROP_EXP_COMPENSATION
)
private val WHEEL_ITEM_WIDTH = 84.dp

/**
 * 无线遥控页（正式功能）：取景器隐喻，恒黑底不随主题——通过覆盖 [LocalAppColors]
 * 让页内所有玻璃组件走深色 token（与 PhotoPreview 恒黑同理，但组件无需特判）。
 *
 * 布局：顶栏（返回/机型名/连接点）→ 监看画面（点击=触摸对焦）→ 曝光读数条
 * （点谁调谁）→ 吸附拨轮（值域来自相机枚举，RO 置灰+锁+抖动）→ 快门键 + 最近一张。
 * 进页自动开监看、退页自动关；拍摄结果仅回显不入队（下载走照片列表）。
 * 开发者面板：连点机型名 3 次呼出（探测/日志/XGA/帧率）。
 */
@Composable
fun RemoteScreen(
    cameraViewModel: CameraViewModel,
    transferViewModel: TransferViewModel,
    onNavigateBack: () -> Unit
) {
    CompositionLocalProvider(LocalAppColors provides DarkAppColors) {
        RemoteContent(cameraViewModel, transferViewModel, onNavigateBack)
    }
}

@Composable
private fun RemoteContent(
    cameraViewModel: CameraViewModel,
    transferViewModel: TransferViewModel,
    onNavigateBack: () -> Unit
) {
    val colors = AppTheme.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current
    val camState by cameraViewModel.state.collectAsState()
    val transferState by transferViewModel.state.collectAsState()
    val haptics = rememberHaptics(transferState.hapticsEnabled)
    val connected = camState.isConnectedToCamera

    // ---------- 会话状态 ----------
    var frame by remember { mutableStateOf<ImageBitmap?>(null) }
    var fps by remember { mutableStateOf(0f) }
    var capturing by remember { mutableStateOf(false) }
    var lastShot by remember { mutableStateOf<ImageBitmap?>(null) }
    var showLastShotLarge by remember { mutableStateOf(false) }
    var modelName by remember { mutableStateOf<String?>(null) }
    var modeText by remember { mutableStateOf<String?>(null) }
    val params = remember { mutableStateMapOf<Int, RcParam>() }
    var selectedProp by remember { mutableStateOf(Lab.PROP_NK_SHUTTER) }

    // ---------- 开发者面板 ----------
    val logLines = remember { mutableStateListOf<String>() }
    var devPanel by remember { mutableStateOf(false) }
    var devFps by remember { mutableStateOf(false) }
    var hdLiveView by remember { mutableStateOf(false) }
    var probing by remember { mutableStateOf(false) }
    fun devLog(line: String) {
        logLines.add(line)
        if (logLines.size > 300) logLines.removeAt(0)
    }

    // 事件总线：单一轮询协程独占 GetEvent（事件是取走即消费的，多处轮询会互相偷事件），
    // 拍摄流程从这里等 ObjectAdded。
    val eventFlow = remember { MutableSharedFlow<Pair<Int, Long>>(extraBufferCapacity = 32) }

    suspend fun decode(bytes: ByteArray): ImageBitmap? = withContext(Dispatchers.Default) {
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
    }

    suspend fun refreshParam(prop: Int) {
        val cam = cameraViewModel.getCamera() ?: return
        runCatching { cam.rcGetParam(prop) }.getOrNull()?.let { params[prop] = it }
    }

    suspend fun refreshMode() {
        val cam = cameraViewModel.getCamera() ?: return
        runCatching { cam.rcGetParam(Lab.PROP_EXPOSURE_PROGRAM) }.getOrNull()?.let {
            modeText = rcFormat(Lab.PROP_EXPOSURE_PROGRAM, it.current)
        }
    }

    // ---------- Live View 会话 ----------
    // 手动管理 + 新任务先 join 旧任务：保证"旧会话的 EndLiveView 一定先于新会话的
    // StartLiveView"（LaunchedEffect 换 key 的取消是异步的，直接依赖它会时序穿插）。
    // 会话在页面存续期内【永不放弃】：断流退避重启、断线后等重连自动换新连接续播——
    // 持续取帧本身就是相机的保活信号，会话若静默死掉，相机空闲片刻就按待机计时器休眠。
    var lvJob by remember { mutableStateOf<Job?>(null) }
    fun startSession(hd: Boolean) {
        val prev = lvJob
        lvJob = scope.launch {
            prev?.cancelAndJoin()
            try {
                while (isActive) {
                    // 每轮现取相机实例：断线重连后拿到的是新连接，旧会话自然淘汰
                    val cam = cameraViewModel.getCamera()
                    if (cam == null) { delay(2000); continue }
                    // LV 分辨率须在 LV 关闭时设置
                    runCatching { cam.rcSetLvSize(if (hd) 3 else 2) }
                    val started = runCatching { cam.labStartLiveView { devLog(it) } }
                        .getOrDefault(false)
                    if (!started) { delay(3000); continue }
                    var frames = 0
                    var windowStart = System.currentTimeMillis()
                    var errStreak = 0
                    while (isActive) {
                        val grabbed = try {
                            cam.labGrabFrame()
                        } catch (e: Exception) {
                            // 非忙失败（掉出 LV / 连接异常）：退避后回外层整体重启
                            errStreak++
                            devLog("!! LV: ${e.message}")
                            if (errStreak >= 3) break
                            delay(300)
                            continue
                        }
                        if (grabbed == null) { delay(40); continue }
                        errStreak = 0
                        decode(grabbed.first)?.let { frame = it }
                        frames++
                        val now = System.currentTimeMillis()
                        if (now - windowStart >= 1000) {
                            fps = frames * 1000f / (now - windowStart)
                            frames = 0
                            windowStart = now
                        }
                    }
                    delay(2000)
                }
            } finally {
                withContext(NonCancellable) {
                    runCatching { cameraViewModel.getCamera()?.labEndLiveView() }
                }
            }
        }
    }

    // 在页期间暂停后台缩略图填充：把 ioMutex 完全让给取帧与参数加载，
    // 否则每条启动命令都排在 GetThumb 后面，进页要等好几秒。退出自动恢复。
    DisposableEffect(Unit) {
        cameraViewModel.setRemoteActive(true)
        onDispose { cameraViewModel.setRemoteActive(false) }
    }

    // 进页/重连：画面最优先——立即启动监看会话；参数与型号并行加载，
    // 在帧间隙穿插完成（读数条随加载逐个点亮）。
    LaunchedEffect(connected) {
        if (!connected) return@LaunchedEffect
        startSession(hdLiveView)
        launch {
            EXPOSURE_PROPS.forEach { refreshParam(it) }
            refreshMode()
            if (modelName == null) {
                modelName = runCatching { cameraViewModel.getCamera()?.rcModelName() }.getOrNull()
            }
        }
    }

    // 事件轮询：唯一的 GetEvent 消费者。参数被机身侧改动（0x4006）时刷新对应值域。
    LaunchedEffect(Unit) {
        while (isActive) {
            val cam = cameraViewModel.getCamera()
            if (cam == null) { delay(1500); continue }
            val events = runCatching { cam.rcPollEvents() }.getOrDefault(emptyList())
            for (e in events) {
                eventFlow.emit(e)
                if (e.first == Lab.EVT_DEVICE_PROP_CHANGED) {
                    val prop = e.second.toInt()
                    if (prop in EXPOSURE_PROPS) refreshParam(prop)
                    if (prop == Lab.PROP_EXPOSURE_PROGRAM) {
                        refreshMode()
                        // 曝光模式变化会连带改变各参数的可写性/值域
                        EXPOSURE_PROPS.forEach { refreshParam(it) }
                    }
                }
            }
            delay(600)
        }
    }

    // ---------- 动作 ----------
    fun commitValue(p: RcParam, value: Long) {
        val cam = cameraViewModel.getCamera() ?: return
        scope.launch {
            val rc = runCatching { cam.rcSetValue(p, value) }.getOrDefault(-1)
            if (rc == Lab.OK) {
                params[p.prop] = p.copy(current = value)
                haptics.tick()
            } else {
                devLog("!! set 0x%04X resp=0x%04X".format(p.prop, rc and 0xFFFF))
                refreshParam(p.prop)   // 写失败刷回真实值，拨轮自动弹回
            }
        }
    }

    fun shoot() {
        if (capturing) return
        val cam = cameraViewModel.getCamera() ?: return
        scope.launch {
            capturing = true
            haptics.longPress()
            try {
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
                val handle = pending.await()
                if (handle == null) {
                    devLog("!! capture: no ObjectAdded in 12s")
                    return@launch
                }
                devLog("shot: handle=0x%08X".format(handle))
                runCatching { cam.getThumbnail(handle) }.getOrNull()
                    ?.let { decode(it) }
                    ?.let { lastShot = it }
            } finally {
                capturing = false
            }
        }
    }

    // 触摸对焦：容器坐标 → ContentScale.Fit 反算 → LV 图像像素坐标
    var viewSize by remember { mutableStateOf(IntSize.Zero) }
    var focusPos by remember { mutableStateOf<Offset?>(null) }
    var focusNonce by remember { mutableStateOf(0) }
    LaunchedEffect(focusNonce) {
        if (focusPos != null) { delay(900); focusPos = null }
    }
    var afBusy by remember { mutableStateOf(false) }
    fun tapToFocus(pos: Offset) {
        if (afBusy) return
        val bmp = frame ?: return
        val cam = cameraViewModel.getCamera() ?: return
        val cw = viewSize.width.toFloat()
        val ch = viewSize.height.toFloat()
        if (cw <= 0f || ch <= 0f) return
        val scale = minOf(cw / bmp.width, ch / bmp.height)
        val bx = ((pos.x - (cw - bmp.width * scale) / 2f) / scale).roundToInt()
        val by = ((pos.y - (ch - bmp.height * scale) / 2f) / scale).roundToInt()
        if (bx !in 0 until bmp.width || by !in 0 until bmp.height) return
        focusPos = pos
        focusNonce++
        haptics.tick()
        scope.launch {
            afBusy = true
            try {
                val rc = runCatching { cam.rcChangeAfArea(bx, by) }.getOrDefault(-1)
                devLog("AF area ($bx,$by) resp=0x%04X".format(rc and 0xFFFF))
                // 移点只是选点，不驱动对焦；补一发 AfDrive 真正合焦
                //（阻塞至合焦/失败，期间 LV 暂停一下属正常；0xA002=对不上焦）。
                val drive = runCatching { cam.rcAfDrive() }.getOrDefault(-1)
                devLog("AF drive resp=0x%04X".format(drive and 0xFFFF))
            } finally {
                afBusy = false
            }
        }
    }

    fun runProbe() {
        if (probing) return
        val cam = cameraViewModel.getCamera() ?: return
        scope.launch {
            probing = true
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

    // 开发者面板入口：连点机型名 3 次
    var titleTaps by remember { mutableStateOf(0) }
    var lastTitleTap by remember { mutableStateOf(0L) }
    fun onTitleTap() {
        val now = System.currentTimeMillis()
        titleTaps = if (now - lastTitleTap < 1200) titleTaps + 1 else 1
        lastTitleTap = now
        if (titleTaps >= 3) {
            titleTaps = 0
            devPanel = true
        }
    }

    // ---------- 提示条（一次性机身锁定提示 / 传输中卡顿提示）----------
    var hintText by remember { mutableStateOf("") }
    var hintVisible by remember { mutableStateOf(false) }
    val lockedHint = stringResource(R.string.remote_locked_hint)
    val busyHint = stringResource(R.string.remote_transfer_busy_hint)
    LaunchedEffect(Unit) {
        val prefs = context.getSharedPreferences("remote_page", Context.MODE_PRIVATE)
        val transfersBusy = transferState.tasks.any {
            it.status == TransferStatus.WAITING || it.status == TransferStatus.TRANSFERING
        }
        val text = when {
            !prefs.getBoolean("locked_hint_shown", false) -> {
                prefs.edit().putBoolean("locked_hint_shown", true).apply()
                lockedHint
            }
            transfersBusy -> busyHint
            else -> null
        }
        if (text != null) {
            hintText = text
            hintVisible = true
            delay(3000)
            hintVisible = false
        }
    }

    // ---------- 布局 ----------
    // 根级横滑手势 = 返回（进入是横滑，退出对称）。拨轮自己消费的水平拖动不会到这里，
    // 两个方向都接受，避免"哪边算回去"的方向歧义。
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .pointerInput(Unit) {
                var totalDx = 0f
                detectHorizontalDragGestures(
                    onDragStart = { totalDx = 0f },
                    onDragEnd = { if (abs(totalDx) > 100.dp.toPx()) onNavigateBack() }
                ) { _, dragAmount -> totalDx += dragAmount }
            }
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .systemBarsPadding()
                .padding(horizontal = 12.dp, vertical = 8.dp)
        ) {
            // 顶栏（无返回按钮：横滑或系统返回退出）
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    modelName ?: stringResource(R.string.remote_title),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.onBackground,
                    modifier = Modifier.clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null
                    ) { onTitleTap() }
                )
                Spacer(Modifier.weight(1f))
                Text(
                    text = if (connected) "●" else "○",
                    color = if (connected) colors.statusConnected else colors.accentOrange,
                    fontSize = 13.sp
                )
            }
            Spacer(Modifier.height(10.dp))

            // 监看画面
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(3f / 2f)
                    .clip(RoundedCornerShape(14.dp))
                    .background(Color(0xFF0D0D0D))
                    .onSizeChanged { viewSize = it }
                    .pointerInput(Unit) { detectTapGestures { tapToFocus(it) } }
            ) {
                frame?.let {
                    Image(
                        bitmap = it,
                        contentDescription = null,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.fillMaxSize()
                    )
                } ?: Icon(
                    Icons.Default.Videocam, contentDescription = null,
                    tint = Color.White.copy(alpha = 0.18f),
                    modifier = Modifier.size(44.dp).align(Alignment.Center)
                )
                // 对焦框
                focusPos?.let { pt ->
                    val reticleScale = remember(focusNonce) { Animatable(1.5f) }
                    LaunchedEffect(focusNonce) { reticleScale.animateTo(1f, tween(180)) }
                    Box(
                        modifier = Modifier
                            .offset {
                                IntOffset(
                                    (pt.x - 28.dp.toPx()).roundToInt(),
                                    (pt.y - 28.dp.toPx()).roundToInt()
                                )
                            }
                            .size(56.dp)
                            .graphicsLayer {
                                scaleX = reticleScale.value
                                scaleY = reticleScale.value
                            }
                            .border(1.5.dp, Color.White.copy(alpha = 0.9f), RoundedCornerShape(8.dp))
                    )
                }
                if (devFps && fps > 0f) {
                    Text(
                        "%.1f fps".format(fps),
                        color = Color.White,
                        fontSize = 10.sp,
                        fontFamily = FontFamily.Monospace,
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .padding(8.dp)
                            .background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(6.dp))
                            .padding(horizontal = 6.dp, vertical = 2.dp)
                    )
                }
                if (!connected) {
                    Text(
                        stringResource(R.string.camera_not_connected),
                        color = colors.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier
                            .align(Alignment.Center)
                            .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(8.dp))
                            .padding(horizontal = 12.dp, vertical = 6.dp)
                    )
                }
            }
            Spacer(Modifier.height(12.dp))

            // 曝光读数条：点谁调谁；RO 参数压暗；右端模式徽标（只读）
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.CenterVertically
            ) {
                EXPOSURE_PROPS.forEach { prop ->
                    val p = params[prop]
                    val selected = prop == selectedProp
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null
                            ) {
                                selectedProp = prop
                                haptics.tick()
                            }
                            .padding(horizontal = 4.dp, vertical = 4.dp)
                    ) {
                        Text(
                            p?.let { rcFormat(prop, it.current) } ?: "—",
                            color = when {
                                p == null -> colors.onSurfaceVariant.copy(alpha = 0.4f)
                                !p.writable -> colors.onSurfaceVariant.copy(alpha = 0.5f)
                                selected -> Color.White
                                else -> colors.onSurfaceVariant
                            },
                            fontFamily = FontFamily.Monospace,
                            fontSize = 15.sp,
                            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                            maxLines = 1
                        )
                        Box(
                            Modifier
                                .padding(top = 3.dp)
                                .size(width = 18.dp, height = 2.dp)
                                .background(
                                    if (selected) colors.accentBlue else Color.Transparent,
                                    RoundedCornerShape(1.dp)
                                )
                        )
                    }
                }
                modeText?.let {
                    Text(
                        it,
                        color = colors.onSurfaceVariant,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier
                            .border(1.dp, colors.glassPanelBorder, RoundedCornerShape(6.dp))
                            .padding(horizontal = 7.dp, vertical = 2.dp)
                    )
                }
            }
            Spacer(Modifier.height(4.dp))

            // 吸附拨轮
            ParamWheel(
                param = params[selectedProp],
                haptics = haptics,
                modifier = Modifier.fillMaxWidth(),
                onCommit = ::commitValue
            )

            Spacer(Modifier.weight(1f))

            // 底部：最近一张 / 快门 / 录像占位（v2）
            Row(
                modifier = Modifier.fillMaxWidth().padding(bottom = 10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(Modifier.size(52.dp)) {
                    AnimatedContent(
                        targetState = lastShot,
                        transitionSpec = {
                            (scaleIn(initialScale = 0.5f, animationSpec = tween(260)) + fadeIn(tween(260)))
                                .togetherWith(fadeOut(tween(120)))
                        },
                        label = "lastShot"
                    ) { shot ->
                        if (shot != null) {
                            Image(
                                bitmap = shot,
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier
                                    .size(52.dp)
                                    .clip(RoundedCornerShape(10.dp))
                                    .border(1.dp, Color.White.copy(alpha = 0.25f), RoundedCornerShape(10.dp))
                                    .clickable { showLastShotLarge = true }
                            )
                        } else {
                            Box(Modifier.size(52.dp))
                        }
                    }
                }
                Spacer(Modifier.weight(1f))
                ShutterButton(
                    capturing = capturing,
                    enabled = connected,
                    onClick = ::shoot
                )
                Spacer(Modifier.weight(1f))
                // 与左侧缩略图等宽的占位，保证快门键几何居中
                Box(Modifier.size(52.dp))
            }
        }

        // 顶部提示条
        AnimatedVisibility(
            visible = hintVisible,
            enter = fadeIn(tween(200)) + slideInVertically(tween(200)) { -it / 2 },
            exit = fadeOut(tween(300)),
            modifier = Modifier
                .align(Alignment.TopCenter)
                .statusBarsPadding()
                .padding(top = 60.dp)
        ) {
            Text(
                hintText,
                color = colors.onBackground,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier
                    .clip(RoundedCornerShape(12.dp))
                    .background(colors.glassSurfaceHeavy)
                    .border(1.dp, colors.glassPanelBorder, RoundedCornerShape(12.dp))
                    .padding(horizontal = 14.dp, vertical = 8.dp)
            )
        }

        // 最近一张放大回显（缩略图放大，非原图；下载走照片列表）
        if (showLastShotLarge && lastShot != null) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.92f))
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null
                    ) { showLastShotLarge = false },
                contentAlignment = Alignment.Center
            ) {
                Image(
                    bitmap = lastShot!!,
                    contentDescription = null,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxWidth().padding(12.dp)
                )
            }
        }

        // 开发者面板
        if (devPanel) {
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
            enter = slideInVertically(tween(240)) { it } + fadeIn(tween(240)),
            exit = slideOutVertically(tween(200)) { it } + fadeOut(tween(200)),
            modifier = Modifier.align(Alignment.BottomCenter)
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp))
                    .background(colors.glassSurfaceHeavy)
                    .border(
                        1.dp, colors.glassPanelBorder,
                        RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp)
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
                    GlassButton(onClick = { devPanel = false }, contentPadding = PaddingValues(8.dp)) {
                        Icon(
                            Icons.Default.Close, contentDescription = null,
                            tint = colors.onSurfaceVariant, modifier = Modifier.size(14.dp)
                        )
                    }
                }
                Spacer(Modifier.height(6.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        stringResource(R.string.dev_hd_liveview),
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.onSurfaceVariant
                    )
                    Spacer(Modifier.width(6.dp))
                    Switch(
                        checked = hdLiveView,
                        onCheckedChange = {
                            hdLiveView = it
                            startSession(it)   // 重启会话使分辨率生效
                        }
                    )
                    Spacer(Modifier.weight(1f))
                    Text(
                        stringResource(R.string.dev_fps_overlay),
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.onSurfaceVariant
                    )
                    Spacer(Modifier.width(6.dp))
                    Switch(checked = devFps, onCheckedChange = { devFps = it })
                }
                Spacer(Modifier.height(6.dp))
                GlassButton(onClick = ::runProbe, enabled = connected && !probing) {
                    Text(
                        stringResource(R.string.lab_run_probe),
                        style = MaterialTheme.typography.labelMedium,
                        color = colors.onBackground
                    )
                }
                Spacer(Modifier.height(8.dp))
                LazyColumn(
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
                            else colors.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}

/**
 * 吸附拨轮：档位来自相机枚举，滑动吸附对中即提交；中心值放大高亮，滑过一档 tick。
 * RO 时禁滚、整条压暗、右端锁图标，点击左右轻抖（把"调不了"的答案放在界面上）。
 */
@OptIn(ExperimentalFoundationApi::class)   // rememberSnapFlingBehavior
@Composable
private fun ParamWheel(
    param: RcParam?,
    haptics: Haptics,
    modifier: Modifier = Modifier,
    onCommit: (RcParam, Long) -> Unit
) {
    val colors = AppTheme.colors
    if (param == null || param.values.isEmpty()) {
        Box(modifier.height(56.dp), contentAlignment = Alignment.Center) {
            Text("—", color = colors.onSurfaceVariant.copy(alpha = 0.4f))
        }
        return
    }
    val current by rememberUpdatedState(param)
    val listState = rememberLazyListState()
    val fling = rememberSnapFlingBehavior(listState)
    val scope = rememberCoroutineScope()
    var programmatic by remember { mutableStateOf(false) }
    val shake = remember { Animatable(0f) }

    val centeredIndex by remember {
        derivedStateOf {
            val li = listState.layoutInfo
            if (li.visibleItemsInfo.isEmpty()) null
            else {
                val center = (li.viewportStartOffset + li.viewportEndOffset) / 2
                li.visibleItemsInfo.minByOrNull { abs(it.offset + it.size / 2 - center) }?.index
            }
        }
    }

    // 参数切换/外部刷新：拨轮直接跳到当前值（不触发提交）
    LaunchedEffect(param.prop, param.current, param.values) {
        val idx = param.values.indexOf(param.current)
        if (idx >= 0) {
            programmatic = true
            listState.scrollToItem(idx)
            programmatic = false
        }
    }

    // 滑动停止且对中值 != 当前值 → 提交
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }.collect { scrolling ->
            if (!scrolling && !programmatic) {
                val p = current
                val idx = centeredIndex ?: return@collect
                if (idx in p.values.indices && idx != p.values.indexOf(p.current)) {
                    onCommit(p, p.values[idx])
                }
            }
        }
    }

    // 滑过一档 tick
    LaunchedEffect(listState) {
        snapshotFlow { centeredIndex }.collect {
            if (listState.isScrollInProgress) haptics.tick()
        }
    }

    BoxWithConstraints(
        modifier
            .height(56.dp)
            .graphicsLayer { translationX = shake.value }
            .pointerInput(Unit) {
                detectTapGestures {
                    if (!current.writable) {
                        scope.launch {
                            shake.animateTo(0f, keyframes {
                                durationMillis = 320
                                -8f at 50
                                8f at 110
                                -5f at 170
                                5f at 230
                                0f at 320
                            })
                        }
                    }
                }
            }
    ) {
        val sidePadding = (maxWidth - WHEEL_ITEM_WIDTH) / 2
        LazyRow(
            state = listState,
            flingBehavior = fling,
            userScrollEnabled = param.writable,
            contentPadding = PaddingValues(horizontal = sidePadding),
            modifier = Modifier.fillMaxSize()
        ) {
            itemsIndexed(param.values) { i, v ->
                val isCenter = i == centeredIndex
                Box(
                    Modifier.width(WHEEL_ITEM_WIDTH).fillMaxHeight(),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        rcFormat(param.prop, v),
                        color = when {
                            !param.writable -> colors.onSurfaceVariant.copy(alpha = 0.35f)
                            isCenter -> Color.White
                            else -> colors.onSurfaceVariant.copy(alpha = 0.8f)
                        },
                        fontSize = if (isCenter) 17.sp else 13.sp,
                        fontWeight = if (isCenter) FontWeight.SemiBold else FontWeight.Normal,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 1
                    )
                }
            }
        }
        // 中心刻度线（上下各一条）
        Box(
            Modifier
                .align(Alignment.TopCenter)
                .size(width = 1.5.dp, height = 7.dp)
                .background(Color.White.copy(alpha = if (param.writable) 0.7f else 0.25f))
        )
        Box(
            Modifier
                .align(Alignment.BottomCenter)
                .size(width = 1.5.dp, height = 7.dp)
                .background(Color.White.copy(alpha = if (param.writable) 0.7f else 0.25f))
        )
        if (!param.writable) {
            Icon(
                Icons.Default.Lock, contentDescription = null,
                tint = colors.onSurfaceVariant.copy(alpha = 0.6f),
                modifier = Modifier
                    .align(Alignment.CenterEnd)
                    .padding(end = 10.dp)
                    .size(13.dp)
            )
        }
    }
}

/** 大圆快门键：按下内圈收缩，拍摄中转圈。 */
@Composable
private fun ShutterButton(capturing: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val innerScale by animateFloatAsState(
        targetValue = if (pressed) 0.82f else 1f,
        animationSpec = tween(90),
        label = "shutterPress"
    )
    Box(
        modifier = Modifier
            .size(76.dp)
            .border(3.dp, Color.White.copy(alpha = if (enabled) 0.9f else 0.3f), CircleShape)
            .clickable(
                interactionSource = interaction,
                indication = null,
                enabled = enabled && !capturing,
                onClick = onClick
            ),
        contentAlignment = Alignment.Center
    ) {
        if (capturing) {
            CircularProgressIndicator(
                modifier = Modifier.size(52.dp),
                color = Color.White,
                strokeWidth = 3.dp
            )
        } else {
            Box(
                Modifier
                    .size(60.dp)
                    .graphicsLayer {
                        scaleX = innerScale
                        scaleY = innerScale
                    }
                    .background(Color.White.copy(alpha = if (enabled) 1f else 0.3f), CircleShape)
            )
        }
    }
}
