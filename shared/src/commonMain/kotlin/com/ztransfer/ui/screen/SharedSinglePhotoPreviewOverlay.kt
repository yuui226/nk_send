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

@kotlin.native.HiddenFromObjC
@Composable
fun SharedSinglePhotoPreviewOverlay(
    bitmap: ImageBitmap,
    title: String,
    anchorRect: Rect?,
    onDismiss: () -> Unit,
    backHandler: @Composable (Boolean, () -> Unit) -> Unit,
    rotationDescription: @Composable () -> String,
) {
    var overlayBounds by remember { mutableStateOf<Rect?>(null) }
    val progress = remember { Animatable(0f) }
    var closing by remember { mutableStateOf(false) }
    var rotationDegrees by remember(bitmap) { mutableFloatStateOf(0f) }

    LaunchedEffect(overlayBounds, closing) {
        if (!closing && overlayBounds != null && progress.value < 1f) {
            progress.animateTo(1f, Motion.overlayExpand)
        }
    }
    LaunchedEffect(closing) {
        if (closing) {
            progress.animateTo(0f, Motion.overlayCollapse)
            onDismiss()
        }
    }
    val startClose: () -> Unit = {
        if (!closing) closing = true
    }
    backHandler(!closing, startClose)

    Box(
        modifier = Modifier
            .fillMaxSize()
            .onGloballyPositioned { overlayBounds = it.boundsInRoot() }
            // 阻断未被大图手势处理的拖动，避免事件穿透到设置页滚动容器。
            .pointerInput(Unit) { detectDragGestures { change, _ -> change.consume() } },
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .drawBehind { drawRect(Color.Black, alpha = 0.74f * progress.value) },
        )

        Box(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    val bounds = overlayBounds
                    val anchor = anchorRect
                    if (bounds != null && anchor != null && bounds.width > 0f && bounds.height > 0f) {
                        transformOrigin = TransformOrigin(
                            (anchor.center.x - bounds.left) / bounds.width,
                            (anchor.center.y - bounds.top) / bounds.height,
                        )
                        val startScale = (anchor.width / bounds.width).coerceIn(0.05f, 1f)
                        val scale = startScale + (1f - startScale) * progress.value
                        scaleX = scale
                        scaleY = scale
                        alpha = if (closing) {
                            (progress.value * 1.6f).coerceAtMost(1f)
                        } else {
                            1f
                        }
                    } else {
                        scaleX = 1f
                        scaleY = 1f
                        alpha = progress.value
                    }
                },
        ) {
            SharedZoomablePreviewViewport(
                imageSize = IntSize(bitmap.width, bitmap.height),
                stateKey = bitmap,
                rotationDegrees = rotationDegrees,
                isCurrent = true,
                zoomEnabled = true,
                onZoomedChange = {},
                onTap = startClose,
            ) { imageTransform ->
                Image(
                    bitmap = bitmap,
                    contentDescription = title,
                    contentScale = ContentScale.Fit,
                    modifier = imageTransform,
                )
            }
        }

        Text(
            text = title,
            style = MaterialTheme.typography.labelMedium,
            color = Color.White.copy(alpha = 0.85f * progress.value),
            textAlign = TextAlign.Center,
            maxLines = 1,
            modifier = Modifier
                .align(Alignment.TopCenter)
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(top = 12.dp, start = 52.dp, end = 52.dp),
        )

        Box(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .navigationBarsPadding()
                .padding(end = 20.dp, bottom = 32.dp)
                .graphicsLayer { alpha = progress.value },
        ) {
            SharedPreviewRotationButton(description = rotationDescription, onClick = {
                rotationDegrees -= 90f
            })
        }
    }
}
