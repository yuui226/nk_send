package com.ztransfer.ui.screen

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.AppTheme

private const val TIP_LIGHTBULB_TEXTURE_SEED = 0x1457A101

/** 连接提示统一入口；调用方只决定尺寸，材质和图标比例保持一致。 */
@Composable
internal fun TipLightbulbButton(
    onClick: () -> Unit,
    contentDescription: String,
    modifier: Modifier = Modifier,
) {
    GlassButton(
        onClick = onClick,
        shape = RoundedCornerShape(12.dp),
        contentPadding = PaddingValues(0.dp),
        textureSeed = TIP_LIGHTBULB_TEXTURE_SEED,
        modifier = modifier,
    ) {
        Box(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Default.Lightbulb,
                contentDescription = contentDescription,
                tint = AppTheme.colors.accentOrange,
                modifier = Modifier.fillMaxSize(0.45f),
            )
        }
    }
}
