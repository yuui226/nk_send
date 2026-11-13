package com.ztransfer.ui.screen

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.AppTheme

/**
 * Shared shell for hints and small confirmation bubbles. Keep the rounded fill and border
 * without an elevation shadow: an outer fade/slide layer can clip that shadow to a flashing
 * rectangular footprint.
 * Visibility, timing and placement stay with each host; no extra layer or animation is needed.
 */
@Composable
internal fun GlassHintSurface(
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(22.dp),
    color: Color = AppTheme.colors.glassSurfaceHeavy,
    border: BorderStroke = BorderStroke(1.dp, AppTheme.colors.glassPanelBorder),
    content: @Composable () -> Unit,
) {
    Surface(
        modifier = modifier,
        shape = shape,
        color = color,
        border = border,
        tonalElevation = 0.dp,
        shadowElevation = 0.dp,
        content = content,
    )
}
