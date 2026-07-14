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
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import com.ztransfer.ui.theme.Motion
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.ztransfer.ui.screen.*
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.ZTransferTheme
import com.ztransfer.ui.theme.rememberAppBackgroundBrush
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
        // 恢复授权状态（本地验签，毫秒级）并在后台触发静默续签（≥7 天且有网时）。
        com.ztransfer.license.LicenseManager.init(applicationContext)
        enableEdgeToEdge()   // 内容延伸到系统栏后面，各屏自行处理 inset
        requestNotificationPermissionIfNeeded()
        setContent {
            // 主题模式存在 TransferViewModel（与其它设置同处持久化），
            // 在主题之上先取出来，切换即全局重排配色。
            val transferViewModel: TransferViewModel = viewModel()
            val transferState by transferViewModel.state.collectAsState()
            ZTransferTheme(themeMode = transferState.themeMode) {
                MainScreen(transferViewModel)
            }
        }
    }

    /** Android 13+ 需运行时授权才能展示前台传输通知；拒绝不影响服务运行，仅隐藏通知。 */
    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
}

sealed class Screen(val route: String) {
    object Home : Screen("home")
    object Files : Screen("files")
    object Transfer : Screen("transfer")
    object Remote : Screen("remote")   // 无线遥控页，位于文件页左侧
}

@Composable
fun MainScreen(transferViewModel: TransferViewModel) {
    val navController = rememberNavController()
    val cameraViewModel: CameraViewModel = viewModel()

    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = navBackStackEntry?.destination?.route
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

    // 屏幕常亮（设置项，默认开）：FLAG_KEEP_SCREEN_ON 只在本应用窗口前台可见时生效，
    // 切到后台/其它应用自动失效，不会全局锁屏幕。
    val view = LocalView.current
    DisposableEffect(transferState.keepScreenOn) {
        val window = (view.context as? Activity)?.window
        val flag = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        if (transferState.keepScreenOn) window?.addFlags(flag) else window?.clearFlags(flag)
        onDispose { window?.clearFlags(flag) }
    }

    // 相机连接成功后：连接页先保持"连接中"脉冲一小会（列表与缩略图此间已在全速加载），
    // 再播成功爆发收尾，播完直接进照片列表——绿色对号 = 马上进入。
    // 时长与 HomeScreen 的庆祝延迟严格对齐（同一对常量）。
    LaunchedEffect(cameraState.isConnectedToCamera) {
        if (cameraState.isConnectedToCamera && currentRoute == Screen.Home.route) {
            delay(CONNECT_CELEBRATE_DELAY_MS + CONNECT_SUCCESS_ANIM_MS)
            navController.navigate(Screen.Files.route) {
                popUpTo(Screen.Home.route) { saveState = true }
                launchSingleTop = true
                restoreState = true
            }
        }
    }

    // 页面底色：纵向微渐变（顶部略亮→底部略暗）替代纯平色，各页共用这一处，
    // 换一处全局生效。恒黑页（遥控/预览）自绘黑底不受影响。
    val backgroundBrush = rememberAppBackgroundBrush()
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
                HomeScreen(
                    viewModel = cameraViewModel,
                    transferViewModel = transferViewModel
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
}
