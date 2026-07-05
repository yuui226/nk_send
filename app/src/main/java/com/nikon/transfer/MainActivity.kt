package com.nikon.transfer

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
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
import com.nikon.transfer.ui.theme.DarkSurface
import com.nikon.transfer.ui.theme.NikonTransferTheme
import com.nikon.transfer.viewmodel.CameraViewModel
import com.nikon.transfer.viewmodel.TransferViewModel

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            NikonTransferTheme {
                MainScreen()
            }
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
    LaunchedEffect(Unit) { transferViewModel.cameraViewModel = cameraViewModel }

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

    val bottomBarScreens = listOf(Screen.Home, Screen.Files, Screen.Settings)
    val showBottomBar = currentRoute in bottomBarScreens.map { it.route }

    Scaffold(
        containerColor = DarkBackground,
        bottomBar = {
            if (showBottomBar) {
                NavigationBar(containerColor = DarkSurface) {
                    bottomBarScreens.forEach { screen ->
                        NavigationBarItem(
                            icon = { Icon(screen.icon, contentDescription = screen.title) },
                            label = { Text(screen.title) },
                            selected = currentRoute == screen.route,
                            onClick = {
                                if (currentRoute != screen.route) {
                                    navController.navigate(screen.route) {
                                        popUpTo(Screen.Home.route) { saveState = true }
                                        launchSingleTop = true
                                        restoreState = true
                                    }
                                }
                            }
                        )
                    }
                }
            }
        }
    ) { paddingValues ->
        NavHost(
            navController = navController,
            startDestination = Screen.Home.route,
            modifier = Modifier.padding(paddingValues)
        ) {
            composable(Screen.Home.route) {
                HomeScreen(viewModel = cameraViewModel)
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
            composable(Screen.Settings.route) {
                SettingsScreen(viewModel = transferViewModel)
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
