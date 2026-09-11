@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.RotateLeft
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.AppTheme

/** Shared glass rotation control for full-screen and effect previews. */
@kotlin.native.HiddenFromObjC
@Composable
fun SharedPreviewRotationButton(
    onClick: () -> Unit,
    description: @Composable () -> String,
    modifier: Modifier = Modifier,
    buttonSize: Dp = 44.dp,
) {
    val colors = AppTheme.colors
    GlassButton(
        onClick = onClick,
        modifier = modifier.size(buttonSize),
        shape = CircleShape,
        contentPadding = PaddingValues(buttonSize / 4f),
    ) {
        Icon(
            imageVector = Icons.Default.RotateLeft,
            contentDescription = description(),
            tint = colors.accentBlue,
            modifier = Modifier.size(buttonSize / 2f),
        )
    }
}
