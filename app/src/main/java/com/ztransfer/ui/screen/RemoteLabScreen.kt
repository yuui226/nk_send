package com.ztransfer.ui.screen

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Radar
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ztransfer.R
import com.ztransfer.protocol.labEndLiveView
import com.ztransfer.protocol.labGetObjectInfo
import com.ztransfer.protocol.labGrabFrame
import com.ztransfer.protocol.labStartLiveView
import com.ztransfer.protocol.runLabCapture
import com.ztransfer.protocol.runLabProbe
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.viewmodel.CameraViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 遥控实验页（临时，验证无线遥控可行性）：位于文件列表页左侧，右滑打开。
 * 三个动作：完整探测（只读+LV试帧，一次拿全能力清单）、连续监看、试拍一张。
 * 日志区可复制,方便把真机探测结果带出来分析。
 */
@Composable
fun RemoteLabScreen(
    cameraViewModel: CameraViewModel,
    onNavigateBack: () -> Unit
) {
    val colors = AppTheme.colors
    val state by cameraViewModel.state.collectAsState()
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current

    val logLines = remember { mutableStateListOf<String>() }
    var busy by remember { mutableStateOf(false) }
    var lvActive by remember { mutableStateOf(false) }
    var lvJob by remember { mutableStateOf<Job?>(null) }
    var frame by remember { mutableStateOf<ImageBitmap?>(null) }
    var fpsText by remember { mutableStateOf("") }
    val listState = rememberLazyListState()

    // 日志随增随滚到底
    LaunchedEffect(logLines.size) {
        if (logLines.isNotEmpty()) listState.scrollToItem(logLines.size - 1)
    }

    val log: suspend (String) -> Unit = { logLines.add(it) }
    suspend fun showJpeg(bytes: ByteArray) {
        val bmp = withContext(Dispatchers.Default) {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        }
        if (bmp != null) frame = bmp.asImageBitmap()
    }

    fun runProbe() {
        val cam = cameraViewModel.getCamera() ?: return
        scope.launch {
            busy = true
            try {
                cam.runLabProbe(log, ::showJpeg)
            } catch (e: Exception) {
                logLines.add("!! probe aborted: $e")
            } finally {
                busy = false
            }
        }
    }

    fun toggleLiveView() {
        if (lvActive) {
            lvJob?.cancel()
            return
        }
        val cam = cameraViewModel.getCamera() ?: return
        lvJob = scope.launch {
            lvActive = true
            try {
                if (cam.labStartLiveView(log)) {
                    var frames = 0
                    var windowStart = System.currentTimeMillis()
                    while (isActive) {
                        val grabbed = cam.labGrabFrame()
                        if (grabbed == null) { delay(50); continue }
                        showJpeg(grabbed.first)
                        frames++
                        val now = System.currentTimeMillis()
                        if (now - windowStart >= 1000) {
                            fpsText = "%.1f fps  %dKB".format(
                                frames * 1000f / (now - windowStart), grabbed.second / 1024
                            )
                            frames = 0
                            windowStart = now
                        }
                    }
                }
            } catch (e: Exception) {
                logLines.add("!! live view stopped: ${e.message}")
            } finally {
                // 页面退出/手动停止都必须把相机的 LV 关掉，否则机身停在遥控画面
                withContext(NonCancellable) {
                    val rc = cam.labEndLiveView()
                    logLines.add("EndLiveView resp=0x%04X".format(rc and 0xFFFF))
                }
                lvActive = false
                fpsText = ""
            }
        }
    }

    fun runCapture() {
        val cam = cameraViewModel.getCamera() ?: return
        scope.launch {
            busy = true
            try {
                val handle = cam.runLabCapture(log)
                if (handle != null) {
                    cam.labGetObjectInfo(handle)?.let {
                        logLines.add("new object: ${it.fileName} ${it.size}B")
                    }
                    // 拿缩略图回显拍摄结果
                    runCatching { cam.getThumbnail(handle) }.getOrNull()?.let { showJpeg(it) }
                }
            } catch (e: Exception) {
                logLines.add("!! capture aborted: $e")
            } finally {
                busy = false
            }
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background)
            .systemBarsPadding()
            .padding(12.dp)
    ) {
        // ---------- 顶栏 ----------
        Row(verticalAlignment = Alignment.CenterVertically) {
            GlassButton(onClick = onNavigateBack, contentPadding = PaddingValues(10.dp)) {
                Icon(
                    Icons.Default.ArrowBack, contentDescription = null,
                    tint = colors.onBackground, modifier = Modifier.size(20.dp)
                )
            }
            Spacer(Modifier.width(10.dp))
            Text(
                stringResource(R.string.lab_title),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = colors.onBackground
            )
            Spacer(Modifier.weight(1f))
            Text(
                text = if (state.isConnectedToCamera) "●" else "○",
                color = if (state.isConnectedToCamera) colors.statusConnected else colors.accentOrange,
                fontSize = 14.sp
            )
        }
        Spacer(Modifier.height(10.dp))

        // ---------- 画面区（LV 帧 / 试拍缩略图）----------
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(3f / 2f)
                .clip(RoundedCornerShape(12.dp))
                .background(Color.Black),
            contentAlignment = Alignment.Center
        ) {
            frame?.let {
                Image(
                    bitmap = it,
                    contentDescription = null,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize()
                )
            } ?: Icon(
                Icons.Default.Videocam, contentDescription = null,
                tint = Color.White.copy(alpha = 0.25f), modifier = Modifier.size(48.dp)
            )
            if (fpsText.isNotEmpty()) {
                Text(
                    fpsText,
                    color = Color.White,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(6.dp))
                        .padding(horizontal = 6.dp, vertical = 2.dp)
                )
            }
        }
        Spacer(Modifier.height(10.dp))

        // ---------- 动作按钮 ----------
        val connected = state.isConnectedToCamera
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            GlassButton(
                onClick = ::runProbe,
                enabled = connected && !busy && !lvActive,
                modifier = Modifier.weight(1f),
                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 10.dp)
            ) {
                Icon(Icons.Default.Radar, null, tint = colors.accentBlue, modifier = Modifier.size(16.dp))
                Text(
                    stringResource(R.string.lab_run_probe),
                    style = MaterialTheme.typography.labelMedium, color = colors.onBackground
                )
            }
            GlassButton(
                onClick = ::toggleLiveView,
                enabled = connected && !busy,
                modifier = Modifier.weight(1f),
                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 10.dp)
            ) {
                Icon(
                    if (lvActive) Icons.Default.Stop else Icons.Default.PlayArrow, null,
                    tint = if (lvActive) colors.accentOrange else colors.statusConnected,
                    modifier = Modifier.size(16.dp)
                )
                Text(
                    stringResource(if (lvActive) R.string.lab_live_view_stop else R.string.lab_live_view),
                    style = MaterialTheme.typography.labelMedium, color = colors.onBackground
                )
            }
            // 监看中允许拍摄：命令层与 LV 取帧共用 ioMutex 严格串行，无 AF 变体在 LV 下
            // 正是真实使用场景（之前禁用导致"点了没反应"——毛玻璃禁用态肉眼看不出来）。
            GlassButton(
                onClick = ::runCapture,
                enabled = connected && !busy,
                modifier = Modifier.weight(1f),
                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 10.dp)
            ) {
                Icon(Icons.Default.CameraAlt, null, tint = colors.accentBlue, modifier = Modifier.size(16.dp))
                Text(
                    stringResource(R.string.lab_capture),
                    style = MaterialTheme.typography.labelMedium, color = colors.onBackground
                )
            }
        }
        Spacer(Modifier.height(10.dp))

        // ---------- 日志 ----------
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .clip(RoundedCornerShape(12.dp))
                .background(colors.glassSurface)
        ) {
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 10.dp, vertical = 8.dp)
            ) {
                items(logLines) { line ->
                    Text(
                        line,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 10.sp,
                        lineHeight = 14.sp,
                        color = if (line.startsWith("!!")) colors.accentOrange else colors.onSurfaceVariant
                    )
                }
            }
            if (logLines.isNotEmpty()) {
                GlassButton(
                    onClick = {
                        clipboard.setText(AnnotatedString(logLines.joinToString("\n")))
                        logLines.add("--- log copied to clipboard ---")
                    },
                    contentPadding = PaddingValues(8.dp),
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(6.dp)
                ) {
                    Icon(
                        Icons.Default.ContentCopy, contentDescription = stringResource(R.string.lab_copy_log),
                        tint = colors.onSurfaceVariant, modifier = Modifier.size(14.dp)
                    )
                }
            }
        }
    }
}
