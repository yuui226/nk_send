package com.ztransfer.ui.screen

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.AppTheme

/** Debug 模拟相机入口：短按免费版成功动画，长按高级版成功动画。 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun DebugSimulatorButton(
    onClick: () -> Unit,
    onLongClick: () -> Unit,
) {
    val colors = AppTheme.colors
    Row {
        Spacer(Modifier.width(8.dp))
        GlassSurface(
            shape = RoundedCornerShape(18.dp),
            modifier = Modifier
                .height(36.dp)
                .combinedClickable(
                    role = Role.Button,
                    onClick = onClick,
                    onLongClickLabel = "播放高级版连接成功动画",
                    onLongClick = onLongClick,
                ),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxHeight()
                    .padding(PaddingValues(horizontal = 10.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Default.PhotoLibrary,
                    contentDescription = "打开模拟照片",
                    tint = colors.accentBlue,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
        Spacer(Modifier.width(8.dp))
    }
}
