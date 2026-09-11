package com.ztransfer.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.*
import androidx.compose.ui.graphics.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.ui.theme.*

data class SignalPillText(
    val notConnected: String,
    val usb: String,
    val staConnected: String,
    val staDisconnected: String,
    val signalUnavailable: String,
)

private val TOP_BAR_COMPACT_BUTTON_MIN_WIDTH = 40.dp

data class SignalBarPalette(
    val lit: Color,
    val unlit: Color,
)

/** 木纹表面使用与胡桃/蜂蜜底色反向的指示灯色，档位靠明暗和格数共同表达。 */
fun signalBarPalette(
    skin: SkinPreset,
    dark: Boolean,
    level: Int,
    defaultLit: Color,
    defaultUnlit: Color,
): SignalBarPalette {
    if (skin != SkinPreset.WOOD) return SignalBarPalette(defaultLit, defaultUnlit)

    val lit = if (dark) {
        when {
            level >= 4 -> Color(0xFFA8E7BC) // 胡桃木上的柔和薄荷绿
            level >= 2 -> Color(0xFFFFD58A) // 暖金色，与木纹同族但亮度充分
            else -> Color(0xFFFF9D91)       // 低信号保持克制的珊瑚红警示
        }
    } else {
        when {
            level >= 4 -> Color(0xFF164F32) // 蜂蜜木上的深森林绿
            level >= 2 -> Color(0xFF4B2A12) // 深琥珀棕，不与橙色木纹融在一起
            else -> Color(0xFF8A2025)       // 深酒红，弱信号仍清楚可辨
        }
    }
    val unlitBase = if (dark) Color(0xFFFFE4B5) else Color(0xFF321D10)
    return SignalBarPalette(lit = lit, unlit = unlitBase.copy(alpha = 0.34f))
}

@Composable
fun SharedSignalPill(
    text: SignalPillText,
    onOpenWifiSettings: () -> Unit,
    allowUnknownRssi: Boolean = false,
    rssi: Int?,
    connected: Boolean,
    pulseTrigger: Int = 0,
    connectionType: CameraConnectionType? = null,
    staMode: Boolean = false,
    onStaDisconnectedClick: () -> Unit = {},
) {
    val colors = AppTheme.colors
    var expanded by remember { mutableStateOf(false) }
    val usbMode = connectionType == CameraConnectionType.USB
    val online = signalPillOnline(connected, usbMode, staMode, rssi, allowUnknownRssi)
    val unknownSignal = online && !usbMode && !staMode && rssi == null
    val r = rssi ?: -999
    // dBm 越接近 0 越强。判定从严：满格只给极好信号，稍差立刻掉格。
    //  -30↑ 满格 / -45↑ 三格 / -55↑ 两格 / -65↑ 一格 / 更弱 0 格。
    val level = when {
        r >= -30 -> 4
        r >= -45 -> 3
        r >= -55 -> 2
        r >= -65 -> 1
        else -> 0
    }
    val color = when {
        usbMode && connected -> colors.accentBlue
        usbMode -> colors.statusError
        staMode && connected -> colors.accentBlue
        staMode -> colors.statusError
        unknownSignal -> colors.accentBlue
        level == 4 -> colors.statusConnected
        level >= 2 -> colors.accentOrange
        else -> colors.statusError
    }
    val skin = LocalButtonTexturePalette.current?.skin ?: SkinPreset.FROSTED_GLASS
    val dark = colors.background.luminance() < 0.5f
    val signalBars = remember(skin, dark, level, color, colors.onSurfaceVariant) {
        signalBarPalette(
            skin = skin,
            dark = dark,
            level = level,
            defaultLit = color,
            defaultUnlit = colors.onSurfaceVariant.copy(alpha = 0.28f),
        )
    }

    // 强调动画：trigger 递增时轻微放大、再弹性缩回（比左右抖动柔和）。
    val pulse = remember { Animatable(1f) }
    LaunchedEffect(pulseTrigger) {
        if (pulseTrigger > 0) {
            pulse.animateTo(1.15f, tween(120, easing = FastOutSlowInEasing))
            pulse.animateTo(1f, Motion.bouncy())
        }
    }
    // 断开呼吸：整个按钮持续轻微放大缩小，把“该重连相机了”顶到眼前。仅断开时
    // 组合 infinite transition，在线零开销；值在 graphicsLayer
    // 里读，每帧只更新图层不重组。与 pulse 强调相乘叠加，互不打架。
    val breath = if (!online) {
        rememberInfiniteTransition(label = "signalBreath").animateFloat(
            initialValue = 1f, targetValue = 1.09f,
            animationSpec = infiniteRepeatable(tween(550, easing = FastOutSlowInEasing), RepeatMode.Reverse),
            label = "signalBreathScale"
        )
    } else null

    GlassButton(
        onClick = {
            if (staMode) {
                expanded = false
                if (!connected) {
                    onStaDisconnectedClick()
                }
            } else if (online && !unknownSignal) expanded = !expanded
            // 断开态：断连图标即"去连 Wi-Fi"的入口，跳系统 Wi-Fi 设置（与连接页
            // 的 Wi-Fi 按钮同款行为）；离线时展开 dBm 本来就无意义。
            else if (!online && !usbMode) onOpenWifiSettings()
        },
        shape = RoundedCornerShape(22.dp),
        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 9.dp),
        enforceMinimumTouchTarget = false,
        // 顶栏按钮统一 36dp 高；信号条内容 15dp，在按钮内垂直居中。
        modifier = Modifier
            .height(36.dp)
            // 收起状态与筛选按钮共用 40dp 宽度基线；展开的 dBm 文本仍可自然增宽。
            .widthIn(min = TOP_BAR_COMPACT_BUTTON_MIN_WIDTH)
            .graphicsLayer {
                val s = pulse.value * (breath?.value ?: 1f)
                scaleX = s
                scaleY = s
            }
    ) {
        // dBm 文本用 AnimatedVisibility 逐帧驱动宽度+透明度，按钮宽度随内容自然过渡。
        // 不能用 animateContentSize + if(expanded)：那是"内容瞬间增删、容器尺寸补动画"，
        // 文字会凭空闪现/先消失再缩壳，且外层 spacedBy 间距在元素移除瞬间跳变。
        // 单一子元素（外层 spacedBy 不参与），文字的起始间距放进动画宽度内一起过渡。
        // 内容高度锁定为信号条高度：文字比信号条略高，靠 unbounded 溢出居中进 padding，
        // 展开/收起时按钮高度不跳动。
        Row(
            modifier = Modifier.height(15.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // AP、STA、USB 各自使用独立图形；连接状态变化时交叉淡化切换。
            Crossfade(
                targetState = when {
                    usbMode -> SignalPillMode.USB
                    staMode && connected -> SignalPillMode.STA_ONLINE
                    staMode -> SignalPillMode.STA_OFFLINE
                    unknownSignal -> SignalPillMode.WIFI_UNKNOWN
                    online -> SignalPillMode.WIFI_ONLINE
                    else -> SignalPillMode.WIFI_OFFLINE
                },
                animationSpec = tween(220),
                label = "signalMode"
            ) { mode ->
                when (mode) {
                    SignalPillMode.USB -> SharedClassicUsbIcon(
                            description = text.usb,
                            tint = color,
                            modifier = Modifier
                                .wrapContentHeight(unbounded = true)
                                .size(18.dp),
                        )

                    SignalPillMode.STA_ONLINE,
                    SignalPillMode.STA_OFFLINE -> StaSignalIcon(
                        text = text,
                        connected = mode == SignalPillMode.STA_ONLINE,
                        tint = color,
                        modifier = Modifier
                            .wrapContentHeight(unbounded = true)
                            .size(19.dp),
                    )

                    SignalPillMode.WIFI_ONLINE -> Row(
                            modifier = Modifier.fillMaxHeight(),
                            verticalAlignment = Alignment.Bottom,
                            horizontalArrangement = Arrangement.spacedBy(2.5.dp),
                        ) {
                            repeat(4) { i ->
                                val lit = i < level.coerceAtLeast(1)
                                Box(
                                    modifier = Modifier
                                        .width(4.dp)
                                        .height((6 + i * 3).dp)
                                        .clip(RoundedCornerShape(1.5.dp))
                                        .background(if (lit) signalBars.lit else signalBars.unlit),
                                )
                            }
                        }

                    SignalPillMode.WIFI_UNKNOWN -> Icon(
                            Icons.Default.Wifi,
                            contentDescription = text.signalUnavailable,
                            tint = colors.accentBlue,
                            modifier = Modifier.wrapContentHeight(unbounded = true).size(18.dp),
                        )

                    SignalPillMode.WIFI_OFFLINE -> Icon(
                            Icons.Default.WifiOff,
                            contentDescription = text.notConnected,
                            tint = colors.statusError,
                            modifier = Modifier
                                .wrapContentHeight(unbounded = true)
                                .size(18.dp),
                        )
                }
            }
            AnimatedVisibility(
                visible = expanded && online && !staMode && !unknownSignal,
                // 展开带一点弹性（与胶囊同款手感），从左侧展开、文字先露出开头。
                enter = expandHorizontally(
                    animationSpec = Motion.bouncy(),
                    expandFrom = Alignment.Start
                ) + fadeIn(),
                // 收起不用弹簧：宽度弹向 0 以下没有意义，干脆利落更自然。
                exit = shrinkHorizontally(
                    animationSpec = tween(220, easing = FastOutSlowInEasing),
                    shrinkTowards = Alignment.Start
                ) + fadeOut(tween(160))
            ) {
                Text(
                    text = if (usbMode) text.usb else "$r dBm",
                    style = MaterialTheme.typography.labelMedium.copy(fontFeatureSettings = "tnum"),
                    fontWeight = FontWeight.Medium,
                    color = if (usbMode) color else signalBars.lit,
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

private enum class SignalPillMode {
    WIFI_UNKNOWN,
    WIFI_OFFLINE,
    WIFI_ONLINE,
    STA_OFFLINE,
    STA_ONLINE,
    USB,
}

/** STA does not expose a meaningful client-Wi-Fi RSSI, so connected state stays visually full. */
@Composable
private fun StaSignalIcon(
    text: SignalPillText,
    connected: Boolean,
    tint: Color,
    modifier: Modifier = Modifier,
) {
    val description = if (connected) text.staConnected else text.staDisconnected
    Canvas(
        modifier = modifier.semantics { contentDescription = description },
    ) {
        val barWidth = 3.2.dp.toPx()
        val gap = 1.65.dp.toPx()
        val bottom = size.height * 0.88f
        val barHeights = floatArrayOf(5.dp.toPx(), 8.dp.toPx(), 11.dp.toPx(), 14.dp.toPx())
        val totalWidth = barWidth * barHeights.size + gap * (barHeights.size - 1)
        val startX = (size.width - totalWidth) / 2f
        val barColor = if (connected) tint else tint.copy(alpha = 0.28f)

        barHeights.forEachIndexed { index, height ->
            drawRoundRect(
                color = barColor,
                topLeft = Offset(startX + index * (barWidth + gap), bottom - height),
                size = Size(barWidth, height),
                cornerRadius = CornerRadius(1.35.dp.toPx()),
            )
        }

        if (!connected) {
            drawLine(
                color = tint,
                start = Offset(size.width * 0.15f, size.height * 0.12f),
                end = Offset(size.width * 0.87f, size.height * 0.88f),
                strokeWidth = 2.15.dp.toPx(),
                cap = StrokeCap.Round,
            )
        }
    }
}

/** 经典 USB 三叉标：箭头、圆点和方形分别作为三条分支端点。 */
@Composable
fun SharedClassicUsbIcon(
    description: String,
    tint: Color,
    modifier: Modifier = Modifier
) {
    Canvas(modifier = modifier.semantics { contentDescription = description }) {
        val unit = size.minDimension
        val stroke = unit * 0.11f
        val centerX = size.width * 0.5f
        val junctionY = size.height * 0.62f

        drawLine(
            color = tint,
            start = Offset(centerX, size.height * 0.84f),
            end = Offset(centerX, size.height * 0.22f),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
        drawLine(
            color = tint,
            start = Offset(centerX, junctionY),
            end = Offset(size.width * 0.25f, size.height * 0.48f),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
        drawLine(
            color = tint,
            start = Offset(centerX, size.height * 0.52f),
            end = Offset(size.width * 0.76f, size.height * 0.38f),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
        drawLine(
            color = tint,
            start = Offset(size.width * 0.76f, size.height * 0.38f),
            end = Offset(size.width * 0.76f, size.height * 0.25f),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )

        val arrow = Path().apply {
            moveTo(centerX, size.height * 0.08f)
            lineTo(size.width * 0.36f, size.height * 0.27f)
            lineTo(size.width * 0.64f, size.height * 0.27f)
            close()
        }
        drawPath(arrow, tint)
        drawCircle(
            color = tint,
            radius = unit * 0.09f,
            center = Offset(size.width * 0.22f, size.height * 0.46f)
        )
        drawRect(
            color = tint,
            topLeft = Offset(size.width * 0.68f, size.height * 0.10f),
            size = androidx.compose.ui.geometry.Size(unit * 0.16f, unit * 0.16f)
        )
    }
}

/** Unknown RSSI is an explicit platform capability, never an invented signal sample. */
fun signalPillOnline(connected: Boolean, usbMode: Boolean, staMode: Boolean, rssi: Int?, allowUnknownRssi: Boolean = false): Boolean =
    connected && (usbMode || staMode || rssi != null || allowUnknownRssi)
