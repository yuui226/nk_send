package com.ztransfer

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.updateTransition
import com.ztransfer.ui.theme.Motion
import androidx.compose.foundation.background
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavBackStackEntry
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.ztransfer.ui.screen.*
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.ZTransferTheme
import com.ztransfer.ui.theme.rememberAppBackgroundBrush
import com.ztransfer.ui.util.rememberHaptics
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.protocol.CameraEndpointOverride
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.update.AppUpdateHost
import com.ztransfer.update.AppUpdateManager
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.CameraState
import com.ztransfer.viewmodel.PhotoDateRange
import com.ztransfer.viewmodel.TransferState
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferViewModel
import com.ztransfer.viewmodel.WirelessMode
import com.ztransfer.viewmodel.isTransferredOriginal
import kotlinx.coroutines.delay
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val notificationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* 结果不阻断使用 */ }

    // 冷启动时包装基座 Context；运行中切换由 Compose 根节点替换本地化 Context，
    // 不重建 Activity，因此当前导航、照片列表和滚动位置都不会抖动。
    override fun attachBaseContext(newBase: android.content.Context) {
        super.attachBaseContext(AppLocale.wrap(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Debug 源集启动内置回环相机；Release 源集实现为空，不包含任何模拟入口。
        CameraEndpointOverride.applyLaunchIntent(intent)
        // 加载本地通行证（本地验签，毫秒级），并在有网时执行每日软续签；通行证最长有效 7 天。
        com.ztransfer.license.LicenseManager.init(applicationContext)
        // 每 6 小时至多检查一次；软更新每日最多提示一次，硬更新始终阻止继续使用。
        AppUpdateManager.init(applicationContext)
        enableEdgeToEdge()   // 内容延伸到系统栏后面，各屏自行处理 inset
        val showFirstLaunchNotificationHint = shouldShowFirstLaunchNotificationHint(
            sdkInt = Build.VERSION.SDK_INT,
            firstLaunch = claimFirstLaunch(),
            permissionGranted = hasNotificationPermission()
        )
        setContent {
            // 主题模式存在 TransferViewModel（与其它设置同处持久化），
            // 在主题之上先取出来，切换即全局重排配色。
            val transferViewModel: TransferViewModel = viewModel()
            val transferState by transferViewModel.state.collectAsState()
            val baseContext = LocalContext.current
            val baseConfiguration = LocalConfiguration.current
            // Configuration 可能由宿主原位更新；用内容指纹作键，横竖屏、窗口尺寸等变化时
            // 也会重建对应的本地化 Resources，而不是错误复用旧配置。
            val baseConfigurationHash = baseConfiguration.hashCode()
            val localeContext = remember(
                baseContext,
                baseConfigurationHash,
                transferState.appLanguage,
            ) {
                AppLocale.forComposition(baseContext, transferState.appLanguage)
            }
            CompositionLocalProvider(
                LocalContext provides localeContext.context,
                LocalConfiguration provides localeContext.configuration,
            ) {
                ZTransferTheme(themeMode = transferState.themeMode, skinPreset = transferState.skinPreset) {
                    Box(Modifier.fillMaxSize()) {
                        MainScreen(transferViewModel)
                        var hintVisible by remember { mutableStateOf(showFirstLaunchNotificationHint) }
                        LaunchedEffect(showFirstLaunchNotificationHint) {
                            if (!showFirstLaunchNotificationHint) return@LaunchedEffect
                            // 先让居中气泡绘制一帧，再呼出系统权限框。
                            withFrameNanos { }
                            requestNotificationPermissionIfNeeded()
                            delay(FIRST_LAUNCH_HINT_DURATION_MS)
                            hintVisible = false
                        }
                        AnimatedVisibility(
                            visible = hintVisible,
                            enter = fadeIn(tween(200)) +
                                scaleIn(initialScale = 0.96f, animationSpec = tween(200)),
                            exit = fadeOut(tween(260)),
                            modifier = Modifier
                                .align(Alignment.Center)
                                .padding(horizontal = 24.dp)
                        ) {
                            FirstLaunchNotificationHint()
                        }
                    }
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        // 从微信返回、Activity 重建时补完已付款但本地尚未落证的订单。
        com.ztransfer.license.LicenseManager.onAppForeground()
    }

    private fun hasNotificationPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED

    /** 读取并记录“安装后首次启动”，Activity 重建和以后启动都返回 false。 */
    private fun claimFirstLaunch(): Boolean {
        val prefs = getSharedPreferences(FIRST_LAUNCH_PREFERENCES, MODE_PRIVATE)
        if (prefs.getBoolean(KEY_HAS_LAUNCHED, false)) return false
        prefs.edit().putBoolean(KEY_HAS_LAUNCHED, true).apply()
        return true
    }

    /** Android 13+ 需运行时授权才能在通知栏展示前台任务状态。 */
    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (!hasNotificationPermission()) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    private companion object {
        const val FIRST_LAUNCH_PREFERENCES = "ztransfer_first_launch"
        const val KEY_HAS_LAUNCHED = "has_launched"
        const val FIRST_LAUNCH_HINT_DURATION_MS = 4_000L
    }
}

sealed class Screen(val route: String) {
    object Home : Screen("home")
    object Files : Screen("files")
    object Transfer : Screen("transfer")
    object Remote : Screen("remote")   // 无线遥控页，位于文件页左侧
}

internal fun shouldPreferHighThroughputTransfers(route: String?): Boolean =
    route == Screen.Files.route || route == Screen.Transfer.route

/**
 * 照片列表与传输队列属于同一个高频工作区，不通过 NavHost 反复入栈。两态内容动画
 * 天然只有一个当前目标；用户连续反向操作时从现有进度转向，不会累积导航条目。
 */
@Composable
private fun FilesQueueWorkspace(
    queueVisible: Boolean,
    onFilesSettledChanged: (Boolean) -> Unit,
    filesContent: @Composable () -> Unit,
    queueContent: @Composable () -> Unit,
    queueTopContent: @Composable () -> Unit,
) {
    val stateHolder = rememberSaveableStateHolder()
    val transition = updateTransition(
        targetState = queueVisible,
        label = "filesQueueTransition",
    )
    val currentOnFilesSettledChanged by rememberUpdatedState(onFilesSettledChanged)
    LaunchedEffect(transition) {
        snapshotFlow {
            !transition.isRunning &&
                !transition.currentState &&
                !transition.targetState
        }
            .distinctUntilChanged()
            .collect { settled -> currentOnFilesSettledChanged(settled) }
    }
    val topControlsProgress = transition.animateFloat(
        transitionSpec = {
            if (targetState) {
                tween(
                    durationMillis = 140,
                    delayMillis = Motion.QUEUE_PAGE_SLIDE_MS,
                    easing = FastOutSlowInEasing,
                )
            } else {
                tween(durationMillis = 80, easing = FastOutSlowInEasing)
            }
        },
        label = "queueTopControls",
    ) { showingQueue ->
        if (showingQueue) 1f else 0f
    }

    Box(Modifier.fillMaxSize()) {
        transition.AnimatedContent(
            modifier = Modifier.fillMaxSize(),
            transitionSpec = {
                if (targetState) {
                    val enterQueue = slideInHorizontally(Motion.queuePageSlide) { it } +
                        fadeIn(
                            tween(220, easing = FastOutSlowInEasing),
                            initialAlpha = 0.72f,
                        )
                    val exitFiles = slideOutHorizontally(Motion.queuePageSlide) { -it / 3 } +
                        fadeOut(
                            tween(Motion.PAGE_FADE_MS),
                            targetAlpha = 0.5f,
                        )
                    (enterQueue togetherWith exitFiles).apply { targetContentZIndex = 1f }
                } else {
                    val enterFiles = slideInHorizontally(Motion.queuePageSlide) { -it / 3 } +
                        fadeIn(
                            tween(Motion.PAGE_FADE_MS),
                            initialAlpha = 0.5f,
                        )
                    val exitQueue = slideOutHorizontally(Motion.queuePageSlide) { it } +
                        fadeOut(
                            tween(140, easing = FastOutSlowInEasing),
                            targetAlpha = 0.72f,
                        )
                    (enterFiles togetherWith exitQueue).apply { targetContentZIndex = 0f }
                }
            },
            contentKey = { it },
        ) { showingQueue ->
            val stateKey = if (showingQueue) "transferQueue" else "cameraFiles"
            stateHolder.SaveableStateProvider(stateKey) {
                if (showingQueue) queueContent() else filesContent()
            }
        }

        // 顶栏不参与横向位移或缩放。等正文横向转场彻底完成后才在原位淡入，避免
        // 返回/信号按钮与仍在滑出的照片页重叠；返回时则立即淡出。
        if (transition.currentState || transition.targetState) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .fillMaxWidth()
                    .graphicsLayer {
                        alpha = topControlsProgress.value
                    },
            ) {
                queueTopContent()
            }
        }
    }
}

/** Navigation Compose 会在目的地转场真正结束后才把当前条目推进到 RESUMED。 */
@Composable
private fun rememberBackStackEntryResumed(entry: NavBackStackEntry?): Boolean {
    var resumed by remember(entry) {
        mutableStateOf(entry?.lifecycle?.currentState == Lifecycle.State.RESUMED)
    }
    DisposableEffect(entry) {
        val lifecycle = entry?.lifecycle
        if (lifecycle == null) {
            resumed = false
            onDispose { }
        } else {
            fun update() {
                resumed = lifecycle.currentState == Lifecycle.State.RESUMED
            }
            val observer = LifecycleEventObserver { _, _ -> update() }
            lifecycle.addObserver(observer)
            update()
            onDispose { lifecycle.removeObserver(observer) }
        }
    }
    return resumed
}

private data class MainCameraUiState(
    val isConnectedToCamera: Boolean,
    val connectionType: CameraConnectionType?,
    val wirelessMode: WirelessMode,
)

private fun CameraState.toMainCameraUiState(): MainCameraUiState = MainCameraUiState(
    isConnectedToCamera = isConnectedToCamera,
    connectionType = connectionType,
    wirelessMode = wirelessMode,
)

private data class MainTransferUiState(
    val isTransferring: Boolean,
    val keepScreenOn: Boolean,
    val filterDateRange: PhotoDateRange?,
)

private fun TransferState.toMainTransferUiState(): MainTransferUiState = MainTransferUiState(
    isTransferring = isTransferring,
    keepScreenOn = keepScreenOn,
    filterDateRange = filterDateRange,
)

internal fun shouldShowFirstLaunchNotificationHint(
    sdkInt: Int,
    firstLaunch: Boolean,
    permissionGranted: Boolean
): Boolean = sdkInt >= Build.VERSION_CODES.TIRAMISU && firstLaunch && !permissionGranted

@Composable
private fun FirstLaunchNotificationHint() {
    val colors = AppTheme.colors
    Surface(
        modifier = Modifier.widthIn(max = 380.dp),
        shape = RoundedCornerShape(22.dp),
        color = colors.glassSurfaceHeavy,
        border = BorderStroke(1.dp, colors.glassPanelBorder)
    ) {
        Text(
            text = stringResource(R.string.notification_permission_first_launch_hint),
            textAlign = TextAlign.Center,
            style = MaterialTheme.typography.labelLarge,
            color = colors.onBackground,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp)
        )
    }
}

/** Shared bottom glass bubble for lightweight, non-blocking action feedback. */
@Composable
private fun BottomGlassHint(
    text: String,
    modifier: Modifier = Modifier,
    verticalPadding: Dp = 10.dp,
) {
    val colors = AppTheme.colors
    Surface(
        modifier = modifier.widthIn(max = 340.dp),
        shape = RoundedCornerShape(22.dp),
        color = colors.glassSurfaceHeavy,
        border = BorderStroke(1.dp, colors.glassPanelBorder),
    ) {
        Text(
            text = text,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = verticalPadding),
            textAlign = TextAlign.Center,
            style = MaterialTheme.typography.labelLarge,
            color = colors.onBackground,
        )
    }
}

/**
 * 照片列表与传输页共用同一个顶部队列控件实例。它位于 NavHost 之外，因此两页横向
 * 切换时不会随页面退场、重建并重播胶囊动画；只有点击语义随当前页面变化。
 */
@Composable
private fun SharedQueueControls(
    route: String,
    transferViewModel: TransferViewModel,
    cameraViewModel: CameraViewModel,
    heldCount: Int,
    catchNonce: Long,
    filePreviewVisible: Boolean,
    onBoundsChanged: (Rect) -> Unit,
    onNavigateToTransfer: () -> Unit,
    onControlAction: () -> Unit,
) {
    val transferState by transferViewModel.state.collectAsState()
    val cameraConnected by remember(cameraViewModel) {
        cameraViewModel.state
            .map { it.isConnectedToCamera }
            .distinctUntilChanged()
    }.collectAsState(initial = cameraViewModel.state.value.isConnectedToCamera)
    val haptics = rememberHaptics(transferState.hapticsEnabled)
    val waitingCount = remember(transferState.tasks) {
        transferState.tasks.count { it.status == TransferStatus.WAITING }
    }
    val executionControl = queueExecutionControl(
        isTransferring = transferState.isTransferring,
        waitingCount = waitingCount,
    )
    var retainedExecutionControl by remember {
        mutableStateOf(executionControl ?: QueueExecutionControl.START)
    }
    LaunchedEffect(executionControl) {
        executionControl?.let { retainedExecutionControl = it }
    }
    val waitingNeedsCamera = remember(
        transferState.tasks,
        transferState.existingExportIndex,
    ) {
        transferState.tasks.any { task ->
            task.status == TransferStatus.WAITING &&
                !isTransferredOriginal(
                    task.file,
                    transferState.existingExportIndex,
                    task.destinationFolderName,
                )
        }
    }

    val catchScale = remember { Animatable(1f) }
    LaunchedEffect(catchNonce) {
        if (catchNonce > 0L) {
            catchScale.animateTo(1.18f, tween(110, easing = FastOutSlowInEasing))
            catchScale.animateTo(1f, Motion.bouncy())
        }
    }

    var pauseHintVisible by remember { mutableStateOf(false) }
    var pauseHintNonce by remember { mutableLongStateOf(0L) }
    LaunchedEffect(pauseHintNonce) {
        if (pauseHintNonce > 0L && pauseHintVisible) {
            delay(2_200)
            pauseHintVisible = false
        }
    }

    Box(Modifier.fillMaxSize()) {
        // 入队飞行只需要固定的右缘与垂直中心；锚点独立于会逐帧变宽的胶囊，
        // 速度/数量变化时不再重复计算全局坐标或向 MainScreen 回写状态。
        Box(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(end = 12.dp, top = 6.dp),
        ) {
            Spacer(
                modifier = Modifier
                    .size(width = 1.dp, height = 36.dp)
                    .onGloballyPositioned { coordinates ->
                        if (coordinates.isAttached) {
                            val bounds = coordinates.boundsInRoot()
                            if (bounds.width > 0f && bounds.height > 0f) {
                                onBoundsChanged(bounds)
                            }
                        }
                    }
            )
        }

        Box(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(horizontal = 12.dp, vertical = 6.dp),
        ) {
            Row(
                modifier = Modifier
                    .graphicsLayer {
                        transformOrigin = TransformOrigin(1f, 0.5f)
                        scaleX = catchScale.value
                        scaleY = catchScale.value
                    },
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                AnimatedVisibility(
                    visible = executionControl != null &&
                        !(route == Screen.Files.route && filePreviewVisible),
                    enter = fadeIn(tween(160)) + scaleIn(
                        initialScale = 0.72f,
                        animationSpec = Motion.bouncy(),
                    ),
                    exit = fadeOut(tween(120)) + scaleOut(
                        targetScale = 0.72f,
                        animationSpec = tween(140),
                    ),
                ) {
                    QueueExecutionButton(
                        control = retainedExecutionControl,
                        pauseRequested = transferState.pauseAfterCurrent,
                        startEnabled = cameraConnected || !waitingNeedsCamera,
                        onStart = {
                            onControlAction()
                            haptics.tick()
                            transferViewModel.startPendingTransfers(cameraViewModel::getCamera)
                        },
                        onPause = {
                            if (transferState.isTransferring &&
                                !transferState.pauseAfterCurrent
                            ) {
                                onControlAction()
                                haptics.tick()
                                transferViewModel.requestPauseAfterCurrent()
                                pauseHintVisible = true
                                pauseHintNonce++
                            }
                        },
                    )
                }

                AnimatedVisibility(
                    visible = route == Screen.Files.route || transferState.tasks.isNotEmpty(),
                    enter = fadeIn() + scaleIn(initialScale = 0.6f),
                    exit = fadeOut() + scaleOut(targetScale = 0.6f),
                ) {
                    QueuePill(
                        transferState = transferState,
                        activeProgressFlow = transferViewModel.activeTransferProgress,
                        heldCount = heldCount,
                        haptics = haptics,
                        onClick = {
                            if (route == Screen.Files.route) {
                                onNavigateToTransfer()
                            }
                        },
                    )
                }
            }
        }

        AnimatedVisibility(
            visible = pauseHintVisible,
            enter = fadeIn() + slideInVertically { it / 2 },
            exit = fadeOut() + slideOutVertically { it / 2 },
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 28.dp),
        ) {
            BottomGlassHint(text = stringResource(R.string.pause_after_current_hint))
        }
    }
}

@Composable
fun MainScreen(transferViewModel: TransferViewModel) {
    val navController = rememberNavController()
    val cameraViewModel: CameraViewModel = viewModel()
    var staReconnectHintVisible by remember { mutableStateOf(false) }
    var staReconnectHintNonce by remember { mutableLongStateOf(0L) }
    LaunchedEffect(cameraViewModel) {
        cameraViewModel.staReconnectRequests.collect {
            staReconnectHintVisible = true
            staReconnectHintNonce++
        }
    }
    LaunchedEffect(staReconnectHintNonce) {
        if (staReconnectHintNonce > 0L && staReconnectHintVisible) {
            delay(1_800L)
            staReconnectHintVisible = false
        }
    }

    // 照片列表（含其上的大图预览）和传输页都优先保证无线传输吞吐。两页之间切换时
    // 布尔值保持 true，不会产生一次 false 的瞬态；每个文件进入协议层前再冻结策略，
    // 因此已经开始的文件也不会中途换道。
    val currentBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = currentBackStackEntry?.destination?.route
    val currentDestinationResumed = rememberBackStackEntryResumed(currentBackStackEntry)
    var queuePageVisible by rememberSaveable { mutableStateOf(false) }
    val context = LocalContext.current
    val exitHintBottomPadding = (LocalConfiguration.current.screenHeightDp * 0.12f).dp
    val backExitHint = stringResource(R.string.return_again_to_exit)
    var lastBackTime by rememberSaveable { mutableLongStateOf(0L) }
    var backExitHintVisible by remember { mutableStateOf(false) }
    var backExitHintNonce by remember { mutableLongStateOf(0L) }
    val activeWorkspaceRoute = if (
        currentRoute == Screen.Files.route && queuePageVisible
    ) {
        Screen.Transfer.route
    } else {
        currentRoute
    }
    LaunchedEffect(currentRoute, queuePageVisible) {
        lastBackTime = 0L
        backExitHintVisible = false
        if (currentRoute != null && currentRoute != Screen.Files.route) {
            queuePageVisible = false
        }
    }
    LaunchedEffect(backExitHintNonce) {
        if (backExitHintNonce > 0L && backExitHintVisible) {
            delay(1_800L)
            backExitHintVisible = false
        }
    }
    // 页面级 BackHandler（弹窗、预览、工作台、队列等）在组合树后部注册，会优先消费返回；
    // 只有没有其它返回动作时，才落到这里执行全局二次退出确认。
    // 照片列表页另有一层页内拦截复用此回调，防止 NavHost 默认返回连接页。
    val requestExitConfirmation: () -> Unit = {
        val now = System.currentTimeMillis()
        if (now - lastBackTime < 2_000L) {
            context.findActivity()?.finish()
            lastBackTime = 0L
            backExitHintVisible = false
        } else {
            lastBackTime = now
            backExitHintVisible = true
            backExitHintNonce++
        }
    }
    BackHandler(onBack = requestExitConfirmation)
    val preferHighThroughputTransfers = shouldPreferHighThroughputTransfers(
        activeWorkspaceRoute
    )
    DisposableEffect(preferHighThroughputTransfers) {
        transferViewModel.setPreferHighThroughputTransfers(preferHighThroughputTransfers)
        onDispose {
            if (preferHighThroughputTransfers) {
                transferViewModel.setPreferHighThroughputTransfers(false)
            }
        }
    }

    val cameraState by remember(cameraViewModel) {
        cameraViewModel.state
            .map(CameraState::toMainCameraUiState)
            .distinctUntilChanged()
    }.collectAsState(
        initial = cameraViewModel.state.value.toMainCameraUiState()
    )
    val transferState by remember(transferViewModel) {
        transferViewModel.state
            .map(TransferState::toMainTransferUiState)
            .distinctUntilChanged()
    }.collectAsState(
        initial = transferViewModel.state.value.toMainTransferUiState()
    )
    // 两页共用的顶部队列控件及其入队反馈。状态放在 NavHost 外，切换照片页/传输页时
    // 胶囊保持同一实例；文件页的飞行动画继续用根坐标落点和押扣计数。
    var queueTargetBounds by remember { mutableStateOf<Rect?>(null) }
    var queueHeldCount by remember { mutableIntStateOf(0) }
    var queueCatchNonce by remember { mutableLongStateOf(0L) }
    var filePreviewVisible by remember { mutableStateOf(false) }
    var queueControlActionNonce by remember { mutableLongStateOf(0L) }
    val autoQueueFlightRequests = remember { mutableStateListOf<AutoQueueFlightRequest>() }
    // 照片页不可见期间只在可变 Map 中 O(1) 累积；恢复可见时才一次性生成动画快照。
    // 不能每来一批都复制此前的 List，监看页长时间间隔拍摄会退化成 O(n²)。
    val pendingAutoQueueFiles = remember {
        LinkedHashMap<NikonCamera, LinkedHashMap<Int, NikonCamera.FileInfo>>()
    }
    var nextAutoQueueFlightId by remember { mutableLongStateOf(0L) }
    var filesWorkspaceSettled by remember { mutableStateOf(false) }
    val autoQueueFlightSurfaceReady = currentRoute == Screen.Files.route &&
        currentDestinationResumed && filesWorkspaceSettled &&
        !queuePageVisible && !filePreviewVisible
    val latestAutoQueueFlightSurfaceReady by rememberUpdatedState(
        autoQueueFlightSurfaceReady
    )

    fun publishAutoQueueFlight(
        camera: NikonCamera,
        files: List<NikonCamera.FileInfo>,
    ) {
        if (files.isEmpty()) return
        autoQueueFlightRequests += AutoQueueFlightRequest(
            id = nextAutoQueueFlightId++,
            camera = camera,
            files = files,
        )
    }

    // 页面被预览/队列遮住时，把尚未起飞的快照也收回 Map；这样临界两帧内刚发布的
    // 请求会和遮挡期间的新照片继续合并，回来仍然只飞一摞。
    // 返回照片页或关闭预览后只快照一次；同一批文件随后由 FileListScreen 精确消费。
    LaunchedEffect(autoQueueFlightSurfaceReady) {
        if (!autoQueueFlightSurfaceReady) {
            autoQueueFlightRequests.forEach { request ->
                val pending = pendingAutoQueueFiles.getOrPut(
                    request.camera,
                    ::LinkedHashMap,
                )
                request.files.forEach { pending[it.handle] = it }
            }
            autoQueueFlightRequests.clear()
            return@LaunchedEffect
        }
        if (pendingAutoQueueFiles.isNotEmpty()) {
            val batches = pendingAutoQueueFiles.map { (camera, files) ->
                camera to files.values.toList()
            }
            pendingAutoQueueFiles.clear()
            batches.forEach { (camera, files) -> publishAutoQueueFlight(camera, files) }
        }
    }

    // 只把真实运行中的队列喂给相机 VM。待传模式下的 WAITING 只是静止清单，不能让
    // 相机缩略图/大图通道误以为传输繁忙，否则“先选完再开始”的价值会被抵消。
    // 桥接放在 MainScreen（所有页面共同的宿主）：填充与页面无关，停在队列页也照常推进。
    val transfersBusy = transferState.isTransferring
    LaunchedEffect(transfersBusy) {
        cameraViewModel.setTransfersBusy(transfersBusy)
    }

    // 日期筛选同时是后台缩略图的优先范围；放在共同宿主桥接，离开文件页后仍能继续填充。
    LaunchedEffect(transferState.filterDateRange) {
        cameraViewModel.setThumbnailPriorityRange(transferState.filterDateRange)
    }

    // 相机新增事件由共同宿主承接，与当前停留页面无关；只有真正被自动入口接纳的文件
    // 才生成视觉事件。短时间连续到达会合成一摞；照片页不可见时继续合并，回来只播一次，
    // 不让监看连拍在返回后逐张刷动画。
    LaunchedEffect(cameraViewModel, transferViewModel) {
        val stagedFiles = LinkedHashMap<NikonCamera, LinkedHashMap<Int, NikonCamera.FileInfo>>()
        var flushJob: Job? = null
        cameraViewModel.newMediaFiles.collect { event ->
            if (cameraViewModel.getCamera() === event.camera) {
                val accepted = transferViewModel.addNewMediaToQueue(
                    event.files,
                    cameraViewModel::getCamera,
                )
                if (accepted.isNotEmpty()) {
                    val cameraFiles = stagedFiles.getOrPut(event.camera, ::LinkedHashMap)
                    accepted.forEach { cameraFiles[it.handle] = it }
                    flushJob?.cancel()
                    flushJob = launch {
                        delay(AUTO_QUEUE_FLIGHT_COALESCE_MS)
                        val batches = stagedFiles.map { (camera, files) ->
                            camera to files.values.toList()
                        }
                        stagedFiles.clear()
                        if (batches.isEmpty()) return@launch

                        batches.forEach { (camera, batch) ->
                            if (latestAutoQueueFlightSurfaceReady) {
                                publishAutoQueueFlight(camera, batch)
                            } else {
                                val pending = pendingAutoQueueFiles.getOrPut(
                                    camera,
                                    ::LinkedHashMap,
                                )
                                batch.forEach { pending[it.handle] = it }
                            }
                        }
                    }
                }
            }
        }
    }

    // 屏幕常亮（设置项，默认开）：FLAG_KEEP_SCREEN_ON 只在本应用窗口前台可见时生效，
    // 切到后台/其它应用自动失效，不会全局锁屏幕。
    val view = LocalView.current
    DisposableEffect(transferState.keepScreenOn) {
        val window = (view.context as? Activity)?.window
        val flag = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        if (transferState.keepScreenOn) window?.addFlags(flag) else window?.clearFlags(flag)
        onDispose { window?.clearFlags(flag) }
    }

    // 页面底色：浅色用纯色防止截图出现水平色带，深色保留纵向微渐变；
    // 各页共用这一处。恒黑页（遥控/预览）自绘黑底不受影响。
    val backgroundBrush = rememberAppBackgroundBrush()
    Box(Modifier.fillMaxSize()) {
        Scaffold(
            containerColor = Color.Transparent,
            modifier = Modifier.background(backgroundBrush),
            // 不消费系统栏 inset，交由各屏自行处理（文件列表 edge-to-edge，其余用 systemBarsPadding）
            contentWindowInsets = WindowInsets(0, 0, 0, 0)
        ) { paddingValues ->
            NavHost(
                navController = navController,
                startDestination = Screen.Home.route,
                modifier = Modifier.padding(paddingValues),
                // 活泼转场：进入的页面缩放+淡入，退出的页面淡出；返回时反向。
                enterTransition = { scaleIn(initialScale = 0.90f, animationSpec = tween(Motion.NAV_ENTER_MS)) + fadeIn(tween(Motion.NAV_ENTER_MS)) },
                exitTransition = { fadeOut(tween(Motion.NAV_EXIT_MS)) },
                popEnterTransition = { fadeIn(tween(Motion.NAV_EXIT_MS)) },
                popExitTransition = { scaleOut(targetScale = 0.90f, animationSpec = tween(Motion.NAV_EXIT_MS)) + fadeOut(tween(Motion.NAV_EXIT_MS)) }
            ) {
                composable(Screen.Home.route) {
                    HomeWorkspacePager(
                        cameraViewModel = cameraViewModel,
                        transferViewModel = transferViewModel,
                        onConnectionCelebrationFinished = {
                            // 由成功动画自身通知结束，避免系统动画倍率改变后固定 delay
                            // 提前切页。断线或已经离开连接页时丢弃迟到回调。
                            if (cameraState.isConnectedToCamera &&
                                navController.currentDestination?.route == Screen.Home.route
                            ) {
                                // USB、Wi-Fi AP、Wi-Fi STA 最终都进入同一个照片列表工作区。
                                // Home 保留在栈中用于状态恢复，但照片列表页必须拦截系统返回，
                                // 不能让 NavHost 把用户带回连接页（见 FileListScreen）。
                                navController.navigate(Screen.Files.route) {
                                    popUpTo(Screen.Home.route) { saveState = true }
                                    launchSingleTop = true
                                    restoreState = true
                                }
                            }
                        },
                    )
                }
                composable(
                    Screen.Files.route,
                    // 空间隐喻：队列页位于本页右侧，遥控页位于本页左侧。去队列页时本页作为
                    // 底层向左 1/3 视差退场并轻微压暗（营造被上层卡片盖住的纵深），返回时反向
                    // 浮现回来；去遥控页方向相反（向右 1/3）。
                    // enter/popEnter（自连接页）不设，仍走 NavHost 默认的缩放淡入转场。
                    exitTransition = {
                        val toRemote = targetState.destination.route == Screen.Remote.route
                        slideOutHorizontally(Motion.pageSlide) { if (toRemote) it / 3 else -it / 3 } +
                                fadeOut(tween(Motion.PAGE_FADE_MS), targetAlpha = 0.5f)
                    },
                    popEnterTransition = {
                        val fromRemote = initialState.destination.route == Screen.Remote.route
                        slideInHorizontally(Motion.pageSlide) { if (fromRemote) it / 3 else -it / 3 } +
                                fadeIn(tween(Motion.PAGE_FADE_MS), initialAlpha = 0.5f)
                    }
                ) {
                    FilesQueueWorkspace(
                        queueVisible = queuePageVisible,
                        onFilesSettledChanged = { filesWorkspaceSettled = it },
                        filesContent = {
                            FileListScreen(
                                cameraViewModel = cameraViewModel,
                                transferViewModel = transferViewModel,
                                queueTargetBounds = queueTargetBounds,
                                onQueueFlightStarted = { count ->
                                    queueHeldCount += count
                                },
                                onQueueFlightFinished = { count ->
                                    queueHeldCount = (queueHeldCount - count).coerceAtLeast(0)
                                    queueCatchNonce++
                                },
                                onQueueFlightsCancelled = { count ->
                                    queueHeldCount = (queueHeldCount - count).coerceAtLeast(0)
                                },
                                onQueueFlightCaught = { queueCatchNonce++ },
                                autoQueueFlightRequest = autoQueueFlightRequests.firstOrNull()
                                    .takeIf { autoQueueFlightSurfaceReady },
                                onAutoQueueFlightConsumed = { requestId ->
                                    val index = autoQueueFlightRequests.indexOfFirst {
                                        it.id == requestId
                                    }
                                    if (index >= 0) autoQueueFlightRequests.removeAt(index)
                                },
                                onPreviewVisibilityChanged = { filePreviewVisible = it },
                                backHandlerEnabled = !queuePageVisible,
                                onRequestExitConfirmation = requestExitConfirmation,
                                onNavigateToRemote = {
                                    navController.navigate(Screen.Remote.route) {
                                        launchSingleTop = true
                                    }
                                },
                            )
                        },
                        queueContent = {
                            TransferScreen(
                                transferViewModel = transferViewModel,
                                cameraViewModel = cameraViewModel,
                                queueControlActionNonce = queueControlActionNonce,
                                backHandlerEnabled = queuePageVisible,
                                onNavigateBack = { queuePageVisible = false },
                            )
                        },
                        queueTopContent = {
                            TransferTopControls(
                                cameraViewModel = cameraViewModel,
                                onNavigateBack = { queuePageVisible = false },
                            )
                        },
                    )
                }
                composable(
                    Screen.Remote.route,
                    // 遥控页作为上层卡片从左侧滑入，返回时向左滑出。
                    enterTransition = { slideInHorizontally(Motion.pageSlide) { -it } },
                    popExitTransition = { slideOutHorizontally(Motion.pageSlide) { -it } }
                ) {
                    RemoteScreen(
                        cameraViewModel = cameraViewModel,
                        transferViewModel = transferViewModel,
                        onNavigateBack = { navController.popBackStack() }
                    )
                }
            }
        }
        if (currentRoute == Screen.Files.route) {
            SharedQueueControls(
                route = activeWorkspaceRoute ?: Screen.Files.route,
                transferViewModel = transferViewModel,
                cameraViewModel = cameraViewModel,
                heldCount = queueHeldCount,
                catchNonce = queueCatchNonce,
                filePreviewVisible = filePreviewVisible,
                onBoundsChanged = { queueTargetBounds = it },
                onNavigateToTransfer = {
                    queuePageVisible = true
                },
                onControlAction = { queueControlActionNonce++ },
            )
        }
        AnimatedVisibility(
            visible = backExitHintVisible,
            enter = fadeIn() + slideInVertically { it / 2 },
            exit = fadeOut() + slideOutVertically { it / 2 },
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = exitHintBottomPadding),
        ) {
            BottomGlassHint(
                text = backExitHint,
                verticalPadding = 14.dp,
            )
        }
        AnimatedVisibility(
            visible = !backExitHintVisible && staReconnectHintVisible,
            enter = fadeIn() + slideInVertically { it / 2 },
            exit = fadeOut() + slideOutVertically { it / 2 },
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 28.dp),
        ) {
            BottomGlassHint(text = stringResource(R.string.sta_reconnect_attempting))
        }
        AppUpdateHost(
            cameraUsesWifi = cameraState.connectionType == CameraConnectionType.WIFI &&
                cameraState.wirelessMode == WirelessMode.AP
        )
    }
}

private const val AUTO_QUEUE_FLIGHT_COALESCE_MS = 220L
