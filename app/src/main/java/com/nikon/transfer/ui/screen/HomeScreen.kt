package com.nikon.transfer.ui.screen

import android.content.Intent
import android.provider.Settings
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.StartOffset
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
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
    var zAnchor by remember { mutableStateOf<Offset?>(null) }

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
        // ---------- 中央 Hero ----------
        Column(
            modifier = Modifier
                .fillMaxSize()
                .systemBarsPadding()
                .padding(horizontal = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            // 连接中脉冲；连接成功时播放一次性"快速发散 + 图标渐变绿"的收尾动画。
            StatusHero(color = heroColor, icon = heroIcon, pulsing = pulsing, success = connected)

            // 已连接后不再显示状态文字——交给成功收尾动画，随后由外层延迟跳转到照片列表。
            if (!connected) {
                Spacer(modifier = Modifier.height(28.dp))

                Text(
                    text = if (onCameraWifi) "正在连接相机…" else "请连接相机 Wi-Fi",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    color = heroColor
                )

                // 未连相机 Wi-Fi 时：一键去系统 Wi-Fi 设置 + 两步引导。
                if (!onCameraWifi) {
                    Spacer(modifier = Modifier.height(24.dp))
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
                contentPadding = PaddingValues(horizontal = 18.dp, vertical = 9.dp),
                modifier = Modifier.onGloballyPositioned { zAnchor = it.boundsInRoot().center }
            ) {
                Text(
                    "Z传",
                    fontWeight = FontWeight.Bold,
                    style = MaterialTheme.typography.titleMedium,
                    color = DarkOnBackground
                )
            }
        }

        // ---------- 设置面板：从 "Z传" 按钮位置变形展开 ----------
        if (showSettings) {
            SettingsOverlay(
                viewModel = transferViewModel,
                anchorCenter = zAnchor,
                onDismiss = { showSettings = false }
            )
        }
    }
}

/**
 * 状态 Hero：中心圆盘 + 图标。
 * [pulsing]：连接中——外围雷达式持续脉冲。
 * [success]：连接成功——播放一次性"快速发散"环 + 图标弹跳一下，颜色平滑渐变到绿色。
 */
@Composable
private fun StatusHero(color: Color, icon: ImageVector, pulsing: Boolean, success: Boolean) {
    val animColor by animateColorAsState(targetValue = color, animationSpec = tween(500), label = "heroColor")
    val burst = remember { Animatable(0f) }
    LaunchedEffect(success) {
        if (success) {
            burst.snapTo(0f)
            burst.animateTo(1f, tween(750, easing = FastOutSlowInEasing))
        }
    }

    Box(modifier = Modifier.size(200.dp), contentAlignment = Alignment.Center) {
        if (pulsing) {
            val transition = rememberInfiniteTransition(label = "pulse")
            repeat(3) { i ->
                val p by transition.animateFloat(
                    initialValue = 0f,
                    targetValue = 1f,
                    animationSpec = infiniteRepeatable(
                        animation = tween(2200, easing = LinearEasing),
                        initialStartOffset = StartOffset(i * 2200 / 3)
                    ),
                    label = "ring$i"
                )
                Box(
                    modifier = Modifier
                        .size(180.dp)
                        .graphicsLayer {
                            val s = 0.35f + p * 0.65f
                            scaleX = s
                            scaleY = s
                            alpha = (1f - p) * 0.45f
                        }
                        .border(2.dp, color, CircleShape)
                )
            }
        }

        if (success) {
            val b = burst.value
            repeat(3) { i ->
                val d = ((b - i * 0.12f) / (1f - i * 0.12f)).coerceIn(0f, 1f)
                if (d > 0f) {
                    Box(
                        modifier = Modifier
                            .size(200.dp)
                            .graphicsLayer {
                                val s = 0.25f + d * 1.05f
                                scaleX = s
                                scaleY = s
                                alpha = (1f - d) * 0.6f
                            }
                            .border(2.5.dp, StatusConnected, CircleShape)
                    )
                }
            }
        }

        val iconScale = if (success) {
            val b = burst.value
            if (b < 0.3f) 0.7f + (b / 0.3f) * 0.45f
            else 1.15f - ((b - 0.3f) / 0.7f) * 0.15f
        } else 1f
        Box(
            modifier = Modifier
                .size(96.dp)
                .graphicsLayer {
                    scaleX = iconScale
                    scaleY = iconScale
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
            Icon(icon, contentDescription = null, tint = animColor, modifier = Modifier.size(44.dp))
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
