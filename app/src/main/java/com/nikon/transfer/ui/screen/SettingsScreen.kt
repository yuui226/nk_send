package com.nikon.transfer.ui.screen

import android.content.Intent
import android.provider.DocumentsContract
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.nikon.transfer.ui.theme.*
import com.nikon.transfer.viewmodel.TransferViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    viewModel: TransferViewModel,
    onNavigateBack: () -> Unit
) {
    val state by viewModel.state.collectAsState()
    val context = LocalContext.current

    val directoryPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocumentTree()
    ) { uri ->
        uri?.let {
            // 持久化权限
            context.contentResolver.takePersistableUriPermission(
                it,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
            viewModel.setTransferDirUri(it)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .systemBarsPadding()
    ) {
        TopAppBar(
            title = {
                Text("设置", fontWeight = FontWeight.Bold)
            },
            navigationIcon = {
                IconButton(onClick = onNavigateBack) {
                    Icon(
                        imageVector = Icons.Default.ArrowBack,
                        contentDescription = "返回",
                        tint = DarkOnBackground
                    )
                }
            },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = DarkBackground)
        )

        // 传输目录设置
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = DarkSurface)
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Default.Folder,
                        contentDescription = null,
                        tint = AccentBlue,
                        modifier = Modifier.size(24.dp)
                    )
                    Spacer(modifier = Modifier.width(12.dp))
                    Text(
                        text = "传输目录",
                        style = MaterialTheme.typography.titleMedium,
                        color = DarkOnBackground
                    )
                }

                Spacer(modifier = Modifier.height(12.dp))

                // 当前目录
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(8.dp),
                    colors = CardDefaults.cardColors(containerColor = DarkSurfaceVariant)
                ) {
                    Row(
                        modifier = Modifier
                            .padding(12.dp)
                            .fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            Icons.Default.LocationOn,
                            contentDescription = null,
                            tint = if (state.transferDirUri != null) StatusConnected else DarkOnSurfaceVariant,
                            modifier = Modifier.size(16.dp)
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(
                            text = state.transferDirUri?.let { dir ->
                                // 尝试显示可读路径
                                try {
                                    val uri = android.net.Uri.parse(dir)
                                    val docId = DocumentsContract.getTreeDocumentId(uri)
                                    if (docId.startsWith("primary:")) {
                                        "/sdcard/${docId.removePrefix("primary:")}"
                                    } else {
                                        docId
                                    }
                                } catch (e: Exception) {
                                    "已设置"
                                }
                            } ?: "未设置",
                            style = MaterialTheme.typography.bodyMedium,
                            color = if (state.transferDirUri != null) DarkOnBackground else DarkOnSurfaceVariant,
                            modifier = Modifier.weight(1f)
                        )
                    }
                }

                Spacer(modifier = Modifier.height(12.dp))

                // 选择按钮
                Button(
                    onClick = { directoryPicker.launch(null) },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = AccentBlue),
                    shape = RoundedCornerShape(12.dp)
                ) {
                    Icon(Icons.Default.Edit, contentDescription = null)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(if (state.transferDirUri != null) "更改目录" else "选择目录")
                }
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        // 缩略图设置
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = DarkSurface)
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Default.GridView,
                        contentDescription = null,
                        tint = AccentBlue,
                        modifier = Modifier.size(24.dp)
                    )
                    Spacer(modifier = Modifier.width(12.dp))
                    Text(
                        text = "缩略图模式",
                        style = MaterialTheme.typography.titleMedium,
                        color = DarkOnBackground,
                        modifier = Modifier.weight(1f)
                    )
                    Switch(
                        checked = state.thumbnailMode,
                        onCheckedChange = { viewModel.setThumbnailMode(it) }
                    )
                }

                Text(
                    text = "以网格缩略图展示照片（分组方式不变，仅展示形态不同）",
                    style = MaterialTheme.typography.bodySmall,
                    color = DarkOnSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp)
                )

                // 列数选择（仅缩略图模式下可用）
                if (state.thumbnailMode) {
                    Spacer(modifier = Modifier.height(16.dp))
                    Text(
                        text = "每行列数",
                        style = MaterialTheme.typography.bodyMedium,
                        color = DarkOnBackground
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        (1..4).forEach { col ->
                            val selected = state.thumbnailColumns == col
                            Surface(
                                onClick = { viewModel.setThumbnailColumns(col) },
                                shape = RoundedCornerShape(8.dp),
                                color = if (selected) AccentBlue else DarkSurfaceVariant,
                                modifier = Modifier
                                    .weight(1f)
                                    .height(40.dp)
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Text(
                                        text = "$col",
                                        style = MaterialTheme.typography.titleMedium,
                                        fontWeight = FontWeight.Bold,
                                        color = if (selected) DarkBackground else DarkOnSurfaceVariant
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        // 关于信息
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = DarkSurface)
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Default.Info,
                        contentDescription = null,
                        tint = DarkOnSurfaceVariant,
                        modifier = Modifier.size(24.dp)
                    )
                    Spacer(modifier = Modifier.width(12.dp))
                    Text(
                        text = "关于",
                        style = MaterialTheme.typography.titleMedium,
                        color = DarkOnBackground
                    )
                }

                Spacer(modifier = Modifier.height(12.dp))

                Text(
                    text = "Z传 v1.0",
                    style = MaterialTheme.typography.bodyMedium,
                    color = DarkOnSurfaceVariant
                )

                Spacer(modifier = Modifier.height(4.dp))

                Text(
                    text = "通过 PTP/IP 协议直接从相机传输文件",
                    style = MaterialTheme.typography.bodySmall,
                    color = DarkOnSurfaceVariant
                )
            }
        }
    }
}
