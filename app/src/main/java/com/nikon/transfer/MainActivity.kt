package com.nikon.transfer

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
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

class MainActivity : ComponentActivity() {
    private val notificationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* 结果不阻断使用 */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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

sealed class Screen(val route: String, val title: String, val icon: ImageVector) {
    object Home : Screen("home", "首页", Icons.Default.Home)
    object Files : Screen("files", "文件", Icons.Default.Folder)
    object Settings : Screen("settings", "设置", Icons.Default.Settings)
    object Transfer : Screen("transfer", "传输", Icons.Default.CloudDownload)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen() {
    val navController = rememberNavController()
    val cameraViewModel: CameraViewModel = viewModel()
    val transferViewModel: TransferViewModel = viewModel()

    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = navBackStackEntry?.destination?.route
    val cameraState by cameraViewModel.state.collectAsState()

    // 相机连接成功后自动跳转到文件列表
    LaunchedEffect(cameraState.isConnectedToCamera) {
        if (cameraState.isConnectedToCamera && currentRoute == Screen.Home.route) {
            navController.navigate(Screen.Files.route) {
                popUpTo(Screen.Home.route) { saveState = true }
                launchSingleTop = true
                restoreState = true
            }
        }
    }

    // 相机（重新）连接后，若队列有因掉线暂停的任务则自动续传
    LaunchedEffect(cameraState.isConnectedToCamera) {
        if (cameraState.isConnectedToCamera) {
            cameraViewModel.getCamera()?.let { transferViewModel.onCameraConnected(it) }
        }
    }

    Scaffold(
        containerColor = DarkBackground
    ) { paddingValues ->
        NavHost(
            navController = navController,
            startDestination = Screen.Home.route,
            modifier = Modifier.padding(paddingValues)
        ) {
            composable(Screen.Home.route) {
                HomeScreen(
                    viewModel = cameraViewModel,
                    onNavigateToSettings = {
                        navController.navigate(Screen.Settings.route)
                    }
                )
            }
            composable(Screen.Files.route) {
                FileListScreen(
                    cameraViewModel = cameraViewModel,
                    transferViewModel = transferViewModel,
                    onNavigateToTransfer = {
                        navController.navigate(Screen.Transfer.route)
                    },
                    onNavigateToSettings = {
                        navController.navigate(Screen.Settings.route)
                    }
                )
            }
            composable(Screen.Settings.route) {
                SettingsScreen(
                    viewModel = transferViewModel,
                    onNavigateBack = { navController.popBackStack() }
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
