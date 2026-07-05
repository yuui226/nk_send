package com.nikon.transfer.ui.screen

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.nikon.transfer.ui.theme.*
import com.nikon.transfer.viewmodel.CameraViewModel

@Composable
fun HomeScreen(viewModel: CameraViewModel) {
    val state by viewModel.state.collectAsState()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(
            imageVector = Icons.Default.CameraAlt,
            contentDescription = null,
            modifier = Modifier.size(80.dp),
            tint = AccentBlue
        )

        Spacer(modifier = Modifier.height(16.dp))

        Text(
            text = "Nikon Z30",
            style = MaterialTheme.typography.headlineLarge,
            color = DarkOnBackground
        )

        Spacer(modifier = Modifier.height(8.dp))

        Text(
            text = "文件传输工具",
            style = MaterialTheme.typography.bodyLarge,
            color = DarkOnSurfaceVariant
        )

        Spacer(modifier = Modifier.height(48.dp))

        // WiFi 状态
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(
                containerColor = if (state.isConnectedToCamera) StatusConnected.copy(alpha = 0.15f)
                else if (state.isWifiConnected) AccentBlue.copy(alpha = 0.1f)
                else DarkSurfaceVariant
            )
        ) {
            Column(
                modifier = Modifier.padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Icon(
                    imageVector = when {
                        state.isConnectedToCamera -> Icons.Default.CheckCircle
                        state.isWifiConnected -> Icons.Default.Wifi
                        else -> Icons.Default.WifiOff
                    },
                    contentDescription = null,
                    modifier = Modifier.size(32.dp),
                    tint = when {
                        state.isConnectedToCamera -> StatusConnected
                        state.isWifiConnected -> AccentBlue
                        else -> AccentOrange
                    }
                )

                Spacer(modifier = Modifier.height(12.dp))

                Text(
                    text = when {
                        state.isConnectedToCamera -> "已连接: ${state.cameraName}"
                        state.isWifiConnected && state.isConnecting -> "正在连接相机..."
                        state.isWifiConnected -> "WiFi 已连接"
                        else -> "未连接到相机 WiFi"
                    },
                    style = MaterialTheme.typography.titleMedium,
                    color = when {
                        state.isConnectedToCamera -> StatusConnected
                        state.isWifiConnected -> AccentBlue
                        else -> AccentOrange
                    }
                )

                if (state.isConnecting) {
                    Spacer(modifier = Modifier.height(12.dp))
                    CircularProgressIndicator(
                        modifier = Modifier.size(24.dp),
                        color = AccentBlue,
                        strokeWidth = 2.dp
                    )
                }
            }
        }

        // 错误信息
        if (state.error != null) {
            Spacer(modifier = Modifier.height(16.dp))
            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                colors = CardDefaults.cardColors(containerColor = StatusError.copy(alpha = 0.15f))
            ) {
                Row(
                    modifier = Modifier.padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(Icons.Default.Error, contentDescription = null, tint = StatusError)
                    Spacer(modifier = Modifier.width(12.dp))
                    Text(
                        text = state.error ?: "",
                        color = StatusError,
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
            }
        }

        if (state.isConnectedToCamera) {
            Spacer(modifier = Modifier.height(24.dp))
            Text(
                text = "正在加载文件...",
                style = MaterialTheme.typography.bodyMedium,
                color = StatusConnected
            )
        }
    }
}
