package com.ztransfer.ui.screen

import android.content.Context
import android.graphics.BitmapFactory
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
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
import com.ztransfer.ui.theme.Motion
import com.ztransfer.ui.util.rememberHaptics
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlin.math.abs
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.hypot

// 直控胶囊覆盖的四个曝光参数，2×2 网格顺序：
// 第一排 曝光补偿 / ISO，第二排 光圈 / 快门速度。
private val EXPOSURE_PROPS = listOf(
    Lab.PROP_EXP_COMPENSATION, Lab.PROP_ISO, Lab.PROP_F_NUMBER, Lab.PROP_NK_SHUTTER
)

/**
 * 无线遥控页（正式功能）：取景器隐喻，恒黑底不随主题——通过覆盖 [LocalAppColors]
 * 让页内所有玻璃组件走深色 token（与 PhotoPreview 恒黑同理，但组件无需特判）。
 *
 * 布局：顶栏（信号/开发者/HD/FPS/返回）→ 监看画面 → 2×2 参数拖拽微调 tile
 * （值域来自相机枚举，只读压暗+锁；点数值弹全表直跳）→ 大圆快门键
 * （按住=半按对焦、松开在键内=拍摄）。进页自动开监看、退页自动关；
 * 拍摄结果仅确认不入队（下载走照片列表）。开发者面板：顶栏虫子按钮呼出（探测/日志）。
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

    suspend fun decode(bytes: ByteArray, offset: Int = 0): ImageBitmap? =
        withContext(Dispatchers.Default) {
            BitmapFactory.decodeByteArray(bytes, offset, bytes.size - offset)?.asImageBitmap()
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
            fps = 0f   // 换会话（HD 切换/重启）时清掉上一会话的陈旧读数
            // 解码流水线：取帧（网络 IO）与解码（Default 线程）并行——取下一帧的同时
            // 解上一帧；CONFLATED 只留最新帧，解码偶尔跟不上时丢旧帧而不排队积压。
            val frameCh = Channel<Pair<ByteArray, Int>>(Channel.CONFLATED)
            launch {
                for ((buf, off) in frameCh) {
                    decode(buf, off)?.let { frame = it }
                }
            }
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
                        frameCh.trySend(grabbed)
                        frames++
                        val now = System.currentTimeMillis()
                        if (now - windowStart >= 1000) {
                            fps = frames * 1000f / (now - windowStart)
                            frames = 0
                            windowStart = now
                        }
                    }
                    // 断流重启前先主动关一次 LV：错误退出时相机侧 LV 状态未知，带着
                    // 未关的 LV 直接重开会吃 InvalidStatus、rcSetLvSize 也不生效；
                    // 关闭失败无所谓（可能本就已掉出 LV）。
                    fps = 0f
                    if (isActive) runCatching { cam.labEndLiveView() }
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
        if (!connected) {
            // 掉线时暂停事件轮询（下面的 initialLoaded 门），重连后参数重读
            // 依然先于轮询，与首次进页同样不抢锁。
            initialLoaded = false
            return@LaunchedEffect
        }
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
                        // 曝光模式变化会连带改变各参数的可写性/值域（正在连调中的除外，同上）
                        EXPOSURE_PROPS.forEach {
                            if (pendingSets[it]?.isActive != true) refreshParam(it)
                        }
                    }
                }
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
            val rc = try {
                cam.rcSetValue(p, value)
            } catch (e: CancellationException) {
                throw e   // 被更新一步的 sendValue 顶掉，不是写失败：别记日志、别回读
            } catch (e: Exception) {
                -1
            }
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
        // 当前值不在枚举里（非标准档位/值域刚随模式变化）：按物理量找最近档位当起点，
        // 否则拖动完全失灵（indexOf 永远 -1）。此时哪怕 delta 走不动也发一次，把值吸附回枚举。
        val from = if (idx >= 0) idx else {
            val m = paramMetric(prop, p.current)
            p.values.indices.minByOrNull { abs(paramMetric(prop, p.values[it]) - m) } ?: return
        }
        val newIdx = (from + delta).coerceIn(0, p.values.size - 1)
        if (idx >= 0 && newIdx == idx) return
        sendValue(prop, p.values[newIdx], immediate = false)
    }

    // 拍摄：capturing 从触发一直保持到收到 ObjectAdded（相机确认新照片已生成）——
    // 快门键转圈即"正在等待拍摄确认"，收到确认/超时/失败即停。不读取也不展示缩略图。
    fun shoot() {
        if (capturing) return
        val cam = cameraViewModel.getCamera() ?: return
        scope.launch {
            capturing = true
            haptics.longPress()   // 快门触发反馈（经全局震动设置门控）
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
                val handle = pending.await()   // 拍摄成功的确认信号
                if (handle == null) devLog("!! capture: no ObjectAdded in 12s")
                else devLog("shot ok: handle=0x%08X".format(handle))
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
    var afLocked by remember { mutableStateOf(false) }   // 当前是否已合焦（对焦框变绿）
    var afJob by remember { mutableStateOf<Job?>(null) }
    fun startFocus() {
        if (afHeld) return
        afHeld = true
        afLocked = false
        haptics.tick()   // 开始半按的轻反馈
        afJob?.cancel()
        afJob = scope.launch {
            val cam = cameraViewModel.getCamera() ?: return@launch
            // 循环驱动 AF 模拟"持续半按"：每次 AfDrive 阻塞至合焦/失败，短歇再来。
            // AfDrive 返回码即合焦结果：0x2001=合上，0xA002=对不上焦。
            // 合焦震动【边沿触发】：仅在"未合焦→刚合上"那一下震一次，避免每轮嗡嗡震；
            // 失焦后再合上会再震。震动本身经全局设置门控（haptics 内部判 enabled）。
            while (isActive) {
                val drive = runCatching { cam.rcAfDrive() }.getOrDefault(-1)
                devLog("AF drive resp=0x%04X".format(drive and 0xFFFF))
                val locked = drive == Lab.OK
                if (locked && !afLocked) haptics.tick()   // 合焦成功那一刻
                afLocked = locked
                delay(120)
            }
        }
    }
    fun endFocus() {
        afHeld = false
        afLocked = false
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
        // 首次读 SharedPreferences 会同步读盘，挪到 IO 免得进页时卡主线程一拍
        val alreadyShown = withContext(Dispatchers.IO) {
            val prefs = context.getSharedPreferences("remote_page", Context.MODE_PRIVATE)
            val shown = prefs.getBoolean("locked_hint_shown", false)
            if (!shown) prefs.edit().putBoolean("locked_hint_shown", true).apply()
            shown
        }
        if (!alreadyShown) {
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
                // 开发者工具入口（放在 HD/FPS 左侧）。顶栏控件统一 22dp 圆角 + 36dp 高
                //（与照片列表页顶栏一致）。
                GlassButton(
                    onClick = { devPanel = true },
                    shape = RoundedCornerShape(22.dp),
                    contentPadding = PaddingValues(9.dp),
                    modifier = Modifier.height(36.dp)
                ) {
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
                GlassButton(
                    onClick = onNavigateBack,
                    shape = RoundedCornerShape(22.dp),
                    contentPadding = PaddingValues(9.dp),
                    modifier = Modifier.height(36.dp)
                ) {
                    Icon(
                        Icons.Default.ArrowForward,
                        contentDescription = stringResource(R.string.cd_back),
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
                // 帧的 state 读取推迟到子组件内部：让 15-30fps 的换帧只重组那一张
                // Image，而不是整页（tile/快门/顶栏全部跟着每帧重跑一遍）。
                ViewfinderImage { frame }
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
                            .background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(8.dp))
                            .padding(horizontal = 7.dp, vertical = 2.dp)
                    )
                }
                // 半按对焦指示：按住期间显示中央对焦框（相机取景器语言的四角 L 形括号），
                // 收缩入场；合焦成功转绿并轻微收拢一下（与合焦触感同步的视觉确认）。
                if (afHeld) {
                    val reticleScale = remember { Animatable(1.4f) }
                    LaunchedEffect(Unit) { reticleScale.animateTo(1f, tween(180)) }
                    val lockScale by animateFloatAsState(
                        targetValue = if (afLocked) 0.9f else 1f,
                        animationSpec = Motion.bouncy(),
                        label = "afLock"
                    )
                    val reticleColor =
                        (if (afLocked) colors.statusConnected else colors.accentBlue)
                            .copy(alpha = 0.95f)
                    Canvas(
                        modifier = Modifier
                            .align(Alignment.Center)
                            .size(64.dp)
                            .graphicsLayer {
                                val s = reticleScale.value * lockScale
                                scaleX = s
                                scaleY = s
                            }
                    ) {
                        val len = 12.dp.toPx()
                        val sw = 2.dp.toPx()
                        val inset = sw / 2
                        val w = size.width - inset
                        val h = size.height - inset
                        // 四角 L 形括号（圆头短杆）
                        drawLine(reticleColor, Offset(inset, inset + len), Offset(inset, inset), sw, StrokeCap.Round)
                        drawLine(reticleColor, Offset(inset, inset), Offset(inset + len, inset), sw, StrokeCap.Round)
                        drawLine(reticleColor, Offset(w - len, inset), Offset(w, inset), sw, StrokeCap.Round)
                        drawLine(reticleColor, Offset(w, inset), Offset(w, inset + len), sw, StrokeCap.Round)
                        drawLine(reticleColor, Offset(inset, h - len), Offset(inset, h), sw, StrokeCap.Round)
                        drawLine(reticleColor, Offset(inset, h), Offset(inset + len, h), sw, StrokeCap.Round)
                        drawLine(reticleColor, Offset(w, h - len), Offset(w, h), sw, StrokeCap.Round)
                        drawLine(reticleColor, Offset(w - len, h), Offset(w, h), sw, StrokeCap.Round)
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

            // 2×2 数值拖拽微调：读数即控件——在数值上【上下拖动】按位移一格一档地调
            // （无惯性、不过冲），拖动时边缘淡显相邻档位示意方向；点一下弹全表直跳。
            // 只读参数整块压暗 + 锁。第一排 曝光补偿/ISO，第二排 光圈/快门。
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                EXPOSURE_PROPS.chunked(2).forEach { rowProps ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        rowProps.forEach { prop ->
                            ParamTile(
                                label = paramLabel(prop),
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

            // 底部：居中快门键（不再显示拍摄缩略图）。
            // 按住=半按对焦，松开在键内=拍摄、移出取消；拍摄中转圈=正在等相机确认拍好。
            Box(
                modifier = Modifier.fillMaxWidth().padding(bottom = 10.dp),
                contentAlignment = Alignment.Center
            ) {
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
            }
        }

        // 顶部提示条：视觉与照片列表页的底部玻璃提示条同款（22dp 玻璃 Surface + 投影 +
        // labelLarge）；位置留在顶部——本页底部是快门键，提示不能压它。
        AnimatedVisibility(
            visible = hintVisible,
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
                                else colors.onSurfaceVariant
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * 监看画面本体。[frameProvider] 延迟到此处才读 frame state——换帧重组被限制在
 * 这个小组件内，页面其余部分（tile/快门/顶栏）不随帧率重跑。
 */
@Composable
private fun ViewfinderImage(frameProvider: () -> ImageBitmap?) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val bmp = frameProvider()
        if (bmp != null) {
            Image(
                bitmap = bmp,
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize()
            )
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
        } else {
            Icon(
                Icons.Default.Videocam, contentDescription = null,
                tint = Color.White.copy(alpha = 0.18f),
                modifier = Modifier.size(44.dp)
            )
        }
    }
}

// 参数拖拽微调：每拖动这么多高度 = 走一档（点动式、无惯性，拖多少走多少）。
// 12dp/档：相机 1/3 挡一步,故一整挡(3 步)≈36dp 的小拖动,跟手又能精确单步(> 触摸 slop);
// 大跨度不靠拖,点数值弹全表直跳。太钝调大、太跳调小,一个常量的事。
private val PARAM_DRAG_STEP_DP = 12.dp

/** 参数在 tile 左上角的短标（相机通用符号，不进 i18n）。 */
private fun paramLabel(prop: Int): String = when (prop) {
    Lab.PROP_NK_SHUTTER -> "S"
    Lab.PROP_F_NUMBER -> "f"
    Lab.PROP_ISO -> "ISO"
    Lab.PROP_EXP_COMPENSATION -> "EV"
    else -> ""
}

/**
 * 参数的"物理量"度量：数值越大 = 向下拖趋近的方向（用户定义的向下语义）。
 * 快门→速度(分母/分子,越快越大)、光圈→开口(用 -f,f 越小开口越大)、ISO→感光度、EV→补偿值。
 */
private fun paramMetric(prop: Int, raw: Long): Double = when (prop) {
    Lab.PROP_NK_SHUTTER -> when (raw) {
        0xFFFFFFFFL, 0xFFFFFFFEL, 0xFFFFFFFDL -> 0.0   // Bulb/x200/Time：当作极慢
        else -> {
            val num = ((raw ushr 16) and 0xFFFFL).toDouble()
            val den = (raw and 0xFFFFL).toDouble()
            if (num > 0) den / num else 0.0
        }
    }
    Lab.PROP_F_NUMBER -> -raw.toDouble()                       // f 越小开口越大
    Lab.PROP_ISO, Lab.PROP_NK_ISO_EX -> raw.toDouble()        // ISO 越大越高
    Lab.PROP_EXP_COMPENSATION -> raw.toDouble()               // EV（已带符号）
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
 * 参数微调 tile：在数值上【上下拖动】按位移一格一档地调（无惯性、不过冲，拖多少走多少档），
 * 每档触感反馈（走 onStep→sendValue→haptics）；拖动时上/下边缘淡显相邻档位示意方向。
 * 点一下打开完整值表大跨度直跳。只读参数整块压暗 + 锁，拖动禁用。
 * 方向按物理量：向下拖 = 增大物理量（快门更快 / 光圈开口更大 / ISO 更高 / EV 更正），
 * 具体 enum 步进方向由 [downStepSign] 判定（不依赖枚举升/降序）。
 */
@Composable
private fun ParamTile(
    label: String,
    param: RcParam?,
    modifier: Modifier = Modifier,
    onStep: (Int) -> Unit,
    onOpenList: () -> Unit
) {
    val colors = AppTheme.colors
    val density = LocalDensity.current
    val writable = param != null && param.values.isNotEmpty() && param.writable
    var dragging by remember { mutableStateOf(false) }
    val stepPx = with(density) { PARAM_DRAG_STEP_DP.toPx() }

    // 向下拖对应的 enum 步进方向（向下=增大物理量）。
    val downSign = if (writable && param != null) downStepSign(param) else -1

    // 相邻档位（拖动时淡显，方向与物理量一致）：向下拖趋近的显示在下边缘，向上拖的在上边缘。
    val idx = param?.values?.indexOf(param.current) ?: -1
    val downTarget = if (idx >= 0) param?.values?.getOrNull(idx + downSign) else null
    val upTarget = if (idx >= 0) param?.values?.getOrNull(idx - downSign) else null

    // 与 GlassButton 同族的玻璃质感：半透明底 + 自上而下高光渐变 + 上亮下暗渐变描边；
    // 拖动中描边整体换成主题蓝示意"正在调"。
    val tileShape = RoundedCornerShape(14.dp)
    Box(
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
            // 上下拖动微调：位移累加，每跨过 stepPx 走一档（无惯性）。向下拖走 downSign 方向。
            .pointerInput(writable, downSign) {
                if (!writable) return@pointerInput
                var acc = 0f
                detectVerticalDragGestures(
                    onDragStart = { dragging = true; acc = 0f },
                    onDragEnd = { dragging = false },
                    onDragCancel = { dragging = false }
                ) { _, dy ->
                    acc += dy   // 手指向下 dy>0 → acc 增 → 向下方向
                    while (acc >= stepPx) { onStep(downSign); acc -= stepPx }
                    while (acc <= -stepPx) { onStep(-downSign); acc += stepPx }
                }
            }
            // 单击打开完整值表（仅可写参数；只读已由锁图标表明不可调）。
            .pointerInput(writable) {
                detectTapGestures { if (writable) onOpenList() }
            }
    ) {
        // 左上短标
        if (label.isNotEmpty()) {
            Text(
                label,
                color = colors.onSurfaceVariant.copy(alpha = if (writable) 0.85f else 0.4f),
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.align(Alignment.TopStart).padding(start = 10.dp, top = 6.dp)
            )
        }
        // 只读锁（右上）
        if (param != null && !writable) {
            Icon(
                Icons.Default.Lock, contentDescription = null,
                tint = colors.onSurfaceVariant.copy(alpha = 0.55f),
                modifier = Modifier.align(Alignment.TopEnd).padding(end = 8.dp, top = 6.dp).size(11.dp)
            )
        }
        // 拖动时的相邻档位淡显（上边缘=向上拖趋近，下边缘=向下拖趋近，方向与物理量一致）
        if (dragging && writable) {
            upTarget?.let {
                Text(
                    rcFormat(param!!.prop, it),
                    color = colors.onSurfaceVariant.copy(alpha = 0.65f),
                    fontFamily = FontFamily.Monospace, fontSize = 10.sp,
                    modifier = Modifier.align(Alignment.TopCenter).padding(top = 3.dp)
                )
            }
            downTarget?.let {
                Text(
                    rcFormat(param!!.prop, it),
                    color = colors.onSurfaceVariant.copy(alpha = 0.65f),
                    fontFamily = FontFamily.Monospace, fontSize = 10.sp,
                    modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 3.dp)
                )
            }
        }
        // 拖拽提示（可写且未拖动时，右侧极淡上下箭头，暗示"可上下拖"）
        if (writable && !dragging) {
            Text(
                "⇅",
                color = colors.onSurfaceVariant.copy(alpha = 0.35f),
                fontSize = 12.sp,
                modifier = Modifier.align(Alignment.CenterEnd).padding(end = 9.dp)
            )
        }
        // 加载占位呼吸：参数未到时"—"缓慢脉动，表达"正在加载"而非死值。
        val loadingAlpha = if (param == null) {
            val pulse = rememberInfiniteTransition(label = "paramLoading")
            pulse.animateFloat(
                initialValue = 0.25f, targetValue = 0.55f,
                animationSpec = infiniteRepeatable(tween(900), RepeatMode.Reverse),
                label = "paramLoadingAlpha"
            ).value
        } else 1f
        // 中心当前值：换值时沿拖动方向滑动（向下拖→新值从下缘滑入、旧值向上滑出），
        // 与边缘淡显的相邻档位方向一致，做出"拨轮走档"的连续感。
        val propCode = param?.prop
        AnimatedContent(
            targetState = param?.current,
            transitionSpec = {
                val vals = param?.values ?: emptyList()
                val from = initialState?.let { vals.indexOf(it) } ?: -1
                val to = targetState?.let { vals.indexOf(it) } ?: -1
                // d>0 = 朝"向下拖"的方向走档；值不明（首载/值域变化）只做淡变
                val d = if (from >= 0 && to >= 0) (to - from) * downSign else 0
                when {
                    d > 0 -> (slideInVertically(tween(130)) { it / 2 } + fadeIn(tween(130)))
                        .togetherWith(slideOutVertically(tween(130)) { -it / 2 } + fadeOut(tween(130)))
                    d < 0 -> (slideInVertically(tween(130)) { -it / 2 } + fadeIn(tween(130)))
                        .togetherWith(slideOutVertically(tween(130)) { it / 2 } + fadeOut(tween(130)))
                    else -> fadeIn(tween(130)) togetherWith fadeOut(tween(130))
                }
            },
            contentAlignment = Alignment.Center,
            label = "paramValue",
            modifier = Modifier.align(Alignment.Center)
        ) { cur ->
            Text(
                if (cur != null && propCode != null) rcFormat(propCode, cur) else "—",
                color = when {
                    param == null -> colors.onSurfaceVariant.copy(alpha = loadingAlpha)
                    !writable -> colors.onSurfaceVariant.copy(alpha = 0.5f)
                    else -> colors.onBackground
                },
                fontFamily = FontFamily.Monospace,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1
            )
        }
    }
}

/**
 * 大圆快门键（两段式）：
 * - 按下（onFocusStart）= 半按对焦；[focusing] 期间内圈收缩 + 边框转蓝，示意"正在合焦"。
 * - 抬手落点在键内 → onRelease(true) 拍摄；移出键外抬手/手势被取消 → onRelease(false) 取消。
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
    // 按压下沉：按住（=半按对焦期间）整键轻微下沉，松开弹性回弹——与 GlassButton 同手感。
    val pressScale by animateFloatAsState(
        targetValue = if (focusing) 0.95f else 1f,
        animationSpec = if (focusing) tween(100) else Motion.bouncy(),
        label = "shutterPress"
    )
    val ringColor = when {
        !enabled -> Color.White.copy(alpha = 0.3f)
        focusing -> AppTheme.colors.accentBlue
        else -> Color.White.copy(alpha = 0.9f)
    }
    Box(
        modifier = Modifier
            .size(76.dp)
            .graphicsLayer {
                scaleX = pressScale
                scaleY = pressScale
            }
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

/** 顶栏小切换按钮（HD / FPS）：激活时蓝字高亮，未激活时低调玻璃底。
 *  规格与顶栏其它控件一致（22dp 圆角 + 36dp 高）。 */
@Composable
private fun TopToggle(label: String, active: Boolean, onClick: () -> Unit) {
    val colors = AppTheme.colors
    GlassButton(
        onClick = onClick,
        shape = RoundedCornerShape(22.dp),
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
        modifier = Modifier.height(36.dp)
    ) {
        Text(
            label,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (active) colors.accentBlue else colors.onSurfaceVariant
        )
    }
}
