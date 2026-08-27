package com.ztransfer.ui.screen

import android.content.Intent
import android.os.SystemClock
import android.provider.Settings
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.Canvas
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
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.zIndex
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.ui.theme.*
import com.ztransfer.viewmodel.CameraState
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.StaConnectionStatus
import com.ztransfer.viewmodel.TransferViewModel
import com.ztransfer.viewmodel.WirelessMode
import com.ztransfer.viewmodel.WifiConnectionStatus
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.isActive
import kotlin.math.cos
import kotlin.math.sin

/** 连接页只观察自身会展示的字段，照片扫描批次不再打断成功动画。 */
internal data class HomeConnectionUiState(
    val isConnectedToCamera: Boolean,
    val connectionType: CameraConnectionType?,
    val wirelessMode: WirelessMode,
    val isStaConnection: Boolean,
    val staConnectionStatus: StaConnectionStatus,
    val staConnectionError: String?,
    val usbConnectionError: String?,
    val wifiConnectionStatus: WifiConnectionStatus,
)

internal fun CameraState.toHomeConnectionUiState(): HomeConnectionUiState =
    HomeConnectionUiState(
        isConnectedToCamera = isConnectedToCamera,
        connectionType = connectionType,
        wirelessMode = wirelessMode,
        isStaConnection = isStaConnection,
        staConnectionStatus = staConnectionStatus,
        staConnectionError = staConnectionError,
        usbConnectionError = usbConnectionError,
        wifiConnectionStatus = wifiConnectionStatus,
    )

internal fun shouldShowSubscriptionExpiryNotice(isPro: Boolean, daysLeft: Int): Boolean =
    isPro && daysLeft in 0..SUB_ALERT_DAYS

/**
 * 连接（引导）页：展示连接状态与引导。左上角 "Z传" 玻璃按钮为设置入口，
 * 与照片列表页完全一致（同一 GlassButton + SettingsOverlay，点击从按钮变形展开设置面板）。
 * 连接成功后自动跳到文件列表，且用户不会再返回本页。
 * 高级版购买、激活与续费入口统一收进设置面板，连接页本身只承担相机连接引导。
 */
@Composable
fun HomeScreen(
    viewModel: CameraViewModel,
    transferViewModel: TransferViewModel,
    onConnectionCelebrationFinished: () -> Unit,
    onOpenLocalPhotoEffects: () -> Unit,
) {
    val state by remember(viewModel) {
        viewModel.state
            .map(CameraState::toHomeConnectionUiState)
            .distinctUntilChanged()
    }.collectAsState(initial = viewModel.state.value.toHomeConnectionUiState())
    val transferState by transferViewModel.state.collectAsState()
    val context = LocalContext.current
    // 连接成功时高级版专属的金色粒子彩蛋依赖它；购买入口已经统一移入设置面板。
    val isPro by LicenseManager.isPro.collectAsState()
    // 当前设备的通行证过期且续签联不上网 → 顶部提示连网续期(连上重开自动续签)。
    val renewalNeeded by LicenseManager.renewalNeeded.collectAsState()
    // 右上角临期提示打开续费弹窗（剩余天数 + 续费价，再进付款）。
    var showRenewInfo by remember { mutableStateOf(false) }
    // 只在购买/续费真正成功后递增；打开或取消续费窗不会改变临期标签。
    var licenseRefreshNonce by remember { mutableStateOf(0) }
    var showSettings by remember { mutableStateOf(false) }
    // 双 Z 标按钮在根坐标系中的边界：设置面板贴其下缘展开（下拉弹窗），并以其中心为动画原点。
    var zAnchor by remember { mutableStateOf<Rect?>(null) }
    // 按钮跟随 Wi-Fi 卡片呼吸缩放。这里只用非 Snapshot 容器记录实时坐标，点击时再冻结
    // 给弹窗，避免每帧坐标变化触发整个连接页重组，也避免展开途中锚点继续漂移。
    val liveTipsButtonBounds = remember { LayoutBoundsHolder() }
    var tipsPopupAnchor by remember { mutableStateOf<Rect?>(null) }
    var showStaResetDialog by remember { mutableStateOf(false) }

    val colors = AppTheme.colors
    val buttonSkin = LocalButtonTexturePalette.current?.skin ?: SkinPreset.FROSTED_GLASS
    val darkTheme = colors.background.luminance() < 0.5f
    val wifiSettingsTextColor = wifiSettingsButtonTextColor(
        skin = buttonSkin,
        dark = darkTheme,
        defaultColor = colors.accentBlue,
    )
    val staConnectTextColor = materialButtonForegroundColor(
        skin = buttonSkin,
        dark = darkTheme,
        defaultColor = colors.onBackground,
    )
    val staResetIconColor = if (buttonSkin == SkinPreset.WOOD) {
        colors.onBackground
    } else {
        colors.accentOrange
    }
    val connected = state.isConnectedToCamera
    val usbError = state.usbConnectionError
    // 会话真正就绪后再触发卡片内成功动画；动画完成时主动通知 MainScreen 跳转。
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
    val selectedConnection = homeSelectedConnection(
        connected = connected,
        connectionType = state.connectionType
    )
    val selectionScene = remember { Animatable(0f) }
    // 进度只允许在 graphicsLayer 中读取；稳定 lambda 避免 620ms 起飞期间重组整页。
    val selectionSceneProgress = remember(selectionScene) { { selectionScene.value } }
    LaunchedEffect(selectedConnection) {
        if (selectedConnection == null) {
            selectionScene.animateTo(
                targetValue = 0f,
                animationSpec = tween(380, easing = FastOutSlowInEasing)
            )
        } else {
            selectionScene.snapTo(0f)
            selectionScene.animateTo(
                targetValue = 1f,
                animationSpec = tween(620, easing = LinearEasing)
            )
        }
    }

    // 快速成功/失败不显示中间态，避免连接页在启动时闪一下“正在识别”。
    var showWifiProbing by remember { mutableStateOf(false) }
    LaunchedEffect(state.wifiConnectionStatus, state.connectionType) {
        showWifiProbing = false
        if (
            shouldShowWifiConnectionFeedback(state.connectionType) &&
            state.wifiConnectionStatus == WifiConnectionStatus.PROBING
        ) {
            delay(WIFI_PROBING_FEEDBACK_DELAY_MS)
            showWifiProbing = true
        }
    }
    // USB 一经识别，本次会话的连接反馈就只属于有线卡片。即使网络回调还有一帧
    // 迟到状态，也不能让 Wi-Fi 提示在卡片退场动画中闪现。
    val wifiFeedback = if (
        !shouldShowCameraHotspotFeedback(
            connectionType = state.connectionType,
            isStaConnection = state.isStaConnection,
            staStatus = state.staConnectionStatus,
            wirelessMode = state.wirelessMode,
        )
    ) null else when (state.wifiConnectionStatus) {
        WifiConnectionStatus.PROBING -> if (showWifiProbing) {
            ConnectionCardFeedback(
                title = stringResource(R.string.wifi_identifying_camera),
                body = null,
                accent = colors.accentBlue,
                busy = true
            )
        } else {
            null
        }
        WifiConnectionStatus.NOT_FOUND -> ConnectionCardFeedback(
            title = stringResource(R.string.wifi_camera_not_found),
            body = stringResource(R.string.wifi_connect_camera),
            accent = colors.accentOrange
        )
        WifiConnectionStatus.REFUSED -> ConnectionCardFeedback(
            title = stringResource(R.string.wifi_camera_refused),
            body = stringResource(R.string.wifi_check_camera_connection),
            accent = colors.accentOrange
        )
        WifiConnectionStatus.FAILED -> ConnectionCardFeedback(
            title = stringResource(R.string.wifi_camera_connection_failed),
            body = stringResource(R.string.wifi_restart_camera),
            accent = colors.accentOrange
        )
        WifiConnectionStatus.RECONNECTING -> ConnectionCardFeedback(
            title = stringResource(R.string.wifi_connection_interrupted),
            body = stringResource(R.string.wifi_reconnecting),
            accent = colors.accentOrange,
            busy = true
        )
        WifiConnectionStatus.IDLE -> null
    }
    val staBusy = state.staConnectionStatus == StaConnectionStatus.DISCOVERING ||
        state.staConnectionStatus == StaConnectionStatus.PAIRING ||
        state.staConnectionStatus == StaConnectionStatus.CONNECTING
    val staConnectButtonState = when {
        state.isConnectedToCamera && state.isStaConnection -> StaConnectButtonState.CONNECTED
        state.staConnectionStatus == StaConnectionStatus.DISCOVERING ->
            StaConnectButtonState.SEARCHING
        state.staConnectionStatus == StaConnectionStatus.PAIRING ->
            StaConnectButtonState.PAIRING
        state.staConnectionStatus == StaConnectionStatus.CONNECTING ->
            StaConnectButtonState.CONNECTING
        else -> StaConnectButtonState.IDLE
    }
    val staConnectButtonLabels = StaConnectButtonState.entries.map { buttonState ->
        stringResource(buttonState.labelRes)
    }
    val staConnectButtonTextStyle = MaterialTheme.typography.labelLarge.copy(
        fontWeight = FontWeight.SemiBold,
    )
    val staFeedback = if (
        state.wirelessMode == WirelessMode.STA &&
        state.staConnectionStatus == StaConnectionStatus.FAILED
    ) {
        ConnectionCardFeedback(
            title = stringResource(R.string.sta_camera_not_found_short),
            body = state.staConnectionError ?: stringResource(R.string.sta_camera_not_found),
            accent = colors.statusError,
            multiline = true,
        )
    } else null
    // 识别传输方式后立即停止提示动画；具体动画在卡片图层内运行，避免每帧重组整个页面。
    val connectionAttentionActive = selectedConnection == null
    val soonDays = if (isPro) {
        val subExp = remember(isPro, licenseRefreshNonce) {
            LicenseManager.subExpiresAtSec()
        }
        if (subExp > 0L) subDaysLeft(subExp) else -1
    } else -1
    val renewalNotice: Pair<String, Boolean>? = when {   // (文案, 点了能不能续费)
        renewalNeeded -> stringResource(R.string.renewal_needed) to false
        shouldShowSubscriptionExpiryNotice(isPro, soonDays) ->
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
            // 提示只占用卡片内部留白，不改变卡片外形，避免识别结果出现时整页跳动。
            // 英文步骤换行更多，单独为其保留额外高度；中文与繁中保持紧凑卡片。
            val cardHeight = if (LocalConfiguration.current.locales[0].language == "en") {
                324.dp
            } else {
                296.dp
            }
            val horizontalPadding = if (maxWidth < 360.dp) 14.dp else 20.dp
            val cardSpacing = 12.dp

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
                        modeIcon = { tint, iconModifier ->
                            ClassicUsbIcon(tint = tint, modifier = iconModifier)
                        },
                        title = stringResource(R.string.connection_usb),
                        accent = colors.accentOrange,
                        materialSeed = USB_CARD_BADGE_TEXTURE_SEED,
                        steps = listOf(
                            stringResource(R.string.usb_step_power),
                            stringResource(R.string.usb_step_cable)
                        ),
                        selected = selectedConnection == CameraConnectionType.USB,
                        success = celebrate && selectedConnection == CameraConnectionType.USB,
                        attentionActive = connectionAttentionActive,
                        attentionPhaseOffset = 0f,
                        selectionSceneProgress = selectionSceneProgress,
                        error = usbError?.takeIf {
                            selectedConnection == CameraConnectionType.USB
                        },
                        goldBurst = isPro,
                        onSuccessAnimationFinished = onConnectionCelebrationFinished,
                    )

                    ConnectionMethodCard(
                        modifier = Modifier.weight(1f),
                        modeIcon = { tint, iconModifier ->
                            Icon(
                                imageVector = Icons.Default.Wifi,
                                contentDescription = null,
                                tint = tint,
                                modifier = iconModifier
                            )
                        },
                        title = stringResource(R.string.connection_wifi),
                        accent = colors.accentBlue,
                        materialSeed = WIFI_CARD_BADGE_TEXTURE_SEED,
                        steps = when (state.wirelessMode) {
                            WirelessMode.AP -> listOf(
                                stringResource(R.string.step_camera_wifi),
                                stringResource(R.string.step_phone_wifi),
                            )
                            WirelessMode.STA -> if (staFeedback == null) {
                                listOf(
                                    stringResource(R.string.sta_step_phone_hotspot),
                                    stringResource(R.string.sta_step_connect_camera),
                                )
                            } else {
                                emptyList()
                            }
                        },
                        modeSelector = {
                            WifiModeTabs(
                                selectedMode = state.wirelessMode,
                                enabled = !connected &&
                                    state.connectionType != CameraConnectionType.USB,
                                onSelectAp = {
                                    tipsPopupAnchor = null
                                    viewModel.selectApMode()
                                },
                                onSelectSta = {
                                    tipsPopupAnchor = null
                                    viewModel.selectStaMode()
                                },
                            )
                        },
                        selected = selectedConnection == CameraConnectionType.WIFI,
                        success = celebrate && selectedConnection == CameraConnectionType.WIFI,
                        attentionActive = connectionAttentionActive,
                        attentionPhaseOffset = 0.5f,
                        selectionSceneProgress = selectionSceneProgress,
                        goldBurst = isPro,
                        onSuccessAnimationFinished = onConnectionCelebrationFinished,
                        feedback = if (state.wirelessMode == WirelessMode.AP) {
                            wifiFeedback
                        } else {
                            staFeedback
                        },
                        feedbackFollowsModeSelector = state.wirelessMode == WirelessMode.STA,
                        footer = {
                            if (state.wirelessMode == WirelessMode.AP) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    TipLightbulbButton(
                                        onClick = {
                                            transferViewModel.markApConnectionHelpViewed()
                                            tipsPopupAnchor = liveTipsButtonBounds.value
                                        },
                                        contentDescription = stringResource(R.string.tip_title),
                                        attention = !transferState.apConnectionHelpViewed,
                                        modifier = Modifier
                                            .size(36.dp)
                                            .onGloballyPositioned {
                                                liveTipsButtonBounds.value = it.boundsInRoot()
                                            },
                                    )
                                    GlassButton(
                                        onClick = {
                                            try {
                                                context.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                                            } catch (_: Exception) {}
                                        },
                                        shape = RoundedCornerShape(12.dp),
                                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 6.dp),
                                        textureSeed = WIFI_SETTINGS_BUTTON_TEXTURE_SEED,
                                        modifier = Modifier
                                            .weight(1f)
                                            .height(36.dp)
                                    ) {
                                        Text(
                                            stringResource(R.string.open_wifi_settings),
                                            style = MaterialTheme.typography.labelSmall,
                                            fontWeight = FontWeight.SemiBold,
                                            color = wifiSettingsTextColor,
                                            maxLines = 1,
                                            textAlign = TextAlign.Center,
                                            modifier = Modifier.fillMaxWidth(),
                                        )
                                    }
                                }
                            } else {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    TipLightbulbButton(
                                        onClick = {
                                            transferViewModel.markStaConnectionHelpViewed()
                                            tipsPopupAnchor = liveTipsButtonBounds.value
                                        },
                                        contentDescription = stringResource(R.string.tip_sta_title),
                                        attention = !transferState.staConnectionHelpViewed,
                                        modifier = Modifier
                                            .size(34.dp)
                                            .onGloballyPositioned {
                                                liveTipsButtonBounds.value = it.boundsInRoot()
                                            },
                                    )
                                    GlassButton(
                                        onClick = { showStaResetDialog = true },
                                        enabled = !connected,
                                        shape = RoundedCornerShape(11.dp),
                                        contentPadding = PaddingValues(8.dp),
                                        modifier = Modifier.size(34.dp),
                                    ) {
                                        Icon(
                                            imageVector = Icons.Default.LinkOff,
                                            contentDescription = stringResource(
                                                R.string.sta_reset_pairing,
                                            ),
                                            tint = staResetIconColor,
                                            modifier = Modifier.size(18.dp),
                                        )
                                    }
                                    GlassButton(
                                        onClick = {
                                            viewModel.cancelStaDiscovery()
                                            openHotspotSettings(context)
                                        },
                                        enabled = !connected,
                                        shape = RoundedCornerShape(11.dp),
                                        contentPadding = PaddingValues(8.dp),
                                        modifier = Modifier
                                            .size(34.dp),
                                    ) {
                                        Icon(
                                            imageVector = Icons.Default.Settings,
                                            contentDescription = stringResource(
                                                R.string.sta_hotspot_settings_short,
                                            ),
                                            tint = colors.onSurfaceVariant,
                                            modifier = Modifier.size(18.dp),
                                        )
                                    }
                                }
                                Spacer(Modifier.height(8.dp))
                                GlassButton(
                                    onClick = {
                                        if (staBusy) {
                                            viewModel.cancelStaDiscovery()
                                        } else {
                                            viewModel.discoverStaCamera()
                                        }
                                    },
                                    enabled = !connected,
                                    shape = RoundedCornerShape(14.dp),
                                    // The button owns its full content plane: the status glyph and
                                    // centered label are independent overlays and never push each
                                    // other sideways as their animated states change.
                                    contentPadding = PaddingValues(0.dp),
                                    textureSeed = WIFI_SETTINGS_BUTTON_TEXTURE_SEED,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .height(42.dp),
                                ) {
                                    Box(
                                        modifier = Modifier.fillMaxSize(),
                                        contentAlignment = Alignment.Center,
                                    ) {
                                        // Fixed left slot. NONE keeps the slot geometry while
                                        // drawing nothing; BUSY and CONNECTED therefore occupy the
                                        // exact same position without disturbing the centered text.
                                        Box(
                                            modifier = Modifier
                                                .align(Alignment.CenterStart)
                                                .padding(start = 8.dp)
                                                .size(18.dp),
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            AnimatedContent(
                                                targetState = staConnectButtonState.icon,
                                                transitionSpec = {
                                                    (
                                                        fadeIn(tween(160)) + scaleIn(
                                                            animationSpec = tween(180),
                                                            initialScale = 0.72f,
                                                        )
                                                    ) togetherWith (
                                                        fadeOut(tween(100)) + scaleOut(
                                                            animationSpec = tween(120),
                                                            targetScale = 0.82f,
                                                        )
                                                    )
                                                },
                                                contentAlignment = Alignment.Center,
                                                label = "staConnectButtonIcon",
                                                modifier = Modifier.fillMaxSize(),
                                            ) { icon ->
                                                when (icon) {
                                                    StaConnectButtonIcon.BUSY ->
                                                        CircularProgressIndicator(
                                                            modifier = Modifier.size(16.dp),
                                                            color = staConnectTextColor,
                                                            strokeWidth = 1.7.dp,
                                                        )
                                                    StaConnectButtonIcon.CONNECTED -> Icon(
                                                        imageVector = Icons.Default.CheckCircle,
                                                        contentDescription = null,
                                                        tint = staConnectTextColor,
                                                        modifier = Modifier.size(18.dp),
                                                    )
                                                    StaConnectButtonIcon.NONE -> Unit
                                                }
                                            }
                                        }
                                        AnimatedContent(
                                            targetState = staConnectButtonState,
                                            transitionSpec = {
                                                // Connection progresses down the enum, so the old
                                                // label rolls out above and the next detent rises
                                                // from below. Cancellation/failure reverses the
                                                // motion back to the idle action.
                                                val direction = if (
                                                    targetState.ordinal >= initialState.ordinal
                                                ) {
                                                    1
                                                } else {
                                                    -1
                                                }
                                                (
                                                    slideInVertically(
                                                        animationSpec = tween(
                                                            durationMillis = 220,
                                                            easing = FastOutSlowInEasing,
                                                        ),
                                                        initialOffsetY = { height ->
                                                            height * direction
                                                        },
                                                    ) + fadeIn(
                                                        tween(
                                                            durationMillis = 150,
                                                            delayMillis = 35,
                                                        ),
                                                    )
                                                ) togetherWith (
                                                    slideOutVertically(
                                                        animationSpec = tween(
                                                            durationMillis = 190,
                                                            easing = FastOutSlowInEasing,
                                                        ),
                                                        targetOffsetY = { height ->
                                                            -height * direction
                                                        },
                                                    ) + fadeOut(tween(120))
                                                )
                                            },
                                            contentAlignment = Alignment.Center,
                                            label = "staConnectButtonText",
                                            modifier = Modifier
                                                .align(Alignment.Center)
                                                .fillMaxWidth(),
                                        ) { buttonState ->
                                            Text(
                                                text = staConnectButtonLabels[buttonState.ordinal],
                                                style = staConnectButtonTextStyle,
                                                color = staConnectTextColor,
                                                maxLines = 1,
                                                textAlign = TextAlign.Center,
                                                modifier = Modifier.fillMaxWidth(),
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    )
                }

                Spacer(Modifier.weight(1f))

                // 工作台在空间关系上位于连接页下方，入口贴近屏幕底部提示下滑方向。
                GlassButton(
                    onClick = onOpenLocalPhotoEffects,
                    shape = RoundedCornerShape(16.dp),
                    contentPadding = PaddingValues(horizontal = 18.dp, vertical = 10.dp),
                    modifier = Modifier.height(44.dp),
                ) {
                    Icon(
                        Icons.Default.PhotoFilter,
                        contentDescription = null,
                        tint = colors.accentBlue,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = stringResource(R.string.local_photo_effects_entry),
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.SemiBold,
                        color = colors.onBackground,
                    )
                    Spacer(Modifier.width(4.dp))
                    Icon(
                        Icons.Default.KeyboardArrowDown,
                        contentDescription = null,
                        tint = colors.onSurfaceVariant,
                        modifier = Modifier.size(18.dp),
                    )
                }
                Spacer(Modifier.height(18.dp))
            }
        }

        // ---------- 左上角 "Z传" 设置入口；右上角只保留必要的订阅续期提示。
        // 高级版购买、激活、已激活状态和常驻续费入口全部统一放进设置面板。 ----------
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
                // 钛合金主题使用品牌黄填充钢印；其余主题仍保留 ZMark 原本的前景色。
                materialContentColor = colors.accentYellow,
                modifier = Modifier
                    .height(36.dp)
                    .onGloballyPositioned { zAnchor = it.boundsInRoot() }
            ) {
                // 双 Z 标（原"Z传"文本，换成自绘的尼康 Z 系列标志更简洁）。
                ZMark(modifier = Modifier.height(20.dp))
            }
            DebugSimulatorButton(onClick = viewModel::connectDebugSimulator)
            Spacer(modifier = Modifier.weight(1f))
            renewalNotice?.let { (noticeText, renewable) ->
                RenewalNoticeTag(
                    text = noticeText,
                    renewable = renewable,
                    onClick = { showRenewInfo = true },
                )
            }
        }
        if (showRenewInfo) {
            RenewDialog(
                onDismiss = { showRenewInfo = false },
                onCelebrate = {
                    licenseRefreshNonce++
                    fireworks.launch()
                },
                onHoldCameraWifi = { viewModel.holdCameraWifi(it) }
            )
        }
        // 临期标签继续进入原有续费确认弹窗；设置页中的常驻续费入口保持独立。
        // ---------- 设置面板：从 "Z传" 按钮位置变形展开 ----------
        if (showSettings) {
            SettingsOverlay(
                viewModel = transferViewModel,
                showPhotoEffectsEntry = false,
                anchorBounds = zAnchor,
                onDismiss = { showSettings = false },
                onPlayFireworks = { fireworks.launch() },
                onLicenseUpdated = { licenseRefreshNonce++ },
                onHoldCameraWifi = { viewModel.holdCameraWifi(it) },
                cameraConnectionType = state.connectionType,
                cameraConnected = connected,
                cameraIsStaMode = state.isStaConnection,
            )
        }

        // ---------- 小技巧气泡：从 tips 按钮变形弹出的毛玻璃内容框 ----------
        tipsPopupAnchor?.let { frozenAnchor ->
            TipsBubble(
                anchorBounds = frozenAnchor,
                wirelessMode = state.wirelessMode,
                onDismiss = { tipsPopupAnchor = null },
            )
        }

        if (showStaResetDialog) {
            ResetStaPairingDialog(
                pairedCameraCount = viewModel.pairedStaCameraCount(),
                pairedCameraModels = viewModel.pairedStaCameraModels(),
                onConfirm = {
                    showStaResetDialog = false
                    viewModel.resetStaPairing()
                },
                onDismiss = { showStaResetDialog = false },
            )
        }

        // ---------- 高级版烟花彩蛋：放在最上层（含设置面板之上），不拦截触摸，播完自行移除 ----------
        FireworksOverlay(
            state = fireworks,
            hapticsEnabled = transferState.hapticsEnabled,
        )
    }
}

private const val CONNECTION_ATTENTION_MS = 2_400
private const val WIFI_PROBING_FEEDBACK_DELAY_MS = 350L
private const val USB_CARD_BADGE_TEXTURE_SEED = 0x554253
private const val WIFI_CARD_BADGE_TEXTURE_SEED = 0x57494649

internal fun openHotspotSettings(context: android.content.Context) {
    val candidates = listOf(
        // AOSP's hotspot detail action deliberately uses the Settings package namespace
        // ("com.android.settings"), not the public "android.settings" namespace.  The old
        // spelling did not resolve on stock-compatible ROMs, so the code always fell through
        // to the broader tethering page and made the user tap "Personal hotspot" once more.
        Intent("com.android.settings.WIFI_TETHER_SETTINGS"),
        // Some OEMs remove the action filter but retain the stock exported activity.
        Intent().setClassName(
            "com.android.settings",
            "com.android.settings.Settings\$WifiTetherSettingsActivity",
        ),
        // Keep the non-standard spelling as an OEM compatibility fallback only.
        Intent("android.settings.WIFI_TETHER_SETTINGS"),
        Intent("android.settings.TETHER_SETTINGS"),
        Intent(Settings.ACTION_WIRELESS_SETTINGS),
    )
    // A resolvable OEM activity can still reject a third-party launch. Try the next candidate
    // instead of selecting once and silently doing nothing after SecurityException.
    candidates.firstOrNull { candidate ->
        candidate.resolveActivity(context.packageManager) != null &&
            runCatching { context.startActivity(candidate) }.isSuccess
    }
}

/**
 * 物理链路只是候选证据。无线模式必须等真实相机会话建立后才能进入 hero 场景；
 * 有线部分保留既有的“检测到设备即选中”交互。
 */
internal fun homeSelectedConnection(
    connected: Boolean,
    connectionType: CameraConnectionType?
): CameraConnectionType? = when {
    connectionType == CameraConnectionType.USB -> CameraConnectionType.USB
    connected && connectionType == CameraConnectionType.WIFI -> CameraConnectionType.WIFI
    else -> null
}

internal fun shouldShowWifiConnectionFeedback(
    connectionType: CameraConnectionType?
): Boolean = connectionType != CameraConnectionType.USB

internal fun shouldShowCameraHotspotFeedback(
    connectionType: CameraConnectionType?,
    isStaConnection: Boolean = false,
    staStatus: StaConnectionStatus = StaConnectionStatus.IDLE,
    wirelessMode: WirelessMode = WirelessMode.AP,
): Boolean = shouldShowWifiConnectionFeedback(connectionType) &&
    wirelessMode == WirelessMode.AP && !isStaConnection &&
    staStatus == StaConnectionStatus.IDLE

private data class ConnectionCardFeedback(
    val title: String,
    val body: String?,
    val accent: Color,
    val busy: Boolean = false,
    val multiline: Boolean = false,
)

private enum class StaConnectButtonState(
    val labelRes: Int,
    val icon: StaConnectButtonIcon = StaConnectButtonIcon.NONE,
) {
    IDLE(R.string.sta_connect_action),
    SEARCHING(R.string.sta_status_searching, StaConnectButtonIcon.BUSY),
    PAIRING(R.string.sta_status_pairing, StaConnectButtonIcon.BUSY),
    CONNECTING(R.string.sta_status_connecting, StaConnectButtonIcon.BUSY),
    CONNECTED(R.string.sta_status_connected, StaConnectButtonIcon.CONNECTED),
}

private enum class StaConnectButtonIcon { NONE, BUSY, CONNECTED }

@Composable
private fun WifiModeTabs(
    selectedMode: WirelessMode,
    enabled: Boolean,
    onSelectAp: () -> Unit,
    onSelectSta: () -> Unit,
) {
    val colors = AppTheme.colors
    val containerShape = remember { RoundedCornerShape(10.dp) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(30.dp)
            .clip(containerShape)
            .background(colors.onBackground.copy(alpha = 0.055f))
            .padding(2.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        listOf(
            WirelessMode.STA to onSelectSta,
            WirelessMode.AP to onSelectAp,
        ).forEach { (mode, onClick) ->
            val selected = selectedMode == mode
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .clip(RoundedCornerShape(8.dp))
                    .background(
                        if (selected) colors.accentBlue.copy(alpha = 0.16f)
                        else Color.Transparent,
                    )
                    .clickable(enabled = enabled && !selected, onClick = onClick),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = mode.name,
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                    color = if (selected) colors.accentBlue else colors.onSurfaceVariant,
                )
            }
        }
    }
}

/**
 * 每轮只有一个峰值：缓入吸气、柔和呼气、短暂停顿；另一张卡错开半拍。
 * 五次平滑插值让起止速度都归零，避免线性缩放的机械感和峰值处的顿挫。
 */
private fun connectionAttention(phase: Float): Float {
    fun smootherStep(value: Float): Float {
        val x = value.coerceIn(0f, 1f)
        return x * x * x * (x * (x * 6f - 15f) + 10f)
    }
    return when {
        phase < 0.38f -> smootherStep(phase / 0.38f)
        phase < 0.82f -> 1f - smootherStep((phase - 0.38f) / 0.44f)
        else -> 0f
    }
}

@Composable
private fun ConnectionMethodCard(
    modifier: Modifier,
    modeIcon: @Composable (Color, Modifier) -> Unit,
    title: String,
    accent: Color,
    materialSeed: Int,
    steps: List<String>,
    modeSelector: (@Composable () -> Unit)? = null,
    selected: Boolean,
    success: Boolean,
    attentionActive: Boolean,
    attentionPhaseOffset: Float,
    selectionSceneProgress: () -> Float,
    onSuccessAnimationFinished: () -> Unit,
    error: String? = null,
    goldBurst: Boolean = false,
    feedback: ConnectionCardFeedback? = null,
    feedbackFollowsModeSelector: Boolean = false,
    footer: (@Composable () -> Unit)? = null
) {
    val colors = AppTheme.colors
    val shape = remember { RoundedCornerShape(24.dp) }
    val badgeShape = remember { RoundedCornerShape(13.dp) }
    val view = LocalView.current
    // 这是连接页最基本的状态提示，不再依赖 Compose 的动画帧时钟。若某些 Android 16
    // 设备上该时钟停滞，InfiniteTransition 会始终留在首帧。用单调系统时间
    // 以 30fps 左右更新，只在未选定连接方式的短暂页面存活期运行。
    var attentionPhase by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(attentionActive, attentionPhaseOffset) {
        if (!attentionActive) {
            attentionPhase = 0f
            return@LaunchedEffect
        }
        val startedAt = SystemClock.uptimeMillis()
        while (isActive) {
            val elapsed = SystemClock.uptimeMillis() - startedAt
            attentionPhase = (
                (elapsed % CONNECTION_ATTENTION_MS).toFloat() / CONNECTION_ATTENTION_MS +
                    attentionPhaseOffset
                ).mod(1f)
            delay(CONNECTION_ATTENTION_FRAME_MS)
        }
    }
    var iconCenterInRoot by remember { mutableStateOf<Offset?>(null) }
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
    val probeProgress = animateFloatAsState(
        targetValue = if (feedback?.busy == true && !selected) 1f else 0f,
        animationSpec = spring(dampingRatio = 0.62f, stiffness = 420f),
        label = "connectionProbeLift"
    )

    fun eased(value: Float): Float {
        val x = value.coerceIn(0f, 1f)
        return x * x * (3f - 2f * x)
    }
    // 场景进度只在图层阶段求值，避免动画状态把整张卡片带入逐帧重组。
    fun cardExitProgress(): Float {
        val scene = eased(selectionSceneProgress())
        // 失败时让胜出卡恢复，继续承载错误信息；正常流程中两张卡一起退场。
        return if (selected && error != null) 0f else scene
    }
    fun heroProgress(): Float = if (selected && error == null) {
        eased(selectionSceneProgress())
    } else {
        0f
    }
    // 用真实屏幕坐标定位飞出终点：横向严格居中，纵向落在屏幕上三分之一处。
    val targetCenterX = view.width / 2f
    val targetCenterY = view.height / 3f
    val heroTravelX = iconCenterInRoot?.let { targetCenterX - it.x } ?: 0f
    val heroTravelY = iconCenterInRoot?.let { targetCenterY - it.y } ?: 0f

    Box(
        modifier = modifier
            .zIndex(if (selected) 3f else 0f)
            // 呼吸和按压放在共同父层：玻璃卡、文字、按钮、模式图标始终同步形变。
            .graphicsLayer {
                val attention = if (attentionActive) connectionAttention(attentionPhase) else 0f
                val breathingScale = 1f + attention * 0.04f
                val deformation = pressDeformation
                scaleX = breathingScale * (1f + deformation * 0.012f)
                scaleY = breathingScale * (1f - deformation * 0.024f)
                rotationZ = pressDirection * deformation * 1.15f
                translationX = pressDirection * deformation * 1.5.dp.toPx()
            }
    ) {
        ConnectionCardSurface(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    val exitProgress = cardExitProgress()
                    val exitScale = 1f - exitProgress * 0.045f
                    scaleX = exitScale
                    scaleY = exitScale
                    translationY = exitProgress * 8.dp.toPx()
                    alpha = 1f - exitProgress
                },
            shape = shape,
            tint = when {
                error != null -> colors.statusError.copy(alpha = 0.055f)
                feedback != null && !feedback.busy ->
                    feedback.accent.copy(alpha = 0.045f)
                attentionActive -> accent.copy(alpha = 0.018f)
                else -> Color.Transparent
            }
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .connectionCardMaterialFrame(shape),
            ) {
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

                    Spacer(Modifier.height(if (modeSelector == null) 20.dp else 10.dp))
                    modeSelector?.let {
                        it()
                        Spacer(
                            Modifier.height(
                                if (feedbackFollowsModeSelector && feedback != null) 4.dp
                                else 12.dp,
                            ),
                        )
                    }
                    steps.forEachIndexed { index, text ->
                        ConnectionStep(index + 1, text, accent)
                        if (index != steps.lastIndex) Spacer(Modifier.height(13.dp))
                    }

                    AnimatedContent(
                        targetState = feedback,
                        transitionSpec = {
                            when {
                                initialState == null && targetState != null ->
                                    (
                                        fadeIn(
                                            animationSpec = tween(
                                                durationMillis = 220,
                                                delayMillis = 35,
                                                easing = FastOutSlowInEasing
                                            )
                                        ) + slideInVertically(
                                            animationSpec = tween(
                                                durationMillis = 260,
                                                easing = FastOutSlowInEasing
                                            ),
                                            initialOffsetY = { it / 4 }
                                        )
                                    ) togetherWith fadeOut(tween(90))

                                initialState != null && targetState == null ->
                                    fadeIn(tween(90)) togetherWith (
                                        fadeOut(tween(150)) + slideOutVertically(
                                            animationSpec = tween(
                                                durationMillis = 180,
                                                easing = FastOutSlowInEasing
                                            ),
                                            targetOffsetY = { it / 8 }
                                        )
                                    )

                                else ->
                                    fadeIn(
                                        tween(
                                            durationMillis = 180,
                                            easing = FastOutSlowInEasing
                                        )
                                    ) togetherWith fadeOut(tween(120))
                            }
                        },
                        label = "connectionCardFeedback"
                    ) { animatedFeedback ->
                        if (animatedFeedback != null) {
                            Column(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalAlignment = Alignment.Start,
                            ) {
                                if (!feedbackFollowsModeSelector) {
                                    Spacer(Modifier.height(12.dp))
                                }
                                Row(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(10.dp))
                                        .background(
                                            animatedFeedback.accent.copy(alpha = 0.10f)
                                        )
                                        .padding(horizontal = 9.dp, vertical = 7.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    if (animatedFeedback.busy) {
                                        CircularProgressIndicator(
                                            modifier = Modifier.size(14.dp),
                                            color = animatedFeedback.accent,
                                            strokeWidth = 1.5.dp
                                        )
                                        Spacer(Modifier.width(7.dp))
                                    }
                                    Column {
                                        Text(
                                            text = animatedFeedback.title,
                                            style = MaterialTheme.typography.labelSmall,
                                            fontWeight = FontWeight.Bold,
                                            color = animatedFeedback.accent,
                                            maxLines = if (animatedFeedback.multiline) 2 else 1,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                        animatedFeedback.body?.let { body ->
                                            Text(
                                                text = body,
                                                style = MaterialTheme.typography.labelSmall,
                                                color = colors.onSurfaceVariant,
                                                maxLines = if (animatedFeedback.multiline) 3 else 1,
                                                overflow = TextOverflow.Ellipsis,
                                            )
                                        }
                                    }
                                }
                            }
                        }
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
                        footer()
                    }
                }

            }
        }

        // 42dp 飞行容器保持原本卡片内的精确位置；成功效果用 requiredSize 从该中心
        // 向外溢出，不让 220dp 动画画布及负偏移参与卡片布局。
        Box(
            modifier = Modifier
                .offset(x = 14.dp, y = 16.dp)
                .size(42.dp)
                .zIndex(4f)
                .onGloballyPositioned { coordinates ->
                    if (!selected || iconCenterInRoot == null) {
                        iconCenterInRoot = coordinates.boundsInRoot().center
                    }
                }
                .graphicsLayer {
                    val heroSceneProgress = heroProgress()
                    translationX = heroTravelX * heroSceneProgress
                    translationY = heroTravelY * heroSceneProgress -
                        kotlin.math.sin(heroSceneProgress * Math.PI.toFloat()) * 10.dp.toPx() -
                        probeProgress.value * 5.dp.toPx()
                }
        ) {
            val badgeAccent = if (success) colors.statusConnected else accent
            ConnectionModeBadge(
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        val heroSceneProgress = heroProgress()
                        val exitProgress = cardExitProgress()
                        val heroScale = (1f + heroSceneProgress * 1.12f) *
                            (1f + probeProgress.value * 0.04f)
                        scaleX = heroScale
                        scaleY = heroScale
                        alpha = if (selected) 1f else 1f - exitProgress
                    },
                shape = badgeShape,
                accentColor = badgeAccent,
                contentColor = accent,
                success = success,
                attentionActive = attentionActive,
                probeProgress = probeProgress,
                textureSeed = materialSeed,
                modeIcon = modeIcon,
            )

            ConnectionSuccessOverlay(
                success = success,
                goldBurst = goldBurst,
                onFinished = onSuccessAnimationFinished,
                modifier = Modifier
                    .align(Alignment.Center)
                    .requiredSize(220.dp)
            )
        }
    }
}

/** 连接页右上角的轻量订阅标签；仅临期状态可点击进入原有续费确认流程。 */
@Composable
private fun RenewalNoticeTag(
    text: String,
    renewable: Boolean,
    onClick: () -> Unit,
) {
    val colors = AppTheme.colors
    val shape = RoundedCornerShape(7.dp)
    Row(
        modifier = Modifier
            .widthIn(max = 240.dp)
            .height(26.dp)
            .clip(shape)
            .then(if (renewable) Modifier.clickable(onClick = onClick) else Modifier)
            .background(colors.accentOrange.copy(alpha = 0.12f), shape)
            .border(1.dp, colors.accentOrange.copy(alpha = 0.28f), shape)
            .padding(horizontal = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            color = colors.accentOrange,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** 探测抬升只重组 42dp 图标底座，不再把整张连接卡拖进动画热路径。 */
@Composable
private fun ConnectionModeBadge(
    modifier: Modifier,
    shape: RoundedCornerShape,
    accentColor: Color,
    contentColor: Color,
    success: Boolean,
    attentionActive: Boolean,
    probeProgress: State<Float>,
    textureSeed: Int,
    modeIcon: @Composable (Color, Modifier) -> Unit,
) {
    val probe = probeProgress.value
    SkinMaterialBadge(
        modifier = modifier,
        shape = shape,
        accentColor = accentColor,
        contentColor = contentColor,
        emphasis = if (success) {
            1f
        } else {
            (if (attentionActive) 0.18f else 0.08f) + probe * 0.48f
        },
        textureSeed = textureSeed,
    ) { badgeContentColor ->
        modeIcon(
            badgeContentColor,
            Modifier
                .size(22.dp)
                .align(Alignment.Center)
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
    onFinished: () -> Unit,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    val progress = remember { mutableFloatStateOf(0f) }
    val readProgress = remember(progress) { { progress.floatValue } }
    val currentOnFinished by rememberUpdatedState(onFinished)
    LaunchedEffect(success) {
        if (success) {
            progress.floatValue = 0f
            val startedAt = SystemClock.uptimeMillis()
            while (isActive) {
                val elapsed = SystemClock.uptimeMillis() - startedAt
                val linearProgress =
                    (elapsed.toFloat() / CONNECTION_SUCCESS_DURATION_MS).coerceIn(0f, 1f)
                progress.floatValue = FastOutSlowInEasing.transform(linearProgress)
                if (linearProgress >= 1f) break
                delay(CONNECTION_SUCCESS_FRAME_MS)
            }
            if (isActive) currentOnFinished()
        } else {
            progress.floatValue = 0f
        }
    }
    if (!success) return

    Canvas(
        modifier = modifier
            .graphicsLayer {
                alpha = (readProgress() * 5f).coerceAtMost(1f)
            }
    ) {
        val p = readProgress()
        if (goldBurst) {
            drawPremiumSuccessEffect(p)
        }

        repeat(2) { index ->
            val ringProgress = ((p - index * 0.14f) / 0.72f).coerceIn(0f, 1f)
            val ringScale = 0.72f + ringProgress * 1.72f
            drawCircle(
                color = colors.statusConnected.copy(
                    alpha = (1f - ringProgress) * 0.62f,
                ),
                radius = (41.dp.toPx() - 0.75.dp.toPx()) * ringScale,
                style = Stroke(width = 1.5.dp.toPx() * ringScale),
            )
        }

        if (goldBurst) {
            repeat(10) { index ->
                val angle = (index * 36f + if (index % 2 == 0) 7f else -5f) *
                    (Math.PI.toFloat() / 180f)
                val distance = (48 + (index % 3) * 11).dp.toPx() * p
                drawCircle(
                    color = (if (index % 2 == 0) {
                        Color(0xFFFFE082)
                    } else {
                        Color(0xFFF0A93B)
                    }).copy(alpha = (p * 5f).coerceAtMost(1f) * (1f - p)),
                    radius = (if (index % 3 == 0) 3.dp else 2.dp).toPx(),
                    center = Offset(
                        center.x + cos(angle) * distance,
                        center.y + sin(angle) * distance,
                    ),
                )
            }
        }

        // 不再绘制另一枚“成功图标”；只给原模式图标增加一圈确认脉冲。
        val coreScale = 0.82f + kotlin.math.sin(p * Math.PI.toFloat()) * 0.22f
        val coreAlpha = (1f - p).coerceAtLeast(0.16f)
        drawCircle(
            color = colors.statusConnected.copy(alpha = 0.08f * coreAlpha),
            radius = 39.dp.toPx() * coreScale,
        )
        drawCircle(
            color = colors.statusConnected.copy(alpha = 0.70f * coreAlpha),
            radius = (39.dp.toPx() - 0.75.dp.toPx()) * coreScale,
            style = Stroke(width = 1.5.dp.toPx() * coreScale),
        )
    }
}

@Composable
private fun ResetStaPairingDialog(
    pairedCameraCount: Int,
    pairedCameraModels: List<String>,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = AppTheme.colors
    val pairedCameraSummary = buildList {
        add(stringResource(R.string.sta_paired_camera_count, pairedCameraCount))
        addAll(pairedCameraModels)
    }.joinToString(" · ")
    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = colors.glassSurfaceHeavy,
            border = BorderStroke(1.dp, colors.glassPanelBorder),
            tonalElevation = 6.dp,
        ) {
            Column(modifier = Modifier.padding(20.dp)) {
                Text(
                    text = stringResource(R.string.sta_reset_pairing_title),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = colors.onBackground,
                )
                Spacer(Modifier.height(8.dp))
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(colors.accentBlue.copy(alpha = 0.10f))
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.Default.PhotoCamera,
                        contentDescription = null,
                        tint = colors.accentBlue,
                        modifier = Modifier.size(17.dp),
                    )
                    Spacer(Modifier.width(7.dp))
                    Text(
                        text = pairedCameraSummary,
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = colors.onBackground,
                    )
                }
                Spacer(Modifier.height(10.dp))
                Text(
                    text = stringResource(R.string.sta_reset_pairing_message),
                    style = MaterialTheme.typography.bodyMedium,
                    color = colors.onSurfaceVariant,
                )
                Spacer(Modifier.height(18.dp))
                Row(
                    modifier = Modifier.align(Alignment.End),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TextButton(onClick = onDismiss) {
                        Text(
                            text = stringResource(R.string.cancel),
                            color = colors.onSurfaceVariant,
                        )
                    }
                    Button(
                        onClick = onConfirm,
                        colors = ButtonDefaults.buttonColors(containerColor = colors.statusError),
                        shape = RoundedCornerShape(10.dp),
                    ) {
                        Text(stringResource(R.string.sta_reset_pairing))
                    }
                }
            }
        }
    }
}

/**
 * 高级版专属成功层：暖金能量晕、旋转断续光环和星芒从同一模式图标中心展开。
 * 免费版不进入该分支，原有绿色双脉冲的外观和节奏保持不变。
 */
private fun DrawScope.drawPremiumSuccessEffect(progress: Float) {
    val gold = Color(0xFFFFD66B)
    val warmGold = Color(0xFFF0A93B)
    val p = progress.coerceIn(0f, 1f)
    val appear = (p / 0.16f).coerceIn(0f, 1f)
    val fade = ((1f - p) / 0.30f).coerceIn(0f, 1f)
    val visibility = appear * fade
    val center = this.center

    // 短促的暖金光晕先托起图标，不形成持续的大色块。
    val haloPulse = sin((p.coerceAtMost(0.72f) / 0.72f) * Math.PI.toFloat())
        .coerceAtLeast(0f)
    drawCircle(
        color = gold.copy(alpha = 0.12f * haloPulse),
        radius = size.minDimension * (0.16f + p * 0.16f),
        center = center
    )
    drawCircle(
        color = warmGold.copy(alpha = 0.07f * haloPulse),
        radius = size.minDimension * (0.24f + p * 0.12f),
        center = center
    )

    // 三段旋转断续光环，比免费版完整绿色圆环更精致，也不会抢模式图标。
    rotate(degrees = -32f + p * 118f, pivot = center) {
        val orbitRadius = size.minDimension * (0.22f + p * 0.10f)
        val orbitTopLeft = Offset(center.x - orbitRadius, center.y - orbitRadius)
        val orbitSize = androidx.compose.ui.geometry.Size(orbitRadius * 2f, orbitRadius * 2f)
        repeat(3) { index ->
            drawArc(
                color = if (index == 1) gold.copy(alpha = 0.92f * visibility)
                else warmGold.copy(alpha = 0.72f * visibility),
                startAngle = index * 120f + 8f,
                sweepAngle = 54f,
                useCenter = false,
                topLeft = orbitTopLeft,
                size = orbitSize,
                style = Stroke(width = 1.6.dp.toPx(), cap = StrokeCap.Round)
            )
        }
    }

    // 六枚星芒沿轻微旋转的轨迹展开；长短交错，让高级版具有可辨识的“签名”。
    repeat(6) { index ->
        val phase = ((p - index * 0.025f) / 0.78f).coerceIn(0f, 1f)
        val angle = index * 60f * (Math.PI.toFloat() / 180f) + phase * 0.28f
        val distance = size.minDimension * (0.19f + phase * 0.25f)
        val sparkleCenter = Offset(
            center.x + cos(angle) * distance,
            center.y + sin(angle) * distance
        )
        val sparkleFade = (phase * 5f).coerceAtMost(1f) * (1f - phase)
        val longArm = (if (index % 2 == 0) 7.dp else 5.dp).toPx() *
            (0.7f + sparkleFade * 0.6f)
        val shortArm = longArm * 0.42f
        val sparkleColor = if (index % 2 == 0) gold else Color.White
        val alpha = sparkleFade * 0.95f
        drawLine(
            sparkleColor.copy(alpha = alpha),
            Offset(sparkleCenter.x, sparkleCenter.y - longArm),
            Offset(sparkleCenter.x, sparkleCenter.y + longArm),
            strokeWidth = 1.5.dp.toPx(),
            cap = StrokeCap.Round
        )
        drawLine(
            sparkleColor.copy(alpha = alpha),
            Offset(sparkleCenter.x - shortArm, sparkleCenter.y),
            Offset(sparkleCenter.x + shortArm, sparkleCenter.y),
            strokeWidth = 1.5.dp.toPx(),
            cap = StrokeCap.Round
        )
    }
}

// 连接成功后的入场节奏：先保持当前卡片 [CONNECT_CELEBRATE_DELAY_MS]，再播放卡片内
// 成功动画；动画协程完成后直接通知 MainScreen 跳转，不再用另一套固定时钟猜结束时刻。
const val CONNECT_CELEBRATE_DELAY_MS = 500L
private const val CONNECTION_ATTENTION_FRAME_MS = 32L
private const val CONNECTION_SUCCESS_DURATION_MS = 760L
private const val CONNECTION_SUCCESS_FRAME_MS = 16L
private const val WIFI_SETTINGS_BUTTON_TEXTURE_SEED = 0x1457A102

/** 布局热路径专用的非观察容器；更新坐标不触发 Compose 重组。 */
private class LayoutBoundsHolder(var value: Rect? = null)

/** 连接页 AP/STA 指引气泡；复用全局 [AnchorPopup]，内容全部走多语言资源。 */
@Composable
private fun TipsBubble(
    anchorBounds: Rect?,
    wirelessMode: WirelessMode,
    onDismiss: () -> Unit,
) {
    val density = LocalDensity.current
    // AP 保持贴近按钮；STA 内容更长，单独上移为完整内容预留空间。
    val anchoredPanelTop = anchorBounds?.let {
        with(density) { it.bottom.toDp() } + 24.dp
    } ?: 156.dp
    val panelTop = if (wirelessMode == WirelessMode.STA) {
        (anchoredPanelTop - 144.dp).coerceAtLeast(20.dp)
    } else {
        anchoredPanelTop
    }
    AnchorPopup(
        anchorBounds = anchorBounds,
        onDismiss = onDismiss,
        panelModifier = Modifier
            .padding(start = 20.dp, end = 20.dp, top = panelTop)
            .navigationBarsPadding()
            .fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        dim = false,
    ) { _ ->
        TipBubbleContent(
            title = stringResource(
                if (wirelessMode == WirelessMode.AP) R.string.tip_title
                else R.string.tip_sta_title,
            ),
            items = if (wirelessMode == WirelessMode.AP) {
                listOf(
                    TipBubbleItem(
                        label = stringResource(R.string.tip_ap_mode),
                        text = stringResource(R.string.tip_body),
                    ),
                    TipBubbleItem(
                        text = stringResource(R.string.tip_path),
                        emphasized = true,
                    ),
                )
            } else {
                listOf(
                    TipBubbleItem(
                        label = stringResource(R.string.tip_sta_first_connection),
                        text = stringResource(R.string.tip_sta_steps),
                        emphasized = true,
                    ),
                    TipBubbleItem(
                        label = stringResource(R.string.tip_sta_quick_start),
                        text = stringResource(R.string.tip_body),
                    ),
                    TipBubbleItem(
                        text = stringResource(R.string.tip_path),
                        emphasized = true,
                    ),
                )
            },
        )
    }
}
