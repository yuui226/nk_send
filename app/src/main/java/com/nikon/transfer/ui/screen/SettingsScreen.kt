package com.nikon.transfer.ui.screen

import android.provider.DocumentsContract
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.nikon.transfer.ui.theme.*
import com.nikon.transfer.viewmodel.TransferViewModel

/**
 * 轻量设置面板（全屏覆盖层，非系统 Dialog）：
 * 面板以触发按钮（[anchorCenter]，在同一 Compose 根坐标系）为缩放原点，缩放+淡入"从按钮变形展开"，
 * 关闭时反向收回到按钮再消失。放在与按钮同一 composition 内，避免跨窗口坐标不一致。
 */
@Composable
fun SettingsOverlay(
    viewModel: TransferViewModel,
    anchorCenter: Offset?,
    onDismiss: () -> Unit
) {
    val state by viewModel.state.collectAsState()

    val directoryPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocumentTree()
    ) { uri ->
        // 持久化授权在 setTransferDirUri 内统一处理，这里不重复申请。
        uri?.let { viewModel.setTransferDirUri(it) }
    }

    val dirText: String? = state.transferDirUri?.let { dir ->
        try {
            val uri = android.net.Uri.parse(dir)
            val docId = DocumentsContract.getTreeDocumentId(uri)
            if (docId.startsWith("primary:")) "/sdcard/${docId.removePrefix("primary:")}" else docId
        } catch (e: Exception) {
            "已设置"
        }
    }

    // 变形动画进度：0=收在按钮处（不可见），1=完全展开。
    var panelBounds by remember { mutableStateOf<Rect?>(null) }
    val progress = remember { Animatable(0f) }
    var closing by remember { mutableStateOf(false) }

    // 面板测量完成即入场展开。
    LaunchedEffect(panelBounds, closing) {
        if (!closing && panelBounds != null && progress.value < 1f) {
            progress.animateTo(1f, tween(360, easing = FastOutSlowInEasing))
        }
    }
    // 关闭：反向收回后再真正移除。
    LaunchedEffect(closing) {
        if (closing) {
            progress.animateTo(0f, tween(280, easing = FastOutSlowInEasing))
            onDismiss()
        }
    }
    val startClose: () -> Unit = { closing = true }

    BackHandler(enabled = !closing) { startClose() }

    Box(modifier = Modifier.fillMaxSize()) {
        // 遮罩：随进度淡入；点击外部关闭。
        Box(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer { alpha = progress.value }
                .background(Color.Black.copy(alpha = 0.4f))
                .pointerInput(Unit) { detectTapGestures { startClose() } }
        )

        // 面板：以按钮位置为原点缩放展开。
        Surface(
            modifier = Modifier
                .align(Alignment.Center)
                .padding(24.dp)
                .fillMaxWidth()
                .onGloballyPositioned { panelBounds = it.boundsInRoot() }
                .graphicsLayer {
                    val b = panelBounds
                    if (b != null && b.width > 0f && b.height > 0f && anchorCenter != null) {
                        // 按钮中心相对于面板自身的比例位置（可超出 0..1，即原点落在面板外）。
                        transformOrigin = TransformOrigin(
                            (anchorCenter.x - b.left) / b.width,
                            (anchorCenter.y - b.top) / b.height
                        )
                    }
                    val p = progress.value
                    // 从"约按钮大小"(6%)在按钮位置放大到全尺寸——明显地"从 Z传 按钮长出来"，
                    // 关闭时反向缩回按钮再消失（从哪来回哪去）。
                    val s = 0.06f + 0.94f * p
                    scaleX = s
                    scaleY = s
                    // 透明度更快到达不透明，放大过程中面板已清晰可见。
                    alpha = (p * 2f).coerceAtMost(1f)
                }
                // 消费面板内点击，避免穿透到遮罩误关闭。
                .pointerInput(Unit) { detectTapGestures { } },
            shape = RoundedCornerShape(20.dp),
            // 毛玻璃：底色保持较高不透明度（不那么透明，保证可读）+ 浅色描边。
            color = DarkSurface.copy(alpha = 0.92f),
            border = BorderStroke(1.dp, Color.White.copy(alpha = 0.15f)),
            tonalElevation = 6.dp
        ) {
          Box {
            // 自上而下淡出的白色高光叠层，营造毛玻璃质感。
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .background(
                        Brush.verticalGradient(
                            listOf(Color.White.copy(alpha = 0.08f), Color.Transparent)
                        )
                    )
            )
            Column(
                modifier = Modifier
                    .verticalScroll(rememberScrollState())
                    .padding(20.dp)
            ) {
                // 标题栏
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        "设置",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = DarkOnBackground
                    )
                    Spacer(Modifier.weight(1f))
                    IconButton(onClick = startClose, modifier = Modifier.size(32.dp)) {
                        Icon(Icons.Default.Close, contentDescription = "关闭", tint = DarkOnSurfaceVariant)
                    }
                }

                Spacer(Modifier.height(16.dp))

                // ---------- 传输目录 ----------
                SectionLabel("传输目录")
                Spacer(Modifier.height(8.dp))
                Surface(
                    shape = RoundedCornerShape(10.dp),
                    color = DarkSurfaceVariant,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier.padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            Icons.Default.LocationOn,
                            contentDescription = null,
                            tint = if (dirText != null) StatusConnected else DarkOnSurfaceVariant,
                            modifier = Modifier.size(16.dp)
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            text = dirText ?: "未设置",
                            style = MaterialTheme.typography.bodyMedium,
                            color = if (dirText != null) DarkOnBackground else DarkOnSurfaceVariant,
                            modifier = Modifier.weight(1f)
                        )
                    }
                }
                Spacer(Modifier.height(10.dp))
                Button(
                    onClick = { directoryPicker.launch(null) },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = AccentBlue),
                    shape = RoundedCornerShape(12.dp)
                ) {
                    Icon(Icons.Default.Edit, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(if (dirText != null) "更改目录" else "选择目录")
                }

                Spacer(Modifier.height(20.dp))

                // ---------- 每行列数 ----------
                SectionLabel("列数")
                Spacer(Modifier.height(8.dp))
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

                Spacer(Modifier.height(20.dp))

                // ---------- 关于（精简页脚）----------
                Text(
                    text = "Z传 v1.0 · 通过 PTP/IP 直连相机传输",
                    style = MaterialTheme.typography.bodySmall,
                    color = DarkOnSurfaceVariant.copy(alpha = 0.7f)
                )
            }
          }
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        fontWeight = FontWeight.SemiBold,
        color = DarkOnBackground
    )
}
