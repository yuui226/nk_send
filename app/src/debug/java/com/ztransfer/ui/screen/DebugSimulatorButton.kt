package com.ztransfer.ui.screen

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.AppTheme

/** Debug 连接页的显式模拟相机入口；不再随 App 启动自动连接。 */
@Composable
internal fun DebugSimulatorButton(onClick: () -> Unit) {
    val colors = AppTheme.colors
    GlassButton(
        onClick = onClick,
        shape = RoundedCornerShape(18.dp),
        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp),
        modifier = Modifier.height(36.dp),
    ) {
        Icon(
            imageVector = Icons.Default.PhotoLibrary,
            contentDescription = "打开模拟照片",
            tint = colors.accentBlue,
            modifier = Modifier.size(18.dp),
        )
    }
    Spacer(Modifier.width(8.dp))
}
