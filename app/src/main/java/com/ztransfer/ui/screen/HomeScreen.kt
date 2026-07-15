package com.ztransfer.ui.screen

import android.content.Intent
import android.provider.Settings
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import com.ztransfer.ui.theme.*
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.delay
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
    var showSettings by remember { mutableStateOf(false) }
    // 双 Z 标按钮在根坐标系中的边界：设置面板贴其下缘展开（下拉弹窗），并以其中心为动画原点。
    var zAnchor by remember { mutableStateOf<Rect?>(null) }

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
                        HomeHint.CONNECTING -> Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = 28.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Text(
                                text = stringResource(R.string.connecting_camera),
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.Bold,
                                color = colors.accentBlue
                            )
                        }
                        HomeHint.OFF_WIFI -> Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = 28.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Text(
                                text = stringResource(R.string.connect_camera_wifi),
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.Bold,
                                color = colors.accentOrange
                            )
                            Spacer(modifier = Modifier.height(24.dp))
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
                            Column(
                                verticalArrangement = Arrangement.spacedBy(10.dp),
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

        // ---------- 左上角 "Z传" 悬浮按钮（设置入口，与照片列表页一致）；
        // 右上角：免费版显示"解锁高级版"金徽标。本页尚未连相机热点、多半还有外网，
        // 因此是全 app 唯一放"输入激活码"入口的弹窗（其余页面连着相机 Wi-Fi 无外网）----------
        var showPro by remember { mutableStateOf(false) }
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
            if (!isPro) {
                ProBadgeButton(
                    label = stringResource(R.string.unlock_pro),
                    onClick = { showPro = true }
                )
            }
        }
        if (showPro) {
            ProDialog(onDismiss = { showPro = false }, showEnterCode = true)
        }

        // ---------- 设置面板：从 "Z传" 按钮位置变形展开 ----------
        if (showSettings) {
            SettingsOverlay(
                viewModel = transferViewModel,
                anchorBounds = zAnchor,
                onDismiss = { showSettings = false }
            )
        }
    }
}

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

/** 引导步骤行：序号圆点 + 说明文字。 */
@Composable
private fun StepRow(index: Int, text: String) {
    val colors = AppTheme.colors
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .size(22.dp)
                .clip(CircleShape)
                .background(colors.surfaceVariant),
            contentAlignment = Alignment.Center
        ) {
            Text(
                "$index",
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.Bold,
                color = colors.accentBlue
            )
        }
        Spacer(modifier = Modifier.width(10.dp))
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            color = colors.onSurfaceVariant
        )
    }
}
