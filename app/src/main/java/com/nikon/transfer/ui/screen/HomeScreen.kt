package com.nikon.transfer.ui.screen

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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.nikon.transfer.ui.theme.*
import com.nikon.transfer.viewmodel.CameraViewModel
import com.nikon.transfer.viewmodel.TransferViewModel

/**
 * 连接（引导）页：展示连接状态与引导。左上角 "Z传" 玻璃按钮为设置入口，
 * 与照片列表页完全一致（同一 GlassButton + SettingsOverlay，点击从按钮变形展开设置面板）。
 * 连接成功后自动跳到文件列表，且用户不会再返回本页。
 */
@Composable
fun HomeScreen(
    viewModel: CameraViewModel,
    transferViewModel: TransferViewModel
) {
    val state by viewModel.state.collectAsState()
    val context = LocalContext.current
    var showSettings by remember { mutableStateOf(false) }
    // 双 Z 标按钮在根坐标系中的边界：设置面板贴其下缘展开（下拉弹窗），并以其中心为动画原点。
    var zAnchor by remember { mutableStateOf<Rect?>(null) }

    val connected = state.isConnectedToCamera
    val onCameraWifi = state.isWifiConnected
    val heroColor = when {
        connected -> StatusConnected
        onCameraWifi -> AccentBlue
        else -> AccentOrange
    }
    val heroIcon = when {
        connected -> Icons.Default.CheckCircle
        onCameraWifi -> Icons.Default.Wifi
        else -> Icons.Default.WifiOff
    }
    val pulsing = onCameraWifi && !connected

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
            StatusHero(color = heroColor, icon = heroIcon, pulsing = pulsing, success = connected)

            Box(modifier = Modifier.weight(2f).fillMaxWidth()) {
                Crossfade(
                    targetState = when {
                        connected -> HomeHint.NONE
                        onCameraWifi -> HomeHint.CONNECTING
                        else -> HomeHint.OFF_WIFI
                    },
                    animationSpec = tween(300),
                    label = "homeHint",
                    modifier = Modifier.fillMaxSize()
                ) { hint ->
                    when (hint) {
                        // 已连接：交给成功收尾动画，随后由外层延迟跳转到照片列表。
                        HomeHint.NONE -> Box(modifier = Modifier.fillMaxSize())
                        HomeHint.CONNECTING -> Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = 28.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Text(
                                text = "正在连接相机…",
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.Bold,
                                color = AccentBlue
                            )
                        }
                        HomeHint.OFF_WIFI -> Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = 28.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Text(
                                text = "请连接相机 Wi-Fi",
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.Bold,
                                color = AccentOrange
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
                                Icon(Icons.Default.Wifi, contentDescription = null, tint = AccentBlue, modifier = Modifier.size(20.dp))
                                Text(
                                    "打开 Wi-Fi 设置",
                                    style = MaterialTheme.typography.labelLarge,
                                    fontWeight = FontWeight.Medium,
                                    color = DarkOnBackground
                                )
                            }
                            Spacer(modifier = Modifier.height(24.dp))
                            Column(
                                verticalArrangement = Arrangement.spacedBy(10.dp),
                                horizontalAlignment = Alignment.Start
                            ) {
                                StepRow(1, "相机开启「与智能设备建立 Wi-Fi 连接」")
                                StepRow(2, "手机 Wi-Fi 连接到相机的热点")
                            }
                        }
                    }
                }
            }
        }

        // ---------- 左上角 "Z传" 悬浮按钮（设置入口，与照片列表页一致）----------
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

// 脉冲一轮的周期（秒）与成功时的相位加速倍数。
private const val PULSE_PERIOD_S = 2.2f
private const val BURST_SPEED = 4f

/** 连接页下半区的引导内容形态（Hero 恒定居中，引导只在下半区渐变切换）。 */
private enum class HomeHint { NONE, CONNECTING, OFF_WIFI }

/**
 * 状态 Hero：中心圆盘 + 图标。
 * 脉冲环由"单调累加的连续相位"驱动（跨状态不重建，永不断档）：各环进度取
 * frac(phase + i/3)，透明度用"出生淡入 × 扩散淡出"包络——两端都为 0，循环无缝。
 * [pulsing] 切换时环整体平滑淡入/淡出，绝不硬切。
 * [success]：相位加速 [BURST_SPEED] 倍——正在扩散的环猛地向外冲出（爆发散开）并淡出，
 * 颜色随 animColor 一路转绿；中心图标 Crossfade 渐变换形 + 轻微弹跳。
 */
@Composable
private fun StatusHero(color: Color, icon: ImageVector, pulsing: Boolean, success: Boolean) {
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
    // 环整体透明度：脉冲中为 1；成功爆发时边冲边淡出，离开相机 Wi-Fi 时平滑收场。
    val ringsAlpha by animateFloatAsState(
        targetValue = if (pulsing) 1f else 0f,
        animationSpec = tween(if (success) 550 else 400),
        label = "ringsAlpha"
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
                            val s = 0.55f + p * 0.55f
                            scaleX = s
                            scaleY = s
                            alpha = (p * 5f).coerceAtMost(1f) * (1f - p) * 0.7f * ringsAlpha
                        }
                        .border(3.5.dp, animColor, CircleShape)
                )
            }
        }

        // 成功瞬间图标轻微弹跳（快起 + 弹性回落）。
        val iconPop = remember { Animatable(1f) }
        LaunchedEffect(success) {
            if (success) {
                iconPop.animateTo(1.12f, tween(180, easing = FastOutSlowInEasing))
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
                // 毛玻璃：状态色淡底 + 自上而下白色高光 + 浅色描边。
                .background(animColor.copy(alpha = 0.15f))
                .background(
                    Brush.verticalGradient(
                        listOf(Color.White.copy(alpha = 0.16f), Color.White.copy(alpha = 0.04f))
                    )
                )
                .border(
                    width = 1.dp,
                    brush = Brush.verticalGradient(
                        listOf(Color.White.copy(alpha = 0.4f), Color.White.copy(alpha = 0.1f))
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
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .size(22.dp)
                .clip(CircleShape)
                .background(DarkSurfaceVariant),
            contentAlignment = Alignment.Center
        ) {
            Text(
                "$index",
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.Bold,
                color = AccentBlue
            )
        }
        Spacer(modifier = Modifier.width(10.dp))
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            color = DarkOnSurfaceVariant
        )
    }
}
