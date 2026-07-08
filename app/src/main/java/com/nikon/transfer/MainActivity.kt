package com.nikon.transfer

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
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
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.nikon.transfer.ui.screen.*
import com.nikon.transfer.ui.theme.DarkBackground
import com.nikon.transfer.ui.theme.NikonTransferTheme
import com.nikon.transfer.viewmodel.CameraViewModel
import com.nikon.transfer.viewmodel.TransferViewModel
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    private val notificationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* 结果不阻断使用 */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()   // 内容延伸到系统栏后面，各屏自行处理 inset
        requestNotificationPermissionIfNeeded()
        setContent {
            NikonTransferTheme {
                MainScreen()
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
}

@Composable
fun MainScreen() {
    val navController = rememberNavController()
    val cameraViewModel: CameraViewModel = viewModel()
    val transferViewModel: TransferViewModel = viewModel()

    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = navBackStackEntry?.destination?.route
    val cameraState by cameraViewModel.state.collectAsState()

    // 相机连接成功后：在首页时先留时间给连接页播放"成功脉冲收尾"动画，再跳转到文件列表
    // （跳转本身带活泼的缩放淡入转场）。
    LaunchedEffect(cameraState.isConnectedToCamera) {
        if (cameraState.isConnectedToCamera && currentRoute == Screen.Home.route) {
            delay(850)
            navController.navigate(Screen.Files.route) {
                popUpTo(Screen.Home.route) { saveState = true }
                launchSingleTop = true
                restoreState = true
            }
        }
    }

    Scaffold(
        containerColor = DarkBackground,
        // 不消费系统栏 inset，交由各屏自行处理（文件列表 edge-to-edge，其余用 systemBarsPadding）
        contentWindowInsets = WindowInsets(0, 0, 0, 0)
    ) { paddingValues ->
        NavHost(
            navController = navController,
            startDestination = Screen.Home.route,
            modifier = Modifier.padding(paddingValues),
            // 活泼转场：进入的页面缩放+淡入，退出的页面淡出；返回时反向。
            enterTransition = { scaleIn(initialScale = 0.90f, animationSpec = tween(420)) + fadeIn(tween(420)) },
            exitTransition = { fadeOut(tween(280)) },
            popEnterTransition = { fadeIn(tween(280)) },
            popExitTransition = { scaleOut(targetScale = 0.90f, animationSpec = tween(280)) + fadeOut(tween(280)) }
        ) {
            composable(Screen.Home.route) {
                HomeScreen(
                    viewModel = cameraViewModel,
                    transferViewModel = transferViewModel
                )
            }
            composable(Screen.Files.route) {
                FileListScreen(
                    cameraViewModel = cameraViewModel,
                    transferViewModel = transferViewModel,
                    onNavigateToTransfer = {
                        navController.navigate(Screen.Transfer.route)
                    }
                )
            }
            composable(Screen.Transfer.route) {
                TransferScreen(
                    transferViewModel = transferViewModel,
                    cameraViewModel = cameraViewModel,
                    onNavigateBack = { navController.popBackStack() }
                )
            }
        }
    }
}
