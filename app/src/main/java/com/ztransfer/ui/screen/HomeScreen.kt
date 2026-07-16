package com.ztransfer.ui.screen

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import com.ztransfer.ui.theme.*
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.cos
import kotlin.math.sin

/**
 * 连接（引导）页：展示连接状态与引导。左上角 "Z传" 玻璃按钮为设置入口，
 * 与照片列表页完全一致（同一 GlassButton + SettingsOverlay，点击从按钮变形展开设置面板）。
 * 连接成功后自动跳到文件列表，且用户不会再返回本页。
 * 右上角"解锁高级版"徽标（免费版）打开的弹窗是全 app 唯一带"输入激活码"的入口——
 * 本页尚未连相机热点，多半还有外网；进入 app 深处后连着相机 Wi-Fi 无法在线激活。
 */
@Composable
fun HomeScreen(
    viewModel: CameraViewModel,
    transferViewModel: TransferViewModel
) {
    val state by viewModel.state.collectAsState()
    val context = LocalContext.current
    // 右上角"解锁高级版"入口的显隐 + 成功爆发的金色粒子彩蛋都依赖它。
    val isPro by LicenseManager.isPro.collectAsState()
    // 曾购买、通行证过期且续签联不上网 → 顶部提示连网续期(连上重开自动恢复)。
    val renewalNeeded by LicenseManager.renewalNeeded.collectAsState()
    var showSettings by remember { mutableStateOf(false) }
    // 双 Z 标按钮在根坐标系中的边界：设置面板贴其下缘展开（下拉弹窗），并以其中心为动画原点。
    var zAnchor by remember { mutableStateOf<Rect?>(null) }
    // 连接页「小技巧」气泡：从 tips 按钮变形弹出（复用 AnchorPopup 的全局毛玻璃）。
    var showTips by remember { mutableStateOf(false) }
    var tipsAnchor by remember { mutableStateOf<Rect?>(null) }

    val colors = AppTheme.colors
    val connected = state.isConnectedToCamera
    val onCameraWifi = state.isWifiConnected
    // 成功庆祝刻意延后：连接后先保持"连接中"的脉冲一小会——此时文件列表与缩略图
    // 已在后台全速加载（连接成功瞬间就启动，与本页停留无关）——再播爆发收尾，
    // 否则动画一闪而过根本看不清。跳转时机在 MainScreen 与此对齐。
    var celebrate by remember { mutableStateOf(false) }
    LaunchedEffect(connected) {
        if (connected) {
            delay(CONNECT_CELEBRATE_DELAY_MS)
            celebrate = true
        } else {
            celebrate = false
        }
    }
    val heroColor = when {
        celebrate -> colors.statusConnected
        onCameraWifi || connected -> colors.accentBlue
        else -> colors.accentOrange
    }
    val heroIcon = when {
        celebrate -> Icons.Default.CheckCircle
        onCameraWifi || connected -> Icons.Default.Wifi
        else -> Icons.Default.WifiOff
    }
    val pulsing = (onCameraWifi || connected) && !celebrate

    Box(modifier = Modifier.fillMaxSize()) {
        // ---------- 中央 Hero：上下弹性区按 1:2 定位——Hero 中心落在屏幕约 35~38% 高度
        // 的视觉重心（光学中心），顶部不空旷、下方给引导文案充裕空间。权重是常数，
        // 状态切换 Hero 依然一动不动；引导在下方区域用 Crossfade 渐变出现/消失 ----------
        Column(
            modifier = Modifier
                .fillMaxSize()
                .systemBarsPadding()
                .padding(horizontal = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Spacer(modifier = Modifier.weight(1f))

            // 连接中脉冲；连接成功时播放"脉冲爆发散开 + 图标渐变绿"的收尾动画。
            // 高级版彩蛋:爆发时附一圈金色粒子(正向差异,免费版无感知)。
            StatusHero(
                color = heroColor, icon = heroIcon,
                pulsing = pulsing, success = celebrate, goldBurst = isPro
            )

            // 高级版过期且离线:提示连网续期(不惩罚正版——连上重开即自动恢复)。
            if (renewalNeeded) {
                Spacer(modifier = Modifier.height(14.dp))
                Text(
                    text = stringResource(R.string.renewal_needed),
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.accentOrange,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .background(
                            colors.accentOrange.copy(alpha = 0.12f),
                            RoundedCornerShape(10.dp)
                        )
                        .padding(horizontal = 14.dp, vertical = 8.dp)
                )
            }

            Box(modifier = Modifier.weight(2f).fillMaxWidth()) {
                Crossfade(
                    targetState = when {
                        celebrate -> HomeHint.NONE
                        // 已连接但还没到庆祝时刻：视觉上仍是"正在连接"的延续，无缝衔接。
                        onCameraWifi || connected -> HomeHint.CONNECTING
                        else -> HomeHint.OFF_WIFI
                    },
                    animationSpec = tween(300),
                    label = "homeHint",
                    modifier = Modifier.fillMaxSize()
                ) { hint ->
                    when (hint) {
                        // 已连接：全交给成功爆发动画——绿色对号 = 马上进入照片列表
                        //（MainScreen 在动画播完后直接跳转），无需任何文字。
                        HomeHint.NONE -> Box(modifier = Modifier.fillMaxSize())
                        // top padding 与 OFF_WIFI 态一致（4dp）：两态 Crossfade 切换时内容不上下跳。
                        HomeHint.CONNECTING -> Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = 4.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Text(
                                text = stringResource(R.string.connecting_camera),
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.Bold,
                                color = colors.accentBlue
                            )
                        }
                        // 去掉「请连接相机 Wi-Fi」标题——它与下方步骤重复；步骤本身放大加重、
                        // 整体上移，作为本页主引导，页面更紧凑和谐。
                        HomeHint.OFF_WIFI -> Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = 4.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            // 一键去系统 Wi-Fi 设置 + 两步引导。
                            GlassButton(
                                onClick = {
                                    try {
                                        context.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                                    } catch (_: Exception) {}
                                }
                            ) {
                                Icon(Icons.Default.Wifi, contentDescription = null, tint = colors.accentBlue, modifier = Modifier.size(20.dp))
                                Text(
                                    stringResource(R.string.open_wifi_settings),
                                    style = MaterialTheme.typography.labelLarge,
                                    fontWeight = FontWeight.Medium,
                                    color = colors.onBackground
                                )
                            }
                            Spacer(modifier = Modifier.height(24.dp))
                            // 步骤区：左侧纯灯泡圆钮 = "小技巧"入口（点击弹毛玻璃气泡）。
                            // 圆钮固定 22dp（与 StepRow 序号圆钮同尺寸），顶对齐后与"步骤 1"
                            // 整行并排、行心一致。size 必须显式给：M3 可点击 Surface 内置
                            // 48dp 最小交互尺寸，无约束时节点被撑大——圆钮四周多出一圈
                            // 不可见留白，既顶歪行心又把它推得离序号很远；固定约束可压制它。
                            Row(verticalAlignment = Alignment.Top) {
                                GlassButton(
                                    onClick = { showTips = true },
                                    shape = CircleShape,
                                    contentPadding = PaddingValues(4.dp),
                                    modifier = Modifier
                                        .size(22.dp)
                                        .onGloballyPositioned { tipsAnchor = it.boundsInRoot() }
                                ) {
                                    Icon(Icons.Default.Lightbulb, contentDescription = null, tint = colors.accentOrange, modifier = Modifier.size(14.dp))
                                }
                                Spacer(modifier = Modifier.width(10.dp))
                                Column(
                                    verticalArrangement = Arrangement.spacedBy(14.dp),
                                    horizontalAlignment = Alignment.Start
                                ) {
                                    StepRow(1, stringResource(R.string.step_camera_wifi))
                                    StepRow(2, stringResource(R.string.step_phone_wifi))
                                }
                            }
                        }
                    }
                }
            }
        }

        // ---------- 左上角 "Z传" 悬浮按钮（设置入口，与照片列表页一致）；
        // 右上角：免费版显示"解锁高级版"金徽标。本页尚未连相机热点、多半还有外网，
        // 因此是全 app 唯一放"输入激活码"入口的弹窗（其余页面连着相机 Wi-Fi 无外网）----------
        var showPro by remember { mutableStateOf(false) }
        // 已解锁：金徽标改显"高级版"，点击不弹窗，每点一次放一发独立烟花（可连点并发）。
        // 设置面板里的同款徽标也共用这一实例（见 SettingsOverlay 的 onPlayFireworks）。
        val fireworks = rememberFireworksState()
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            GlassButton(
                onClick = { showSettings = true },
                shape = RoundedCornerShape(22.dp),
                // 与文件列表页的双 Z 标按钮完全同规格（顶栏统一 36dp 高，见彼处注释）。
                contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
                modifier = Modifier
                    .height(36.dp)
                    .onGloballyPositioned { zAnchor = it.boundsInRoot() }
            ) {
                // 双 Z 标（原"Z传"文本，换成自绘的尼康 Z 系列标志更简洁）。
                ZMark(modifier = Modifier.height(20.dp))
            }
            Spacer(modifier = Modifier.weight(1f))
            // 免费版：金徽标"解锁高级版"，点击开介绍弹窗（全 app 唯一激活码入口）。
            // 已解锁：金徽标"高级版"，点击不弹窗，放烟花彩蛋。
            if (!isPro) {
                ProBadgeButton(
                    label = stringResource(R.string.unlock_pro),
                    onClick = { showPro = true }
                )
            } else {
                ProBadgeButton(
                    label = stringResource(R.string.pro_label),
                    onClick = { fireworks.launch() }
                )
            }
        }
        if (showPro) {
            ProDialog(
                onDismiss = { showPro = false },
                showEnterCode = true,
                onCelebrate = { fireworks.launch() }
            )
        }

        // ---------- 设置面板：从 "Z传" 按钮位置变形展开 ----------
        if (showSettings) {
            SettingsOverlay(
                viewModel = transferViewModel,
                anchorBounds = zAnchor,
                onDismiss = { showSettings = false },
                onPlayFireworks = { fireworks.launch() }
            )
        }

        // ---------- 小技巧气泡：从 tips 按钮变形弹出的毛玻璃内容框 ----------
        if (showTips) {
            TipsBubble(anchorBounds = tipsAnchor, onDismiss = { showTips = false })
        }

        // ---------- 检查更新：底部居中的低调小入口。放本页与激活码入口同一逻辑——
        // 这是全 app 唯一确定有外网的页面(其余页面连着相机 Wi-Fi)。
        // 结果轻反馈走底部玻璃提示条(已最新/检查失败);有新版弹对话框跳网盘下载 ----------
        if (SHOW_UPDATE_CHECK) {
            var checkingUpdate by remember { mutableStateOf(false) }
            var updateInfo by remember { mutableStateOf<LicenseManager.UpdateInfo?>(null) }
            // 提示条文案与可见性分开存,消失动画期间仍有文字可渲染;nonce 重启计时(全局同款模式)。
            var updateHintText by remember { mutableStateOf("") }
            var updateHintVisible by remember { mutableStateOf(false) }
            var updateHintNonce by remember { mutableStateOf(0) }
            LaunchedEffect(updateHintNonce) {
                if (updateHintVisible) {
                    delay(1800)
                    updateHintVisible = false
                }
            }
            val updateScope = rememberCoroutineScope()
            val latestHint = stringResource(R.string.update_latest)
            val checkFailedHint = stringResource(R.string.update_check_failed)
            GlassButton(
                onClick = {
                    if (!checkingUpdate) {
                        checkingUpdate = true
                        updateScope.launch {
                            when (val r = LicenseManager.checkAppUpdate(BuildConfig.VERSION_CODE)) {
                                is LicenseManager.UpdateResult.Available -> updateInfo = r.info
                                LicenseManager.UpdateResult.UpToDate -> {
                                    updateHintText = latestHint
                                    updateHintVisible = true
                                    updateHintNonce++
                                }
                                LicenseManager.UpdateResult.Unreachable -> {
                                    updateHintText = checkFailedHint
                                    updateHintVisible = true
                                    updateHintNonce++
                                }
                            }
                            checkingUpdate = false
                        }
                    }
                },
                shape = RoundedCornerShape(14.dp),
                contentPadding = PaddingValues(horizontal = 14.dp),
                // 与设置页脚"反馈"按钮同规格(28dp 高小胶囊);次要文字色保持低调,不与主引导抢视线。
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .navigationBarsPadding()
                    .padding(bottom = 16.dp)
                    .height(28.dp)
            ) {
                Text(
                    stringResource(if (checkingUpdate) R.string.checking_update else R.string.check_update),
                    style = MaterialTheme.typography.labelMedium,
                    color = colors.onSurfaceVariant
                )
            }
            // 结果提示条(与列表页底部玻璃提示同款),浮在入口按钮上方。
            AnimatedVisibility(
                visible = updateHintVisible,
                enter = fadeIn() + slideInVertically { it / 2 },
                exit = fadeOut() + slideOutVertically { it / 2 },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .navigationBarsPadding()
                    .padding(bottom = 56.dp)
            ) {
                Surface(
                    shape = RoundedCornerShape(18.dp),
                    color = colors.glassSurfaceHeavy,
                    shadowElevation = 6.dp,
                    border = BorderStroke(1.dp, colors.glassPanelBorder)
                ) {
                    Text(
                        updateHintText,
                        style = MaterialTheme.typography.labelLarge,
                        color = colors.onBackground,
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp)
                    )
                }
            }
            updateInfo?.let { info ->
                UpdateDialog(info = info, onDismiss = { updateInfo = null })
            }
        }

        // ---------- 高级版烟花彩蛋：放在最上层（含设置面板之上），不拦截触摸，播完自行移除 ----------
        FireworksOverlay(fireworks)
    }
}

// 检查更新入口的显隐开关:功能已接好(服务器接口/对话框/提示条齐备),但版本尚未稳定,
// 先不对用户暴露。稳定后置 true 即恢复显示,勿删相关代码。
private const val SHOW_UPDATE_CHECK = false

// 连接成功后的入场节奏：先保持"连接中"脉冲 [CONNECT_CELEBRATE_DELAY_MS]（此间列表与
// 缩略图已在后台全速加载），再播约 [CONNECT_SUCCESS_ANIM_MS] 的爆发收尾——播完由
// MainScreen 跳转到照片列表。两个值相加即连接成功后在本页的总停留。
const val CONNECT_CELEBRATE_DELAY_MS = 500L
const val CONNECT_SUCCESS_ANIM_MS = 850L

// 脉冲一轮的周期（秒）与成功时的相位加速倍数。
private const val PULSE_PERIOD_S = 2.2f
private const val BURST_SPEED = 5.5f
// 成功爆发时环的额外扩散范围：最远飞到基准尺寸的约 2.3 倍，明显冲出圆盘。
private const val BURST_EXTRA_RANGE = 1.2f

/** 连接页下半区的引导内容形态（Hero 恒定居中，引导只在下半区渐变切换）。 */
private enum class HomeHint { NONE, CONNECTING, OFF_WIFI }

/**
 * 状态 Hero：中心圆盘 + 图标。
 * 脉冲环由"单调累加的连续相位"驱动（跨状态不重建，永不断档）：各环进度取
 * frac(phase + i/3)，透明度用"出生淡入 × 扩散淡出"包络——两端都为 0，循环无缝。
 * [pulsing] 切换时环整体平滑淡入/淡出，绝不硬切。
 * [success]：相位加速 [BURST_SPEED] 倍——正在扩散的环猛地向外冲出（爆发散开）并淡出，
 * 颜色随 animColor 一路转绿；中心图标 Crossfade 渐变换形 + 轻微弹跳。
 * [goldBurst]：高级版彩蛋——爆发时一圈金色粒子从圆盘后迸出（与"解锁高级版"徽标
 * 同色系的正向差异,免费版不显示,无任何"惩罚感"设计）。
 */
@Composable
private fun StatusHero(
    color: Color,
    icon: ImageVector,
    pulsing: Boolean,
    success: Boolean,
    goldBurst: Boolean = false
) {
    val colors = AppTheme.colors
    val animColor by animateColorAsState(targetValue = color, animationSpec = tween(500), label = "heroColor")

    // 连续相位：每帧按当前速度累加，成功时速度平滑升到 BURST_SPEED。
    var phase by remember { mutableStateOf(0f) }
    val speed by animateFloatAsState(
        targetValue = if (success) BURST_SPEED else 1f,
        animationSpec = tween(250),
        label = "pulseSpeed"
    )
    val currentSpeed by rememberUpdatedState(speed)
    LaunchedEffect(Unit) {
        var last = 0L
        while (true) {
            withFrameNanos { now ->
                if (last != 0L) {
                    phase += (now - last) / 1_000_000_000f / PULSE_PERIOD_S * currentSpeed
                }
                last = now
            }
        }
    }
    // 环整体透明度：脉冲中为 1；成功爆发时边冲边淡出（拉长到 700ms 让"飞出"读得完整），
    // 离开相机 Wi-Fi 时平滑收场。
    val ringsAlpha by animateFloatAsState(
        targetValue = if (pulsing) 1f else 0f,
        animationSpec = tween(if (success) 700 else 400),
        label = "ringsAlpha"
    )
    // 爆发进度：成功瞬间 0→1，驱动环的扩散范围外扩（冲出圆盘）与亮度增强。
    val burst by animateFloatAsState(
        targetValue = if (success) 1f else 0f,
        animationSpec = tween(650, easing = FastOutSlowInEasing),
        label = "burst"
    )

    Box(modifier = Modifier.size(200.dp), contentAlignment = Alignment.Center) {
        if (ringsAlpha > 0.01f) {
            repeat(3) { i ->
                Box(
                    modifier = Modifier
                        .size(180.dp)
                        .graphicsLayer {
                            // 相位在 graphicsLayer 块内读取：逐帧只更新图层，不触发重组。
                            val p = (phase + i / 3f).mod(1f)
                            // 出生尺寸 0.55×180=99dp——刚好在 96dp 中心圆盘外缘冒头。
                            // 再小的话，环最亮的前 20% 行程全藏在圆盘后面，脉冲显得又弱又淡。
                            // 成功爆发：扩散终点随 burst 外扩到 ~2.3 倍，环猛地冲出圆盘很远，
                            // 亮度同时增强——能量迸发感，而不是普通脉冲的延续。
                            val s = 0.55f + p * (0.55f + BURST_EXTRA_RANGE * burst)
                            scaleX = s
                            scaleY = s
                            alpha = (p * 5f).coerceAtMost(1f) * (1f - p) *
                                    (0.7f + 0.3f * burst) * ringsAlpha
                        }
                        .border(3.5.dp, animColor, CircleShape)
                )
            }
        }

        // 高级版彩蛋:成功爆发时 12 颗金色粒子从圆盘后向四周迸出,随 burst 飞散、
        // 收缩、抛物线式明灭(峰值在前 1/4 行程),与环的爆发同拍。角度带确定性
        // 抖动、距离/大小分三层,免随机数也不呆板。断开时 success 立灭,不播回吸。
        if (goldBurst && success) {
            repeat(12) { i ->
                Box(
                    modifier = Modifier
                        .size(if (i % 3 == 0) 7.dp else 5.dp)
                        .graphicsLayer {
                            val angleRad = (i * 30f + if (i % 2 == 0) 9f else -7f) *
                                    (Math.PI.toFloat() / 180f)
                            val dist = (58 + (i % 3) * 16).dp.toPx() * burst
                            translationX = cos(angleRad) * dist
                            translationY = sin(angleRad) * dist
                            val s = 1f - 0.45f * burst
                            scaleX = s
                            scaleY = s
                            alpha = (burst * 4f).coerceAtMost(1f) * (1f - burst)
                        }
                        .clip(CircleShape)
                        .background(if (i % 2 == 0) Color(0xFFFFE082) else Color(0xFFF0A93B))
                )
            }
        }

        // 成功瞬间图标有力地弹跳（快起 + 弹性回落），与环的爆发同拍。
        val iconPop = remember { Animatable(1f) }
        LaunchedEffect(success) {
            if (success) {
                iconPop.animateTo(1.22f, tween(160, easing = FastOutSlowInEasing))
                iconPop.animateTo(1f, spring(dampingRatio = Spring.DampingRatioMediumBouncy))
            }
        }

        Box(
            modifier = Modifier
                .size(96.dp)
                .graphicsLayer {
                    scaleX = iconPop.value
                    scaleY = iconPop.value
                }
                .clip(CircleShape)
                // 毛玻璃：高光打底、状态色淡罩在上——浅色主题的高光较浓（白 60%），
                // 若把状态色垫在高光下面会被洗成一片白，圆盘失去状态感；
                // 深色主题两层透明度都很低，先后顺序视觉上无差别。
                .background(
                    Brush.verticalGradient(
                        listOf(colors.glassHighlightTop, colors.glassHighlightBottom)
                    )
                )
                .background(animColor.copy(alpha = 0.15f))
                .border(
                    width = 1.dp,
                    brush = Brush.verticalGradient(
                        listOf(colors.glassBorderTop, colors.glassBorderBottom)
                    ),
                    shape = CircleShape
                ),
            contentAlignment = Alignment.Center
        ) {
            // 图标渐变换形（Wifi→√ 等一律交叉淡化），配合 tint 颜色过渡，不再硬切。
            Crossfade(targetState = icon, animationSpec = tween(450), label = "heroIcon") { ic ->
                Icon(ic, contentDescription = null, tint = animColor, modifier = Modifier.size(44.dp))
            }
        }
    }
}

/** 引导步骤行：序号蓝底圆点 + 说明文字（去掉标题后步骤是本页主引导，故放大加重更显眼）。 */
@Composable
private fun StepRow(index: Int, text: String) {
    val colors = AppTheme.colors
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .size(22.dp)
                .clip(CircleShape)
                .background(colors.accentBlue.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center
        ) {
            Text(
                "$index",
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.Bold,
                color = colors.accentBlue
            )
        }
        Spacer(modifier = Modifier.width(10.dp))
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold,
            color = colors.onBackground
        )
    }
}

/**
 * 发现新版本对话框:版本号 + 更新说明 + "去下载"跳浏览器打开网盘分享页。
 * 分享链接带提取码时,点"去下载"先把提取码写进剪贴板再跳转(对话框内先行明示)。
 * 不做 App 内下载:网盘无稳定直链,浏览器下载 + 手动点安装是最小成本路径。
 */
@Composable
private fun UpdateDialog(info: LicenseManager.UpdateInfo, onDismiss: () -> Unit) {
    val colors = AppTheme.colors
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(22.dp),
            color = colors.glassSurfaceHeavy,
            border = BorderStroke(1.dp, colors.glassPanelBorder)
        ) {
            Column(Modifier.padding(20.dp)) {
                Text(
                    stringResource(R.string.update_found_title, info.versionName),
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    color = colors.onBackground
                )
                if (info.notes.isNotBlank()) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        info.notes,
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.onSurfaceVariant
                    )
                }
                if (info.password.isNotEmpty()) {
                    Spacer(Modifier.height(10.dp))
                    Text(
                        stringResource(R.string.update_password_hint, info.password),
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.accentOrange
                    )
                }
                Spacer(Modifier.height(16.dp))
                Row(
                    modifier = Modifier.align(Alignment.End),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    TextButton(onClick = onDismiss) {
                        Text(stringResource(R.string.cancel), color = colors.onSurfaceVariant)
                    }
                    Button(
                        onClick = {
                            // 先复制提取码再跳转:落到网盘页时码已在剪贴板,粘贴即可。
                            if (info.password.isNotEmpty()) {
                                clipboard.setText(AnnotatedString(info.password))
                            }
                            runCatching {
                                context.startActivity(
                                    Intent(Intent.ACTION_VIEW, Uri.parse(info.url))
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                            }
                            onDismiss()
                        },
                        colors = ButtonDefaults.buttonColors(containerColor = colors.accentBlue),
                        shape = RoundedCornerShape(10.dp)
                    ) {
                        Text(stringResource(R.string.update_download))
                    }
                }
            }
        }
    }
}

/**
 * 连接页「小技巧」气泡：从 tips 按钮变形弹出的毛玻璃内容框（复用全局 [AnchorPopup]）。
 * 介绍把「Wi-Fi 连接」加进相机 i 菜单以省去层层翻菜单，并给出设置路径；内容全部走多语言资源。
 */
@Composable
private fun TipsBubble(anchorBounds: Rect?, onDismiss: () -> Unit) {
    val colors = AppTheme.colors
    val density = LocalDensity.current
    val panelTop = anchorBounds?.let { with(density) { it.bottom.toDp() } + 8.dp } ?: 140.dp
    AnchorPopup(
        anchorBounds = anchorBounds,
        onDismiss = onDismiss,
        panelModifier = Modifier
            .padding(start = 20.dp, end = 20.dp, top = panelTop)
            .navigationBarsPadding()
            .fillMaxWidth(),
        shape = RoundedCornerShape(18.dp)
    ) { _ ->
        Column(modifier = Modifier.padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Lightbulb, contentDescription = null, tint = colors.accentOrange, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(
                    stringResource(R.string.tip_title),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold,
                    color = colors.onBackground
                )
            }
            Spacer(Modifier.height(10.dp))
            Text(
                stringResource(R.string.tip_body),
                style = MaterialTheme.typography.bodyMedium,
                color = colors.onSurfaceVariant
            )
            Spacer(Modifier.height(12.dp))
            // 设置路径：内嵌浅底卡片承载，箭头分隔的菜单路径，蓝色加重以便照着相机菜单一步步走。
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(colors.onBackground.copy(alpha = 0.05f))
                    .padding(horizontal = 12.dp, vertical = 10.dp)
            ) {
                Text(
                    stringResource(R.string.tip_path),
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Medium,
                    color = colors.accentBlue
                )
            }
        }
    }
}
