"""Exact original viewport/single-photo extraction. Does not normalize numbers or gesture keys."""
from transfer_card_extraction import replace_once
from thumbnail_grid_extraction import section

HEADER = '''@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

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

'''


def extract_photo_viewport(source, rotation):
    source = source.replace('\r\n', '\n'); rotation = rotation.replace('\r\n', '\n')
    single = section(source, '@Composable\ninternal fun SinglePhotoPreviewOverlay(', '@Composable\nprivate fun BurstCollectionPreviewPage(')
    viewport = source[source.index('@Composable\nprivate fun ZoomablePreviewViewport('):]
    android = replace_once(source, single, '''@Composable
internal fun SinglePhotoPreviewOverlay(
    bitmap: ImageBitmap,
    title: String,
    anchorRect: Rect?,
    onDismiss: () -> Unit,
) = SharedSinglePhotoPreviewOverlay(bitmap, title, anchorRect, onDismiss,
    backHandler = { enabled, onBack -> BackHandler(enabled, onBack) },
    rotationDescription = { stringResource(R.string.cd_rotate_photo) },
)

''')
    android = replace_once(android, viewport, '')
    android = replace_once(android, 'private const val MAX_ZOOM = 4f\nprivate const val DOUBLE_TAP_ZOOM = 2.5f\n\n', '')
    android = replace_once(android, '    ZoomablePreviewViewport(', '    SharedZoomablePreviewViewport(')
    # The entire paging/loading coordinator and every other original helper stay untouched.
    shared_single = replace_once(single, '@Composable\ninternal fun SinglePhotoPreviewOverlay(', '@kotlin.native.HiddenFromObjC\n@Composable\nfun SharedSinglePhotoPreviewOverlay(')
    shared_single = replace_once(shared_single, '    onDismiss: () -> Unit,\n', '''    onDismiss: () -> Unit,
    backHandler: @Composable (Boolean, () -> Unit) -> Unit,
    rotationDescription: @Composable () -> String,
''')
    shared_single = replace_once(shared_single, '    BackHandler(enabled = !closing) { startClose() }', '    backHandler(!closing, startClose)')
    shared_single = replace_once(shared_single, '            ZoomablePreviewViewport(', '            SharedZoomablePreviewViewport(')
    shared_single = replace_once(shared_single, '            PreviewRotationButton(onClick = {', '            SharedPreviewRotationButton(description = rotationDescription, onClick = {')
    shared_viewport = replace_once(viewport, '@Composable\nprivate fun ZoomablePreviewViewport(', '@kotlin.native.HiddenFromObjC\n@Composable\nfun SharedZoomablePreviewViewport(')
    assert shared_viewport.count('Math.toRadians(') == 2
    shared_viewport = shared_viewport.replace('Math.toRadians(', 'previewRadians(')
    shared_viewport = HEADER + 'private const val MAX_ZOOM = 4f\nprivate const val DOUBLE_TAP_ZOOM = 2.5f\n\n' + shared_viewport
    shared_single = HEADER + shared_single.rstrip() + '\n'
    shared_rotation = rotation.replace('import androidx.compose.ui.res.stringResource\n', '').replace('import com.ztransfer.R\n', '')
    shared_rotation = replace_once(shared_rotation, '@Composable\ninternal fun PreviewRotationButton(', '@kotlin.native.HiddenFromObjC\n@Composable\nfun SharedPreviewRotationButton(')
    shared_rotation = replace_once(shared_rotation, '    onClick: () -> Unit,\n', '    onClick: () -> Unit,\n    description: @Composable () -> String,\n')
    shared_rotation = replace_once(shared_rotation, 'stringResource(R.string.cd_rotate_photo)', 'description()')
    shared_rotation = '@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)\n\n' + shared_rotation
    body = rotation[rotation.index('    val colors = AppTheme.colors'):]
    android_rotation = replace_once(rotation, body, '''    SharedPreviewRotationButton(onClick, { stringResource(R.string.cd_rotate_photo) }, modifier, buttonSize)
}
''')
    return android, shared_single, shared_viewport, android_rotation, shared_rotation
