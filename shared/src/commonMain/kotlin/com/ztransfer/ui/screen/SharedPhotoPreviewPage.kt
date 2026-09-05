@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.animation.core.*
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.Motion
import kotlin.math.*
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.sp
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.viewmodel.PhotoExif
import com.ztransfer.ui.theme.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

@kotlin.native.HiddenFromObjC
val PREVIEW_VIDEO_EXTENSIONS = setOf(".mov", ".mp4")
private const val FHD_REVEAL_DURATION_MS = 300L
private const val FHD_REVEAL_FRAME_MS = 16L

@kotlin.native.HiddenFromObjC
@Composable
fun SharedPhotoPreviewPage(
    file: CameraFileInfo,
    images: PreviewPageImages,
    text: PreviewPageText,
    uptimeMillis: () -> Long,
    fhdBitmap: ImageBitmap?,
    isLoadingFhd: Boolean,
    allowRemoteThumbnailFallback: Boolean,
    loadEnabled: Boolean,
    rotationDegrees: Float,
    isCurrent: Boolean,
    onDisplayBitmapChanged: (ImageBitmap?) -> Unit,
    onZoomedChange: (Boolean) -> Unit,
    onTap: () -> Unit
) {
    // 预览通常由一个已经显示缩略图的可见格子打开。同步复用同一份内存缓存，确保
    // overlay 第一帧就有画面；缓存未命中时才异步走磁盘/相机兜底。
    var thumbnail by remember(file.handle) {
        mutableStateOf(images.cached(file.handle))
    }
    // 取过仍为 null → 该文件确实没有缩略图（如部分视频）。
    var noThumb by remember(file.handle) { mutableStateOf(false) }
    LaunchedEffect(file.handle, loadEnabled, allowRemoteThumbnailFallback) {
        if (loadEnabled && thumbnail == null && !noThumb) {
            val t = images.thumbnail(
                file = file,
                allowRemote = allowRemoteThumbnailFallback,
            )
            if (t != null) thumbnail = t
            else if (allowRemoteThumbnailFallback) noThumb = true
        }
    }

    // FHD 到位后覆盖在缩略图上淡入。缩略图在过渡完成前始终保持不透明，避免两张图
    // 的有效画面边界略有差异时交叉淡出露出背景，视觉上只发生一次连续的“变清晰”。
    var fhdAlpha by remember(file.handle) { mutableFloatStateOf(0f) }
    LaunchedEffect(fhdBitmap) {
        if (fhdBitmap != null) {
            if (thumbnail == null) {
                fhdAlpha = 1f
            } else {
                // FHD 是否可见不能依赖 Compose 动画帧时钟：部分设备上该时钟可能不推进，
                // Animatable 会一直停在 0，造成 FHD 已加载却始终被透明隐藏。
                fhdAlpha = 0f
                val startedAt = uptimeMillis()
                while (isActive) {
                    val elapsed = uptimeMillis() - startedAt
                    val linearProgress =
                        (elapsed.toFloat() / FHD_REVEAL_DURATION_MS).coerceIn(0f, 1f)
                    fhdAlpha = FastOutSlowInEasing.transform(linearProgress)
                    if (linearProgress >= 1f) break
                    delay(FHD_REVEAL_FRAME_MS)
                }
            }
        } else {
            fhdAlpha = 0f
        }
    }

    val displayBitmap = fhdBitmap ?: thumbnail
    LaunchedEffect(displayBitmap, isCurrent) {
        if (isCurrent) onDisplayBitmapChanged(displayBitmap)
    }
    val isVideo = file.extension in PREVIEW_VIDEO_EXTENSIONS
    SharedZoomablePreviewViewport(
        imageSize = displayBitmap?.let { IntSize(it.width, it.height) },
        stateKey = file.handle,
        rotationDegrees = rotationDegrees,
        isCurrent = isCurrent,
        zoomEnabled = !isVideo && displayBitmap != null,
        onZoomedChange = onZoomedChange,
        onTap = onTap,
    ) { imageTransform ->
        val thumb = thumbnail  // 本地变量，delegate 属性无法被编译器 smart cast
        // 若 FHD 比缩略图先到，直接显示 FHD；不能等待 LaunchedEffect 下一帧再 snap，
        // 否则仍会产生一帧全透明图片区。
        val effectiveFhdAlpha = if (thumb == null) 1f else fhdAlpha
        val anyLoading = isLoadingFhd || (!noThumb && thumbnail == null)
        when {
            isVideo -> {
                // 视频无高清封面：缩略图压暗当背景 + 居中毛玻璃信息卡，明确暂不支持播放，
                // 同时复用 ObjectInfo 已有的大小与拍摄时间，不为占位页增加相机请求。
                // 而非把糊掉的小缩略图硬撑满屏当"预览"。
                if (thumb != null) {
                    Image(
                        bitmap = thumb,
                        contentDescription = null,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.fillMaxSize()
                    )
                }
                Box(modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.5f)))
                val metadata = text.videoMetadata(file)
                Surface(
                    shape = RoundedCornerShape(18.dp),
                    color = Color.Black.copy(alpha = 0.45f),
                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.22f))
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
                    ) {
                        Text(
                            text.videoUnavailable(),
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.Medium,
                            color = Color.White,
                        )
                        if (metadata.isNotEmpty()) {
                            Spacer(Modifier.height(6.dp))
                            Text(
                                text = metadata,
                                style = MaterialTheme.typography.labelMedium,
                                color = Color.White.copy(alpha = 0.76f),
                                textAlign = TextAlign.Center,
                            )
                        }
                    }
                }
            }
            displayBitmap != null -> {
                // 图像栈（缩略图淡出 + FHD 淡入）统一套用缩放/平移变换。
                Box(modifier = imageTransform) {
                    if (thumb != null && (fhdBitmap == null || effectiveFhdAlpha < 1f)) {
                        Image(
                            bitmap = thumb,
                            contentDescription = file.fileName.takeIf { fhdBitmap == null },
                            contentScale = ContentScale.Fit,
                            modifier = Modifier.fillMaxSize()
                        )
                    }
                    if (fhdBitmap != null) {
                        Image(
                            bitmap = fhdBitmap,
                            contentDescription = file.fileName,
                            contentScale = ContentScale.Fit,
                            modifier = Modifier.fillMaxSize(),
                            alpha = effectiveFhdAlpha
                        )
                    }

                }
            }
            anyLoading -> CircularProgressIndicator(color = AccentBlue, modifier = Modifier.size(32.dp))
            noThumb -> Text(text.noPreview(), color = DarkOnSurfaceVariant)
            else -> CircularProgressIndicator(color = AccentBlue, modifier = Modifier.size(32.dp))
        }
    }
}
