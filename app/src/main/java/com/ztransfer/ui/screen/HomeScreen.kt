package com.ztransfer.ui.screen

import android.content.Intent
import android.provider.Settings
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
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
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import com.ztransfer.protocol.CameraConnectionType
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
    // 曾购买、通行证过期且续签联不上网 → 顶部提示连网续期(连上重开自动恢复)。
    val renewalNeeded by LicenseManager.renewalNeeded.collectAsState()
    // 订阅到期(要花钱才能继续用)——与 renewalNeeded 是两回事,别混:那个连上网就自己好了。
    val subExpired by LicenseManager.subExpired.collectAsState()
    var showRenew by remember { mutableStateOf(false) }
    // 徽标左侧"续费"按钮打开的续费弹窗(剩余天数 + 续费价,再进付款);
    // 与 showRenew(提示条直进付款)分开:一个是常驻入口,一个是临期/到期的急路径。
    var showRenewInfo by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    // 双 Z 标按钮在根坐标系中的边界：设置面板贴其下缘展开（下拉弹窗），并以其中心为动画原点。
    var zAnchor by remember { mutableStateOf<Rect?>(null) }
    // 连接页「小技巧」气泡：从 tips 按钮变形弹出（复用 AnchorPopup 的全局毛玻璃）。
    var showTips by remember { mutableStateOf(false) }
    var tipsAnchor by remember { mutableStateOf<Rect?>(null) }

    val colors = AppTheme.colors
    val connected = state.isConnectedToCamera
    val onCameraWifi = state.isWifiConnected
    val onUsb = state.connectionType == CameraConnectionType.USB
    val usbError = state.usbConnectionError
    // 会话真正就绪后再触发卡片内成功动画；MainScreen 使用同一组常量等待动画结束再跳转。
    var celebrate by remember { mutableStateOf(false) }
    LaunchedEffect(connected) {
        if (connected) {
            delay(CONNECT_CELEBRATE_DELAY_MS)
            celebrate = true
        } else {
            celebrate = false
        }
    }

    // 用户不需要点卡片作出强选择：App 观察真实链路，先识别到哪种传输就点亮哪张卡片。
    val selectedConnection = when {
        onUsb -> CameraConnectionType.USB
        onCameraWifi || (connected && state.connectionType == CameraConnectionType.WIFI) ->
            CameraConnectionType.WIFI
        else -> null
    }
    val selectionScene = remember { Animatable(0f) }
    LaunchedEffect(selectedConnection) {
        if (selectedConnection == null) {
            selectionScene.snapTo(0f)
        } else {
            selectionScene.snapTo(0f)
            selectionScene.animateTo(
                targetValue = 1f,
                animationSpec = tween(620, easing = LinearEasing)
            )
        }
    }
    // 待连接时两张卡相差半个周期依次呼吸；识别传输方式后立即停止提示动画。
    val attentionTransition = rememberInfiniteTransition(label = "connectionAttention")
    val attentionPhase by attentionTransition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(CONNECTION_ATTENTION_MS, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "connectionAttentionPhase"
    )
    val usbPhase = attentionPhase
    val wifiPhase = (attentionPhase + 0.5f).mod(1f)
    val usbAttention = if (selectedConnection == null) connectionAttention(usbPhase) else 0f
    val wifiAttention = if (selectedConnection == null) {
        connectionAttention(wifiPhase)
    } else 0f
    val soonDays = if (isPro) {
        val subExp = remember(showRenew, showRenewInfo) { LicenseManager.subExpiresAtSec() }
        if (subExp > 0L) subDaysLeft(subExp) else -1
    } else -1
    val banner: Pair<String, Boolean>? = when {   // (文案, 点了能不能续费)
        renewalNeeded -> stringResource(R.string.renewal_needed) to false
        subExpired -> stringResource(R.string.sub_expired_renew) to true
        soonDays in 0..SUB_ALERT_DAYS ->
            pluralStringResource(R.plurals.sub_expiring_soon, soonDays, soonDays) to true
        else -> null
    }

    Box(modifier = Modifier.fillMaxSize()) {
        // ---------- 连接内容区：顶部功能按钮仍由下面原有顶栏独立覆盖，本区只负责双卡 ----------
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxSize()
                .systemBarsPadding()
        ) {
            val compact = maxHeight < 690.dp
            val cardHeight = if (compact) 272.dp else 292.dp
            val horizontalPadding = if (maxWidth < 360.dp) 14.dp else 20.dp
            val cardSpacing = 12.dp
            val cardWidth = (maxWidth - horizontalPadding * 2 - cardSpacing) / 2
            val selectedCenterShift = (cardWidth + cardSpacing) / 2
            // 图标最终停在屏幕上方中央，避开 Android USB 权限弹窗的主体区域。
            val selectedLift = if (compact) (-48).dp else (-76).dp

            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = horizontalPadding),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                // 给原有顶栏留空间；确认模式后卡片退场，仅模式图标飞向屏幕上方。
                Spacer(Modifier.height(56.dp))
                Spacer(Modifier.weight(if (compact) 0.18f else 0.32f))

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(cardHeight),
                    horizontalArrangement = Arrangement.spacedBy(cardSpacing)
                ) {
                    ConnectionMethodCard(
                        modifier = Modifier.weight(1f),
                        icon = Icons.Default.Usb,
                        title = stringResource(R.string.connection_usb),
                        accent = colors.accentOrange,
                        steps = listOf(
                            stringResource(R.string.usb_step_power),
                            stringResource(R.string.usb_step_cable)
                        ),
                        selected = selectedConnection == CameraConnectionType.USB,
                        success = celebrate && selectedConnection == CameraConnectionType.USB,
                        attention = usbAttention,
                        selectionOffsetX = selectedCenterShift,
                        selectionOffsetY = selectedLift,
                        selectionScene = selectionScene.value,
                        error = usbError?.takeIf {
                            selectedConnection == CameraConnectionType.USB
                        },
                        goldBurst = isPro
                    )

                    ConnectionMethodCard(
                        modifier = Modifier.weight(1f),
                        icon = Icons.Default.Wifi,
                        title = stringResource(R.string.connection_wifi_hotspot),
                        accent = colors.accentBlue,
                        steps = listOf(
                            stringResource(R.string.step_camera_wifi),
                            stringResource(R.string.step_phone_wifi)
                        ),
                        selected = selectedConnection == CameraConnectionType.WIFI,
                        success = celebrate && selectedConnection == CameraConnectionType.WIFI,
                        attention = wifiAttention,
                        selectionOffsetX = -selectedCenterShift,
                        selectionOffsetY = selectedLift,
                        selectionScene = selectionScene.value,
                        goldBurst = isPro,
                        footer = {
                            GlassButton(
                                onClick = { showTips = true },
                                shape = RoundedCornerShape(12.dp),
                                contentPadding = PaddingValues(0.dp),
                                panel = true,
                                modifier = Modifier
                                    .size(36.dp)
                                    .onGloballyPositioned { tipsAnchor = it.boundsInRoot() }
                            ) {
                                Box(
                                    modifier = Modifier.fillMaxWidth(),
                                    contentAlignment = Alignment.Center
                                ) {
                                    Icon(
                                        Icons.Default.Lightbulb,
                                        contentDescription = stringResource(R.string.tip_title),
                                        tint = colors.accentOrange,
                                        modifier = Modifier.size(16.dp)
                                    )
                                }
                            }
                            GlassButton(
                                onClick = {
                                    try {
                                        context.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                                    } catch (_: Exception) {}
                                },
                                shape = RoundedCornerShape(12.dp),
                                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 6.dp),
                                panel = true,
                                modifier = Modifier
                                    .weight(1f)
                                    .height(36.dp)
                            ) {
                                Text(
                                    stringResource(R.string.open_wifi_settings),
                                    style = MaterialTheme.typography.labelSmall,
                                    fontWeight = FontWeight.SemiBold,
                                    color = colors.accentBlue,
                                    maxLines = 1,
                                    textAlign = TextAlign.Center,
                                    modifier = Modifier.fillMaxWidth()
                                )
                            }
                        }
                    )
                }

                // 原有订阅提示逻辑完整保留在双卡下方。
                Spacer(modifier = Modifier.height(14.dp))
                if (banner != null) {
                    val (bannerText, renewable) = banner
                    val bannerShape = RoundedCornerShape(10.dp)
                    Text(
                        text = bannerText,
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.accentOrange,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            // clip 在 clickable 之前:否则水波纹是方的,溢出圆角提示条。
                            .then(
                                if (renewable) Modifier
                                    .clip(bannerShape)
                                    .clickable { showRenew = true }
                                else Modifier
                            )
                            .background(colors.accentOrange.copy(alpha = 0.12f), bannerShape)
                            .padding(horizontal = 14.dp, vertical = 8.dp)
                    )
                }
                Spacer(Modifier.weight(1f))
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
                // 订阅用户(有到期日;永久码没有):徽标左侧一颗与顶栏同规格的"续费"玻璃按钮。
                // 常驻但安静——想续随时点得到,不想理它也不碍眼;到期日等细节都收进弹窗里。
                val subExp = remember(showRenewInfo, showRenew) { LicenseManager.subExpiresAtSec() }
                if (subExp > 0L) {
                    // 与右邻的"高级版"徽标同高同圆角(28dp/14dp),两颗并排像一对。
                    GlassButton(
                        onClick = { showRenewInfo = true },
                        shape = RoundedCornerShape(14.dp),
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
                        modifier = Modifier.height(28.dp)
                    ) {
                        Text(
                            stringResource(R.string.renew_action),
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.SemiBold,
                            color = colors.accentBlue
                        )
                    }
                    Spacer(modifier = Modifier.width(8.dp))
                }
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
                onCelebrate = { fireworks.launch() },
                onHoldCameraWifi = { viewModel.holdCameraWifi(it) },
                // 到期的老用户从徽标再买 = 续原来那个码,不发新码。
                renew = subExpired
            )
        }
        // 徽标左侧"续费"按钮:先看剩余天数与价格,认可了再进付款。
        if (showRenewInfo) {
            RenewDialog(
                onDismiss = { showRenewInfo = false },
                onCelebrate = { fireworks.launch() },
                onHoldCameraWifi = { viewModel.holdCameraWifi(it) }
            )
        }
        // 提示条点开的续费:他已经买过且临期/到期,不必再看一遍天数和价格,直接付款页。
        if (showRenew) {
            PurchaseDialog(
                onDismiss = { showRenew = false },
                onCelebrate = { showRenew = false; fireworks.launch() },
                onHoldCameraWifi = { viewModel.holdCameraWifi(it) },
                renew = true
            )
        }

        // ---------- 设置面板：从 "Z传" 按钮位置变形展开 ----------
        if (showSettings) {
            SettingsOverlay(
                viewModel = transferViewModel,
                anchorBounds = zAnchor,
                onDismiss = { showSettings = false },
                onPlayFireworks = { fireworks.launch() },
                onHoldCameraWifi = { viewModel.holdCameraWifi(it) }
            )
        }

        // ---------- 小技巧气泡：从 tips 按钮变形弹出的毛玻璃内容框 ----------
        if (showTips) {
            TipsBubble(anchorBounds = tipsAnchor, onDismiss = { showTips = false })
        }

        // ---------- 高级版烟花彩蛋：放在最上层（含设置面板之上），不拦截触摸，播完自行移除 ----------
        FireworksOverlay(fireworks)
    }
}

private const val CONNECTION_ATTENTION_MS = 2_800

/**
 * 半周期内完成一次整卡呼吸；另一张卡错开半周期。
 * 每轮只有一个峰值：较快放大，随后柔和收回，不做二次回弹。
 */
private fun connectionAttention(phase: Float): Float {
    if (phase >= 0.5f) return 0f
    val t = phase * 2f
    fun segment(start: Float, end: Float, from: Float, to: Float): Float {
        val x = ((t - start) / (end - start)).coerceIn(0f, 1f)
        val eased = x * x * (3f - 2f * x)
        return from + (to - from) * eased
    }
    return if (t < 0.32f) {
        segment(0f, 0.32f, 0f, 1f)
    } else {
        segment(0.32f, 1f, 1f, 0f)
    }
}

@Composable
private fun ConnectionMethodCard(
    modifier: Modifier,
    icon: ImageVector,
    title: String,
    accent: Color,
    steps: List<String>,
    selected: Boolean,
    success: Boolean,
    attention: Float,
    selectionOffsetX: Dp,
    selectionOffsetY: Dp,
    selectionScene: Float,
    error: String? = null,
    goldBurst: Boolean = false,
    footer: (@Composable RowScope.() -> Unit)? = null
) {
    val colors = AppTheme.colors
    val shape = RoundedCornerShape(24.dp)
    var cardPressed by remember { mutableStateOf(false) }
    var pressDirection by remember { mutableStateOf(0f) }
    val pressDeformation by animateFloatAsState(
        targetValue = if (cardPressed && !success) 1f else 0f,
        animationSpec = if (cardPressed && !success) {
            tween(70)
        } else {
            spring(dampingRatio = 0.42f, stiffness = 500f)
        },
        label = "connectionCardPress"
    )

    fun eased(value: Float): Float {
        val x = value.coerceIn(0f, 1f)
        return x * x * (3f - 2f * x)
    }
    val sceneProgress = eased(selectionScene)
    // 失败时让胜出卡恢复，继续承载错误信息；正常流程中两张卡一起退场。
    val cardExitProgress = if (selected && error != null) 0f else sceneProgress
    val heroProgress = if (selected && error == null) sceneProgress else 0f

    Box(
        modifier = modifier
            .zIndex(if (selected) 3f else 0f)
    ) {
        GlassSurface(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    val breathingScale = 1f + attention * 0.04f
                    val deformation = pressDeformation
                    val exitScale = 1f - cardExitProgress * 0.045f
                    scaleX = breathingScale * exitScale * (1f + deformation * 0.012f)
                    scaleY = breathingScale * exitScale * (1f - deformation * 0.024f)
                    rotationZ = pressDirection * deformation * 1.15f
                    translationX = pressDirection * deformation * 1.5.dp.toPx()
                    translationY = cardExitProgress * 8.dp.toPx()
                    alpha = 1f - cardExitProgress
                },
            shape = shape,
            tint = when {
                error != null -> colors.statusError.copy(alpha = 0.055f)
                else -> Color.Transparent
            },
            showBorder = false
        ) {
            Box(modifier = Modifier.fillMaxSize()) {
                // 空白区负责卡片形变；前景按钮拥有独立手势，不与卡片反馈竞争。
                Box(
                    modifier = Modifier
                        .matchParentSize()
                        .pointerInput(success) {
                            if (success) return@pointerInput
                            awaitEachGesture {
                                val down = awaitFirstDown()
                                pressDirection = if (size.width == 0) 0f else {
                                    ((down.position.x / size.width) * 2f - 1f)
                                        .coerceIn(-1f, 1f)
                                }
                                cardPressed = true
                                var pressed = true
                                while (pressed) {
                                    val event = awaitPointerEvent(PointerEventPass.Final)
                                    pressed = event.changes.any {
                                        it.id == down.id && it.pressed
                                    }
                                }
                                cardPressed = false
                            }
                        }
                )

                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 14.dp, vertical = 16.dp)
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        // 图标由下方独立图层绘制，这里只保留原始排版占位。
                        Spacer(Modifier.size(42.dp))
                        Spacer(Modifier.width(10.dp))
                        Text(
                            text = title,
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = colors.onBackground,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
                        )
                    }

                    Spacer(Modifier.height(20.dp))
                    steps.forEachIndexed { index, text ->
                        ConnectionStep(index + 1, text, accent)
                        if (index != steps.lastIndex) Spacer(Modifier.height(13.dp))
                    }

                    if (error != null) {
                        Spacer(Modifier.height(12.dp))
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .background(colors.statusError.copy(alpha = 0.10f))
                                .padding(horizontal = 9.dp, vertical = 7.dp)
                        ) {
                            Text(
                                text = stringResource(R.string.connection_failed_short),
                                style = MaterialTheme.typography.labelSmall,
                                fontWeight = FontWeight.Bold,
                                color = colors.statusError
                            )
                            Text(
                                text = error,
                                style = MaterialTheme.typography.labelSmall,
                                color = colors.onSurfaceVariant,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }

                    Spacer(Modifier.weight(1f))
                    if (footer != null) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            content = footer
                        )
                    }
                }

            }
        }

        // 模式图标独立于卡片裁剪层：胜出图标飞到屏幕上方，另一枚随卡片退场。
        GlassSurface(
            modifier = Modifier
                .offset(x = 14.dp, y = 16.dp)
                .size(42.dp)
                .zIndex(3f)
                .graphicsLayer {
                    translationX = selectionOffsetX.toPx() * heroProgress
                    translationY = selectionOffsetY.toPx() * heroProgress -
                        kotlin.math.sin(heroProgress * Math.PI.toFloat()) * 10.dp.toPx()
                    val heroScale = 1f + heroProgress * 1.12f
                    scaleX = heroScale
                    scaleY = heroScale
                    alpha = if (selected) 1f else 1f - cardExitProgress
                },
            shape = RoundedCornerShape(13.dp),
            panel = true,
            tint = if (success) {
                colors.statusConnected.copy(alpha = 0.12f)
            } else {
                accent.copy(alpha = 0.07f)
            },
            borderColor = if (success) {
                colors.statusConnected.copy(alpha = 0.78f)
            } else {
                accent.copy(alpha = 0.24f)
            }
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = accent,
                modifier = Modifier
                    .size(21.dp)
                    .align(Alignment.Center)
            )
        }

        // 成功效果与飞出的模式图标共用位置，可越过卡片边界绘制。
        ConnectionSuccessOverlay(
            success = success,
            goldBurst = goldBurst,
            modifier = Modifier
                // 220dp 画布的中心与 42dp 模式图标的中心完全重合。
                .offset(x = (-75).dp, y = (-73).dp)
                .size(220.dp)
                .zIndex(4f)
                .graphicsLayer {
                    translationX = selectionOffsetX.toPx() * heroProgress
                    translationY = selectionOffsetY.toPx() * heroProgress -
                        kotlin.math.sin(heroProgress * Math.PI.toFloat()) * 10.dp.toPx()
                }
        )
    }
}

@Composable
private fun ConnectionStep(index: Int, text: String, accent: Color) {
    val colors = AppTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth()
    ) {
        Box(
            modifier = Modifier
                .size(21.dp)
                .alignByBaseline()
                .clip(CircleShape)
                .background(accent.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = index.toString(),
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.Bold,
                color = accent
            )
        }
        Spacer(Modifier.width(8.dp))
        Text(
            text = text,
            style = MaterialTheme.typography.bodySmall,
            fontWeight = FontWeight.Medium,
            color = colors.onSurfaceVariant,
            modifier = Modifier
                .weight(1f)
                .alignByBaseline()
        )
    }
}

@Composable
private fun ConnectionSuccessOverlay(
    success: Boolean,
    goldBurst: Boolean,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    val progress = remember { Animatable(0f) }
    LaunchedEffect(success) {
        if (success) {
            progress.snapTo(0f)
            progress.animateTo(
                targetValue = 1f,
                animationSpec = tween(760, easing = FastOutSlowInEasing)
            )
        } else {
            progress.snapTo(0f)
        }
    }
    if (!success && progress.value == 0f) return

    val p = progress.value
    Box(
        modifier = modifier
            .graphicsLayer { alpha = (p * 5f).coerceAtMost(1f) },
        contentAlignment = Alignment.Center
    ) {
        repeat(2) { index ->
            val ringProgress = ((p - index * 0.14f) / 0.72f).coerceIn(0f, 1f)
            Box(
                modifier = Modifier
                    .size(82.dp)
                    .graphicsLayer {
                        val ringScale = 0.72f + ringProgress * 1.72f
                        scaleX = ringScale
                        scaleY = ringScale
                        alpha = (1f - ringProgress) * 0.62f
                    }
                    .border(1.5.dp, colors.statusConnected, CircleShape)
            )
        }

        if (goldBurst) {
            repeat(10) { index ->
                Box(
                    modifier = Modifier
                        .size(if (index % 3 == 0) 6.dp else 4.dp)
                        .graphicsLayer {
                            val angle = (index * 36f + if (index % 2 == 0) 7f else -5f) *
                                (Math.PI.toFloat() / 180f)
                            val distance = (48 + (index % 3) * 11).dp.toPx() * p
                            translationX = cos(angle) * distance
                            translationY = sin(angle) * distance
                            alpha = (p * 5f).coerceAtMost(1f) * (1f - p)
                        }
                        .clip(CircleShape)
                        .background(if (index % 2 == 0) Color(0xFFFFE082) else Color(0xFFF0A93B))
                )
            }
        }

        // 不再绘制另一枚“成功图标”；只给原模式图标增加一圈确认脉冲。
        val coreScale = 0.82f + kotlin.math.sin(p * Math.PI.toFloat()) * 0.22f
        Box(
            modifier = Modifier
                .size(78.dp)
                .graphicsLayer {
                    scaleX = coreScale
                    scaleY = coreScale
                    alpha = (1f - p).coerceAtLeast(0.16f)
                }
                .clip(CircleShape)
                .background(colors.statusConnected.copy(alpha = 0.08f))
                .border(1.5.dp, colors.statusConnected.copy(alpha = 0.70f), CircleShape)
        )
    }
}

// 连接成功后的入场节奏：先保持当前卡片 [CONNECT_CELEBRATE_DELAY_MS]，再播放
// [CONNECT_SUCCESS_ANIM_MS] 的卡片内成功动画；动画结束后由 MainScreen 跳到照片列表。
const val CONNECT_CELEBRATE_DELAY_MS = 500L
const val CONNECT_SUCCESS_ANIM_MS = 850L

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
