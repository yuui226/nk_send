package com.ztransfer.ui.screen

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowForward
import androidx.compose.material.icons.filled.Close
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.ui.theme.AppTheme

@Composable
internal fun GlassBackButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    forward: Boolean = false,
    enabled: Boolean = true,
) {
    GlassNavigationButton(onClick, modifier,
        if (forward) Icons.Default.ArrowForward else Icons.Default.ArrowBack,
        stringResource(R.string.cd_back), enabled)
}

@Composable
internal fun GlassCloseButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    GlassNavigationButton(onClick, modifier, Icons.Default.Close, stringResource(R.string.cd_close))
}

@Composable
private fun GlassNavigationButton(
    onClick: () -> Unit,
    modifier: Modifier,
    icon: ImageVector,
    description: String,
    enabled: Boolean = true,
) {
    GlassButton(
        onClick = onClick,
        enabled = enabled,
        // The host animates visibility; disabling input must not add an abrupt dimming step.
        disabledAlpha = 1f,
        shape = RoundedCornerShape(22.dp),
        contentPadding = PaddingValues(horizontal = 9.dp, vertical = 7.dp),
        enforceMinimumTouchTarget = false,
        modifier = modifier.size(width = 40.dp, height = 36.dp),
    ) {
        Icon(
            icon,
            contentDescription = description,
            tint = AppTheme.colors.onBackground,
            modifier = Modifier.size(22.dp),
        )
    }
}
