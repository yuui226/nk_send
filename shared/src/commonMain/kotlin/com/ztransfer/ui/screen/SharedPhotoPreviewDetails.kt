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
fun SharedPreviewBurstNavigationButton(
    expand: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
    text: PreviewPageText,
) {
    val colors = AppTheme.colors
    val description = text.navigationDescription(expand)
    GlassButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.size(44.dp),
        shape = CircleShape,
        contentPadding = PaddingValues(0.dp),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .semantics { contentDescription = description },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = if (expand) {
                    Icons.Default.ChevronRight
                } else {
                    Icons.Default.ChevronLeft
                },
                contentDescription = null,
                tint = colors.accentBlue,
                modifier = Modifier.size(25.dp),
            )
        }
    }
}

@kotlin.native.HiddenFromObjC
@Composable
fun SharedPreviewExifMetadataBar(
    exif: PhotoExif,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    val parts = listOfNotNull(
        exif.aperture,
        exif.shutterSpeed,
        exif.iso,
        exif.exposureCompensation,
        exif.focalLength,
    )
    if (parts.isEmpty()) return
    val text = parts.joinToString("\u2009·\u2009")
    val textMeasurer = rememberTextMeasurer(cacheSize = 4)
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = colors.glassSurfaceHeavy,
        shadowElevation = 4.dp,
        border = BorderStroke(1.dp, colors.glassPanelBorder),
        modifier = modifier
    ) {
        BoxWithConstraints {
            val horizontalPadding = 14.dp
            val availableWidthPx = with(LocalDensity.current) {
                (maxWidth - horizontalPadding * 2).coerceAtLeast(0.dp).roundToPx()
            }
            val baseStyle = MaterialTheme.typography.labelLarge
            val textStyle = remember(text, availableWidthPx, baseStyle) {
                listOf(
                    baseStyle,
                    baseStyle.copy(fontSize = 13.sp, lineHeight = 18.sp),
                    baseStyle.copy(fontSize = 12.sp, lineHeight = 17.sp),
                    baseStyle.copy(fontSize = 11.sp, lineHeight = 16.sp),
                ).firstOrNull { candidate ->
                    textMeasurer.measure(
                        text = AnnotatedString(text),
                        style = candidate,
                        maxLines = 1,
                        softWrap = false,
                    ).size.width <= availableWidthPx
                } ?: baseStyle.copy(fontSize = 11.sp, lineHeight = 16.sp)
            }
            Text(
                text = text,
                style = textStyle,
                color = colors.onBackground,
                textAlign = TextAlign.Center,
                maxLines = 1,
                softWrap = false,
                overflow = TextOverflow.Clip,
                modifier = Modifier.padding(horizontal = horizontalPadding, vertical = 10.dp),
            )
        }
    }
}

@kotlin.native.HiddenFromObjC
@Composable
fun SharedPreviewTransferQueueButton(
    onClick: () -> Unit,
    text: PreviewPageText,
    modifier: Modifier = Modifier,
    buttonSize: Dp = 44.dp
) {
    val colors = AppTheme.colors
    GlassButton(
        onClick = onClick,
        modifier = modifier.size(buttonSize),
        shape = CircleShape,
        contentPadding = PaddingValues(0.dp)
    ) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = Icons.Default.Add,
                contentDescription = text.transferDescription(),
                tint = colors.accentBlue,
                modifier = Modifier.size(buttonSize * 0.5f)
            )
        }
    }
}
