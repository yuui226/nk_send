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
@Composable
fun SharedPreviewBurstPage(
    collection: PhotoPreviewItem.BurstCollection,
    content: PreviewBurstContent,
    loadEnabled: Boolean,
    isCurrent: Boolean,
    onZoomedChange: (Boolean) -> Unit,
    stackMotionProgress: () -> Float = { 0f },
    onTap: () -> Unit
) {
    val a11y = content.accessibility(collection.files.size)
    LaunchedEffect(isCurrent) {
        if (isCurrent) onZoomedChange(false)
    }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .semantics { contentDescription = a11y }
            .pointerInput(collection.id) {
                detectTapGestures(onTap = { onTap() })
            },
        contentAlignment = Alignment.Center
    ) {
        val stackSize = minOf(maxWidth * 0.72f, maxHeight * 0.46f, 360.dp)
        SharedPreviewBurstStack(
            files = collection.files,
            content = content,
            loadEnabled = loadEnabled,
            stackSize = stackSize,
            stackMotionProgress = stackMotionProgress,
            modifier = Modifier.size(stackSize),
        )
    }
}

@kotlin.native.HiddenFromObjC
@Composable
fun SharedPreviewBurstStack(
    files: List<CameraFileInfo>,
    content: PreviewBurstContent,
    loadEnabled: Boolean,
    stackSize: Dp,
    stackMotionProgress: () -> Float = { 0f },
    modifier: Modifier = Modifier,
) {
    Box(modifier = modifier) {
        val stackFiles = files.take(3).reversed()
        val stackInset = stackSize * 0.07f + 6.dp
        val stackSpreadPx = with(LocalDensity.current) { 6.dp.toPx() }
        stackFiles.forEachIndexed { index, file ->
            val last = stackFiles.lastIndex
            val rotation = when (stackFiles.size) {
                1 -> 0f
                2 -> if (index == 0) -5f else 3f
                else -> when (index) {
                    0 -> -6f
                    1 -> 5f
                    else -> 0f
                }
            }
            val x = when {
                index == last -> 0.dp
                index % 2 == 0 -> (-12).dp
                else -> 12.dp
            }
            val spreadDirection = when {
                index == last -> 0f
                index % 2 == 0 -> -1f
                else -> 1f
            }
            content.Photo(
                file = file,
                loadEnabled = loadEnabled,
                showPlaceholderIcon = index == last,
                modifier = Modifier
                    .fillMaxSize(0.86f)
                    .align(Alignment.Center)
                    .offset(x = x, y = if (index == last) 2.dp else 5.dp)
                    .graphicsLayer {
                        val motion = stackMotionProgress().coerceIn(0f, 1f)
                        rotationZ = rotation
                        translationX = spreadDirection * stackSpreadPx * motion
                        val motionScale = 1f + 0.012f * motion
                        scaleX = motionScale
                        scaleY = motionScale
                    }
            )
        }

        content.Badge(
            count = files.size,
            iconSize = 16.dp,
            modifier = Modifier
                .align(Alignment.TopStart)
                .offset(x = stackInset, y = stackInset)
        )
    }
}
