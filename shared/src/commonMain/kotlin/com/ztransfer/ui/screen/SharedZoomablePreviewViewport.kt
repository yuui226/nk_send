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

private const val MAX_ZOOM = 4f
private const val DOUBLE_TAP_ZOOM = 2.5f

@kotlin.native.HiddenFromObjC
@Composable
fun SharedZoomablePreviewViewport(
    imageSize: IntSize?,
    stateKey: Any,
    rotationDegrees: Float,
    isCurrent: Boolean,
    zoomEnabled: Boolean,
    onZoomedChange: (Boolean) -> Unit,
    onTap: () -> Unit,
    content: @Composable BoxScope.(Modifier) -> Unit,
) {
    val animatedRotation by animateFloatAsState(
        targetValue = rotationDegrees,
        animationSpec = tween(220),
        label = "previewRotation",
    )
    var scale by remember(stateKey) { mutableFloatStateOf(1f) }
    var offset by remember(stateKey) { mutableStateOf(Offset.Zero) }
    var zoomAnimJob by remember(stateKey) { mutableStateOf<Job?>(null) }
    val scope = rememberCoroutineScope()
    val zoomed = scale > 1.01f

    LaunchedEffect(isCurrent) {
        if (!isCurrent) {
            zoomAnimJob?.cancel()
            scale = 1f
            offset = Offset.Zero
        }
    }
    LaunchedEffect(isCurrent, zoomed) {
        if (isCurrent) onZoomedChange(zoomed)
    }
    LaunchedEffect(rotationDegrees) {
        zoomAnimJob?.cancel()
        scale = 1f
        offset = Offset.Zero
    }

    val rawAspect = imageSize?.takeIf { it.width > 0 && it.height > 0 }?.let {
        it.width.toFloat() / it.height.toFloat()
    }
    val quarterTurn = ((rotationDegrees / 90f).roundToInt() % 2) != 0
    val imageAspect = rawAspect?.let { if (quarterTurn) 1f / it else it }
    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    val viewportW = viewportSize.width.toFloat()
    val viewportH = viewportSize.height.toFloat()
    val baseImageW: Float
    val baseImageH: Float
    if (rawAspect != null && viewportW > 0f && viewportH > 0f) {
        val viewportAspect = viewportW / viewportH
        baseImageW = if (rawAspect > viewportAspect) viewportW else viewportH * rawAspect
        baseImageH = if (rawAspect > viewportAspect) viewportW / rawAspect else viewportH
    } else {
        baseImageW = 0f
        baseImageH = 0f
    }
    val targetRotationRadians = previewRadians(rotationDegrees.toDouble())
    val targetAbsCos = abs(cos(targetRotationRadians)).toFloat()
    val targetAbsSin = abs(sin(targetRotationRadians)).toFloat()
    val targetBoundsWidth = baseImageW * targetAbsCos + baseImageH * targetAbsSin
    val targetBoundsHeight = baseImageW * targetAbsSin + baseImageH * targetAbsCos
    val targetRotationFit = if (
        targetBoundsWidth > 0f && targetBoundsHeight > 0f && viewportW > 0f && viewportH > 0f
    ) {
        min(viewportW / targetBoundsWidth, viewportH / targetBoundsHeight)
    } else {
        1f
    }
    val targetBreathingRoom = if ((rawAspect ?: 0f) > 1f) {
        1f - 0.08f * targetAbsSin
    } else {
        1f
    }
    val oneToOneZoom = imageSize?.takeIf {
        it.width > 0 && it.height > 0 && baseImageW > 0f && baseImageH > 0f
    }?.let {
        max(it.width / baseImageW, it.height / baseImageH) /
            (targetRotationFit * targetBreathingRoom).coerceAtLeast(0.01f)
    } ?: 1f
    val maximumZoom = max(MAX_ZOOM, oneToOneZoom)

    fun clampOffset(
        targetScale: Float,
        targetOffset: Offset,
        displayWidth: Float,
        displayHeight: Float,
        containerWidth: Float,
        containerHeight: Float,
    ): Offset {
        val maxX = max(0f, (displayWidth * targetScale - containerWidth) / 2f)
        val maxY = max(0f, (displayHeight * targetScale - containerHeight) / 2f)
        return Offset(
            targetOffset.x.coerceIn(-maxX, maxX),
            targetOffset.y.coerceIn(-maxY, maxY),
        )
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .onSizeChanged { viewportSize = it }
            // 单指且处于 1x 时不消费，让列表分页器接管；单图预览的根层会统一阻断穿透。
            .pointerInput(imageAspect, zoomEnabled, maximumZoom) {
                val aspect = imageAspect
                if (!zoomEnabled || aspect == null) return@pointerInput
                val containerWidth = size.width.toFloat()
                val containerHeight = size.height.toFloat()
                val containerAspect = containerWidth / containerHeight
                val displayWidth = if (aspect > containerAspect) {
                    containerWidth
                } else {
                    containerHeight * aspect
                }
                val displayHeight = if (aspect > containerAspect) {
                    containerWidth / aspect
                } else {
                    containerHeight
                }
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    zoomAnimJob?.cancel()
                    do {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.count { it.pressed }
                        if (pressed >= 2 || scale > 1.01f) {
                            val zoomChange = event.calculateZoom()
                            val panChange = event.calculatePan()
                            if (zoomChange != 1f || panChange != Offset.Zero) {
                                val newScale = (scale * zoomChange).coerceIn(1f, maximumZoom)
                                val centroid = event.calculateCentroid(useCurrent = true)
                                val centerDelta = Offset(
                                    centroid.x - containerWidth / 2f,
                                    centroid.y - containerHeight / 2f,
                                )
                                offset = clampOffset(
                                    newScale,
                                    offset + centerDelta * (scale - newScale) + panChange,
                                    displayWidth,
                                    displayHeight,
                                    containerWidth,
                                    containerHeight,
                                )
                                scale = newScale
                                event.changes.forEach { change ->
                                    if (change.pressed) change.consume()
                                }
                            }
                        }
                    } while (event.changes.any { it.pressed })
                }
            }
            .pointerInput(imageAspect, zoomEnabled) {
                val containerWidth = size.width.toFloat()
                val containerHeight = size.height.toFloat()
                detectTapGestures(
                    onTap = { if (scale <= 1.01f) onTap() },
                    onDoubleTap = { tap ->
                        val aspect = imageAspect
                        if (!zoomEnabled || aspect == null) return@detectTapGestures
                        val containerAspect = containerWidth / containerHeight
                        val displayWidth = if (aspect > containerAspect) {
                            containerWidth
                        } else {
                            containerHeight * aspect
                        }
                        val displayHeight = if (aspect > containerAspect) {
                            containerWidth / aspect
                        } else {
                            containerHeight
                        }
                        val targetScale = if (scale > 1.01f) 1f else DOUBLE_TAP_ZOOM
                        val startScale = scale
                        val startOffset = offset
                        val targetOffset = if (targetScale == 1f) {
                            Offset.Zero
                        } else {
                            clampOffset(
                                targetScale,
                                Offset(
                                    tap.x - containerWidth / 2f,
                                    tap.y - containerHeight / 2f,
                                ) * (1f - targetScale),
                                displayWidth,
                                displayHeight,
                                containerWidth,
                                containerHeight,
                            )
                        }
                        zoomAnimJob?.cancel()
                        zoomAnimJob = scope.launch {
                            Animatable(0f).animateTo(1f, tween(240)) {
                                scale = startScale + (targetScale - startScale) * value
                                offset = androidx.compose.ui.geometry.lerp(
                                    startOffset,
                                    targetOffset,
                                    value,
                                )
                            }
                        }
                    },
                )
            },
        contentAlignment = Alignment.Center,
    ) {
        val imageTransform = Modifier
            .fillMaxSize()
            .graphicsLayer {
                val angle = previewRadians(animatedRotation.toDouble())
                val absCos = abs(cos(angle)).toFloat()
                val absSin = abs(sin(angle)).toFloat()
                val boundsWidth = baseImageW * absCos + baseImageH * absSin
                val boundsHeight = baseImageW * absSin + baseImageH * absCos
                val rotationFit = if (boundsWidth > 0f && boundsHeight > 0f) {
                    min(viewportW / boundsWidth, viewportH / boundsHeight)
                } else {
                    1f
                }
                val portraitBreathingRoom = if ((rawAspect ?: 0f) > 1f) {
                    1f - 0.08f * absSin
                } else {
                    1f
                }
                scaleX = scale * rotationFit * portraitBreathingRoom
                scaleY = scale * rotationFit * portraitBreathingRoom
                translationX = offset.x
                translationY = offset.y
                rotationZ = animatedRotation
            }
        content(imageTransform)
    }
}
