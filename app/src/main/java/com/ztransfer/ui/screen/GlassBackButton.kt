package com.ztransfer.ui.screen

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowForward
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.ui.theme.AppTheme

@Composable
internal fun GlassBackButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    forward: Boolean = false,
) {
    GlassButton(
        onClick = onClick,
        shape = RoundedCornerShape(22.dp),
        contentPadding = PaddingValues(horizontal = 9.dp, vertical = 7.dp),
        enforceMinimumTouchTarget = false,
        modifier = modifier.size(width = 40.dp, height = 36.dp),
    ) {
        Icon(
            if (forward) Icons.Default.ArrowForward else Icons.Default.ArrowBack,
            contentDescription = stringResource(R.string.cd_back),
            tint = AppTheme.colors.onBackground,
            modifier = Modifier.size(22.dp),
        )
    }
}
