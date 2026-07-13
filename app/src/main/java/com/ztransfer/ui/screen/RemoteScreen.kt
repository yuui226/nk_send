package com.ztransfer.ui.screen

import android.content.Context
import android.graphics.BitmapFactory
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowForward
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
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
import com.ztransfer.protocol.rcFormat
import com.ztransfer.protocol.rcGetParam
import com.ztransfer.protocol.rcPollEvents
import com.ztransfer.protocol.rcSetLvSize
import com.ztransfer.protocol.rcSetValue
import com.ztransfer.protocol.runLabProbe
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.DarkAppColors
import com.ztransfer.ui.theme.LocalAppColors
import com.ztransfer.ui.util.rememberHaptics
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.CancellationException
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

// 直控胶囊覆盖的四个曝光参数，2×2 网格顺序：
// 第一排 曝光补偿 / ISO，第二排 光圈 / 快门速度。
private val EXPOSURE_PROPS = listOf(
    Lab.PROP_EXP_COMPENSATION, Lab.PROP_ISO, Lab.PROP_F_NUMBER, Lab.PROP_NK_SHUTTER
)

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
    var modeText by remember { mutableStateOf<String?>(null) }
    val params = remember { mutableStateMapOf<Int, RcParam>() }
    // 每个参数一个待发送任务：乐观更新后合并发送最终值（声明在前，事件循环要引用）
    val pendingSets = remember { mutableMapOf<Int, Job>() }
    // 初始参数是否已加载完：用于把事件轮询推迟到之后开始，避免进页时 GetEvent 与
    // 5 条参数读取抢 ioMutex、拖慢参数首次显示。
    var initialLoaded by remember { mutableStateOf(false) }
    // 弹出完整值表的参数（点胶囊中间值触发）
    var listProp by remember { mutableStateOf<Int?>(null) }

    // ---------- 开发者面板 ----------
    val logLines = remember { mutableStateListOf<String>() }
    var devPanel by remember { mutableStateOf(false) }
    var showFps by remember { mutableStateOf(true) }    // 帧率覆盖默认显示（右下角）
    var hdLiveView by remember { mutableStateOf(false) } // 高清监看(XGA)开关
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
                        } catch (e: CancellationException) {
                            throw e   // 会话被取消（退页/重启），不能当普通错误吞掉
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

    // 进页/重连：先拉参数（5 条快速往返，胶囊立刻点亮）再启动监看——LV 首帧
    // 反正要等相机预热（DeviceReady 常见 1s+），参数若排在取帧流后面才真叫慢；
    // 型号是装饰信息，最后后台拉。
    LaunchedEffect(connected) {
        if (!connected) return@LaunchedEffect
        // 先把通道让给参数读取（此时事件轮询尚未开始、缩略图填充已停），参数最快点亮，
        // 再放开事件轮询并启动监看。
        EXPOSURE_PROPS.forEach { refreshParam(it) }
        refreshMode()
        initialLoaded = true
        startSession(hdLiveView)
    }

    // 事件轮询：唯一的 GetEvent 消费者。参数被机身侧改动（0x4006）时刷新对应值域。
    LaunchedEffect(Unit) {
        while (isActive) {
            // 让初始参数先加载完再开始轮询，避免抢锁拖慢进页
            if (!initialLoaded) { delay(150); continue }
            val cam = cameraViewModel.getCamera()
            if (cam == null) { delay(1500); continue }
            val events = runCatching { cam.rcPollEvents() }.getOrDefault(emptyList())
            for (e in events) {
                eventFlow.emit(e)
                if (e.first == Lab.EVT_DEVICE_PROP_CHANGED) {
                    val prop = e.second.toInt()
                    // 本地还有未发出的乐观值时不刷新——自己刚设的值触发的事件
                    // 会把正在连调的显示值拽回去
                    if (prop in EXPOSURE_PROPS && pendingSets[prop]?.isActive != true) {
                        refreshParam(prop)
                    }
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
            val rc = runCatching { cam.rcSetValue(p, value) }.getOrDefault(-1)
            if (rc != Lab.OK) {
                devLog("!! set 0x%04X resp=0x%04X".format(prop, rc and 0xFFFF))
                refreshParam(prop)   // 写失败刷回真实值
            }
        }
    }

    fun stepParam(prop: Int, delta: Int) {
        val p = params[prop] ?: return
        if (!p.writable || p.values.isEmpty()) return
        val idx = p.values.indexOf(p.current)
        if (idx < 0) return
        val newIdx = (idx + delta).coerceIn(0, p.values.size - 1)
        if (newIdx == idx) return
        sendValue(prop, p.values[newIdx], immediate = false)
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

    // 模拟半按对焦：按住快门键 = 持续半按（循环 AfDrive 在【当前对焦点】合焦），
    // 松开手指在按钮内 = 拍摄，手指移出按钮 = 取消不拍。对焦框在按住期间显示。
    //（用 AfDrive 半按而非 ChangeAfArea 移点：后者响应 0x2001 但落点语义与机身对不上、
    // 连发还会把相机踢出 LV(0xA00B)；半按模式行为可预期。）
    var afHeld by remember { mutableStateOf(false) }
    var afJob by remember { mutableStateOf<Job?>(null) }
    fun startFocus() {
        if (afHeld) return
        afHeld = true
        haptics.tick()
        afJob?.cancel()
        afJob = scope.launch {
            val cam = cameraViewModel.getCamera() ?: return@launch
            // 循环驱动 AF 模拟"持续半按"：每次 AfDrive 阻塞至合焦/失败，短歇再来，
            // 让按住期间画面保持跟焦。0xA002=对不上焦（正常，继续尝试）。
            while (isActive) {
                val drive = runCatching { cam.rcAfDrive() }.getOrDefault(-1)
                devLog("AF drive resp=0x%04X".format(drive and 0xFFFF))
                delay(120)
            }
        }
    }
    fun endFocus() {
        afHeld = false
        afJob?.cancel()
        afJob = null
    }
    // 断连兜底：若在按住对焦期间相机掉线，快门键手势节点会被卸载、onRelease 不再执行，
    // 导致 afHeld/afJob 卡住（对焦框不消失、对空相机空转刷日志）。这里主动复位。
    LaunchedEffect(connected) {
        if (!connected) endFocus()
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

    // ---------- 提示条（首次进页的一次性机身锁定提示）----------
    // 传输中已在照片列表侧禁止进入本页，故不再需要"传输卡顿"提示。
    var hintText by remember { mutableStateOf("") }
    var hintVisible by remember { mutableStateOf(false) }
    val lockedHint = stringResource(R.string.remote_locked_hint)
    LaunchedEffect(Unit) {
        val prefs = context.getSharedPreferences("remote_page", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("locked_hint_shown", false)) {
            prefs.edit().putBoolean("locked_hint_shown", true).apply()
            hintText = lockedHint
            hintVisible = true
            delay(3000)
            hintVisible = false
        }
    }

    // ---------- 布局 ----------
    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .systemBarsPadding()
                .padding(horizontal = 12.dp, vertical = 8.dp)
        ) {
            // 顶栏：左＝复用照片列表的信号按钮（连接/信号状态，取代原来的小圆点）；
            // 右＝开发者 / HD / FPS 三个小按钮 + 返回。返回用【右】箭头——本页位于
            // 照片列表左侧，回去的方向向右。
            Row(verticalAlignment = Alignment.CenterVertically) {
                SignalPill(rssi = camState.wifiRssi, connected = connected)
                Spacer(Modifier.weight(1f))
                // 开发者工具入口（放在 HD/FPS 左侧）
                GlassButton(onClick = { devPanel = true }, contentPadding = PaddingValues(9.dp)) {
                    Icon(
                        Icons.Default.BugReport,
                        contentDescription = stringResource(R.string.cd_dev_panel),
                        tint = colors.onSurfaceVariant, modifier = Modifier.size(18.dp)
                    )
                }
                Spacer(Modifier.width(6.dp))
                TopToggle("HD", hdLiveView) { hdLiveView = !hdLiveView; startSession(hdLiveView) }
                Spacer(Modifier.width(6.dp))
                TopToggle("FPS", showFps) { showFps = !showFps }
                Spacer(Modifier.width(6.dp))
                GlassButton(onClick = onNavigateBack, contentPadding = PaddingValues(9.dp)) {
                    Icon(
                        Icons.Default.ArrowForward, contentDescription = null,
                        tint = colors.onBackground, modifier = Modifier.size(18.dp)
                    )
                }
            }
            Spacer(Modifier.height(10.dp))

            // 监看画面（取景器：不再点击对焦——对焦改由按住快门键触发，见底部）
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(3f / 2f)
                    .clip(RoundedCornerShape(14.dp))
                    .background(Color(0xFF0D0D0D))
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
                // 曝光模式徽标（只读；带物理拨盘的机身无法远程切换）——取景器左上角，
                // 相机副屏的自然位置。
                modeText?.let {
                    Text(
                        it,
                        color = Color.White,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier
                            .align(Alignment.TopStart)
                            .padding(8.dp)
                            .background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(6.dp))
                            .padding(horizontal = 7.dp, vertical = 2.dp)
                    )
                }
                // 半按对焦指示：按住期间显示中央对焦框，收缩入场（合焦位置由机身当前对焦点决定）
                if (afHeld) {
                    val reticleScale = remember { Animatable(1.4f) }
                    LaunchedEffect(Unit) { reticleScale.animateTo(1f, tween(180)) }
                    Box(
                        modifier = Modifier
                            .align(Alignment.Center)
                            .size(64.dp)
                            .graphicsLayer {
                                scaleX = reticleScale.value
                                scaleY = reticleScale.value
                            }
                            .border(1.5.dp, colors.accentBlue.copy(alpha = 0.95f), RoundedCornerShape(8.dp))
                    )
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

            // 2×2 直控胶囊：读数即控件——单击 ±1 档、长按连调、点中间值弹全表直跳；
            // 只读参数整个胶囊压暗 + 锁。无选中态、无隐藏手势。
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                EXPOSURE_PROPS.chunked(2).forEach { rowProps ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        rowProps.forEach { prop ->
                            ParamCapsule(
                                param = params[prop],
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
                // 按住=半按对焦，松开在键内=拍摄，移出取消。对焦与拍照合一（真机两段式快门隐喻）。
                ShutterButton(
                    capturing = capturing,
                    focusing = afHeld,
                    enabled = connected,
                    onFocusStart = { startFocus() },
                    onRelease = { fire ->
                        endFocus()
                        if (fire) shoot()
                    }
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

        // 完整值表（点胶囊中间值弹出）：呼出=缩放淡入、消失=淡出（item 9 动画）。
        // 用 lastListProp 记住最后一次的参数，让消失动画期间仍有数据可渲染。
        var lastListProp by remember { mutableStateOf<Int?>(null) }
        LaunchedEffect(listProp) { if (listProp != null) lastListProp = listProp }
        // 遮罩：淡入淡出
        AnimatedVisibility(
            visible = listProp != null,
            enter = fadeIn(tween(160)),
            exit = fadeOut(tween(160)),
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
                    LazyColumn(
                        state = valueListState,
                        modifier = Modifier
                            .width(190.dp)
                            .heightIn(max = 340.dp)
                            .clip(RoundedCornerShape(16.dp))
                            .background(colors.glassSurfaceHeavy)
                            .border(1.dp, colors.glassPanelBorder, RoundedCornerShape(16.dp))
                            .padding(vertical = 6.dp)
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
 * 参数直控胶囊：[− 值 ＋]。单击 ±1 档、长按连调（420ms 后每 140ms 一档）、
 * 点中间值打开完整值表大跨度直跳；只读参数整体压暗 + 锁图标，步进与弹表不可用。
 */
@Composable
private fun ParamCapsule(
    param: RcParam?,
    modifier: Modifier = Modifier,
    onStep: (Int) -> Unit,
    onOpenList: () -> Unit
) {
    val colors = AppTheme.colors
    val scope = rememberCoroutineScope()
    val writable = param != null && param.writable && param.values.isNotEmpty()

    @Composable
    fun StepZone(delta: Int, icon: ImageVector) {
        Box(
            modifier = Modifier
                .width(42.dp)
                .fillMaxHeight()
                .pointerInput(writable, delta) {
                    if (!writable) return@pointerInput
                    detectTapGestures(onPress = {
                        onStep(delta)
                        val repeater = scope.launch {
                            delay(420)
                            while (isActive) {
                                onStep(delta)
                                delay(140)
                            }
                        }
                        tryAwaitRelease()
                        repeater.cancel()
                    })
                },
            contentAlignment = Alignment.Center
        ) {
            Icon(
                icon, contentDescription = null,
                tint = Color.White.copy(alpha = if (writable) 0.75f else 0.2f),
                modifier = Modifier.size(16.dp)
            )
        }
    }

    Row(
        modifier = modifier
            .height(46.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(colors.glassSurface)
            .border(1.dp, colors.glassPanelBorder, RoundedCornerShape(14.dp)),
        verticalAlignment = Alignment.CenterVertically
    ) {
        StepZone(-1, Icons.Default.Remove)
        Row(
            modifier = Modifier
                .weight(1f)
                .fillMaxHeight()
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    enabled = param != null
                ) { onOpenList() },
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                param?.let { rcFormat(it.prop, it.current) } ?: "—",
                color = when {
                    param == null -> colors.onSurfaceVariant.copy(alpha = 0.4f)
                    !writable -> colors.onSurfaceVariant.copy(alpha = 0.5f)
                    else -> Color.White
                },
                fontFamily = FontFamily.Monospace,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1
            )
            if (param != null && !writable) {
                Spacer(Modifier.width(4.dp))
                Icon(
                    Icons.Default.Lock, contentDescription = null,
                    tint = colors.onSurfaceVariant.copy(alpha = 0.6f),
                    modifier = Modifier.size(11.dp)
                )
            }
        }
        StepZone(1, Icons.Default.Add)
    }
}

/**
 * 大圆快门键（两段式）：
 * - 按下（onFocusStart）= 半按对焦；[focusing] 期间内圈收缩 + 边框转蓝，示意"正在合焦"。
 * - 抬手在键内（tryAwaitRelease 返回 true）→ onRelease(true) 拍摄；移出键外 → onRelease(false) 取消。
 * - 拍摄中（capturing）转圈并禁手势。
 */
@Composable
private fun ShutterButton(
    capturing: Boolean,
    focusing: Boolean,
    enabled: Boolean,
    onFocusStart: () -> Unit,
    onRelease: (fire: Boolean) -> Unit
) {
    val innerScale by animateFloatAsState(
        targetValue = if (focusing) 0.8f else 1f,
        animationSpec = tween(120),
        label = "shutterFocus"
    )
    val ringColor = when {
        !enabled -> Color.White.copy(alpha = 0.3f)
        focusing -> AppTheme.colors.accentBlue
        else -> Color.White.copy(alpha = 0.9f)
    }
    Box(
        modifier = Modifier
            .size(76.dp)
            .border(3.dp, ringColor, CircleShape)
            .then(
                if (enabled && !capturing)
                    Modifier.pointerInput(Unit) {
                        // 按下即半按对焦；抬手时按【落点是否在键内】判定拍摄/取消——
                        // waitForUpOrCancellation 返回抬手事件(取消返回 null)，据其 position
                        // 判断在界内(拍摄)还是滑出界外(取消)，比 tryAwaitRelease 的键内/取消
                        // 语义更可靠（无滚动父级时移出再松手仍会被算作释放）。
                        awaitEachGesture {
                            awaitFirstDown()
                            onFocusStart()
                            val up = waitForUpOrCancellation()
                            val fire = up != null &&
                                up.position.x in 0f..size.width.toFloat() &&
                                up.position.y in 0f..size.height.toFloat()
                            onRelease(fire)
                        }
                    }
                else Modifier
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

/** 顶栏小切换按钮（HD / FPS）：激活时蓝底高亮，未激活时低调玻璃底。 */
@Composable
private fun TopToggle(label: String, active: Boolean, onClick: () -> Unit) {
    val colors = AppTheme.colors
    GlassButton(
        onClick = onClick,
        shape = RoundedCornerShape(20.dp),
        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 7.dp)
    ) {
        Text(
            label,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (active) colors.accentBlue else colors.onSurfaceVariant
        )
    }
}
