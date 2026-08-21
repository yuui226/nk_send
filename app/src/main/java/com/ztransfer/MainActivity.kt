package com.ztransfer

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import com.ztransfer.ui.theme.Motion
import androidx.compose.foundation.background
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.ztransfer.ui.screen.*
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.ZTransferTheme
import com.ztransfer.ui.theme.rememberAppBackgroundBrush
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.protocol.CameraEndpointOverride
import com.ztransfer.update.AppUpdateHost
import com.ztransfer.update.AppUpdateManager
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    private val notificationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* 结果不阻断使用 */ }

    // 应用内语言：设置里切换后 recreate()，这里重新包装基座 Context 使其生效。
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
            ZTransferTheme(themeMode = transferState.themeMode, skinPreset = transferState.skinPreset) {
                Box(Modifier.fillMaxSize()) {
                    MainScreen(transferViewModel)
                    var hintVisible by remember { mutableStateOf(showFirstLaunchNotificationHint) }
                    LaunchedEffect(showFirstLaunchNotificationHint) {
                        if (!showFirstLaunchNotificationHint) return@LaunchedEffect
                        // 先让顶部气泡绘制一帧，再呼出系统权限框；两者同时可见且不重叠。
                        withFrameNanos { }
                        requestNotificationPermissionIfNeeded()
                        delay(FIRST_LAUNCH_HINT_DURATION_MS)
                        hintVisible = false
                    }
                    AnimatedVisibility(
                        visible = hintVisible,
                        enter = fadeIn(tween(200)) +
                            slideInVertically(tween(200)) { -it / 3 },
                        exit = fadeOut(tween(260)),
                        modifier = Modifier
                            .align(Alignment.TopCenter)
                            .statusBarsPadding()
                            .padding(horizontal = 24.dp)
                            .padding(top = 60.dp)
                    ) {
                        FirstLaunchNotificationHint()
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
        shadowElevation = 6.dp,
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

@Composable
fun MainScreen(transferViewModel: TransferViewModel) {
    val navController = rememberNavController()
    val cameraViewModel: CameraViewModel = viewModel()

    // 照片列表（含其上的大图预览）和传输页都优先保证无线传输吞吐。两页之间切换时
    // 布尔值保持 true，不会产生一次 false 的瞬态；每个文件进入协议层前再冻结策略，
    // 因此已经开始的文件也不会中途换道。
    val currentBackStackEntry by navController.currentBackStackEntryAsState()
    val preferHighThroughputTransfers = shouldPreferHighThroughputTransfers(
        currentBackStackEntry?.destination?.route
    )
    DisposableEffect(preferHighThroughputTransfers) {
        transferViewModel.setPreferHighThroughputTransfers(preferHighThroughputTransfers)
        onDispose {
            if (preferHighThroughputTransfers) {
                transferViewModel.setPreferHighThroughputTransfers(false)
            }
        }
    }

    val cameraState by cameraViewModel.state.collectAsState()
    val transferState by transferViewModel.state.collectAsState()

    // 把"是否有任务在传输/等待"喂给相机 VM——它是后台缩略图填充的唯一开关。
    // 桥接放在 MainScreen（所有页面共同的宿主）：填充与页面无关，停在队列页也照常推进。
    val transfersBusy = transferState.tasks.any {
        it.status == TransferStatus.WAITING || it.status == TransferStatus.TRANSFERING
    }
    LaunchedEffect(transfersBusy) {
        cameraViewModel.setTransfersBusy(transfersBusy)
    }

    // 日期筛选同时是后台缩略图的优先范围；放在共同宿主桥接，离开文件页后仍能继续填充。
    LaunchedEffect(transferState.filterDateRange) {
        cameraViewModel.setThumbnailPriorityRange(transferState.filterDateRange)
    }

    // 相机新增事件由共同宿主承接，与当前停留页面无关；开关关闭时传输 VM 静默忽略。
    LaunchedEffect(cameraViewModel, transferViewModel) {
        cameraViewModel.newMediaFiles.collect { event ->
            if (cameraViewModel.getCamera() === event.camera) {
                transferViewModel.addNewMediaToQueue(event.files, cameraViewModel::getCamera)
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

    // 页面底色：纵向微渐变（顶部略亮→底部略暗）替代纯平色，各页共用这一处，
    // 换一处全局生效。恒黑页（遥控/预览）自绘黑底不受影响。
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
                    FileListScreen(
                        cameraViewModel = cameraViewModel,
                        transferViewModel = transferViewModel,
                        onNavigateToTransfer = {
                            navController.navigate(Screen.Transfer.route)
                        },
                        onNavigateToRemote = {
                            navController.navigate(Screen.Remote.route) { launchSingleTop = true }
                        }
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
                composable(
                    Screen.Transfer.route,
                    // 队列页作为上层卡片：前进时整页从右滑入盖住"Z传"页，
                    // 返回（含系统返回键）时向右滑出、露出底层视差归位的"Z传"页。
                    enterTransition = { slideInHorizontally(Motion.pageSlide) { it } },
                    popExitTransition = { slideOutHorizontally(Motion.pageSlide) { it } }
                ) {
                    TransferScreen(
                        transferViewModel = transferViewModel,
                        cameraViewModel = cameraViewModel,
                        onNavigateBack = { navController.popBackStack() }
                    )
                }
            }
        }
        AppUpdateHost(
            cameraUsesWifi = cameraState.connectionType == CameraConnectionType.WIFI
        )
    }
}
