package com.ztransfer.ui.screen

import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ztransfer.diagnostics.PhotoGenerationProbe
import com.ztransfer.ui.theme.AppTheme

/** Debug 照片页的生成耗时窗口；Release 有同名空实现。 */
@Composable
internal fun DebugPhotoGenerationProbePanel(modifier: Modifier = Modifier) {
    val colors = AppTheme.colors
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val version by PhotoGenerationProbe.version.collectAsState()
    var open by remember { mutableStateOf(false) }
    val lines = remember(version, open) {
        if (open) PhotoGenerationProbe.displayLines() else emptyList()
    }

    Box(modifier = modifier) {
        if (!open) {
            GlassButton(
                onClick = { open = true },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .navigationBarsPadding()
                    .padding(bottom = 8.dp)
                    .height(30.dp),
                shape = RoundedCornerShape(15.dp),
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                panel = true,
            ) {
                Icon(
                    Icons.Default.Timer,
                    contentDescription = null,
                    tint = colors.accentOrange,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(Modifier.width(5.dp))
                Text(
                    "生成耗时",
                    color = colors.onBackground,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        } else {
            BackHandler { open = false }
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(colors.scrim)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                    ) { open = false },
            )
            Surface(
                shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
                color = colors.glassSurfaceHeavy,
                border = BorderStroke(1.dp, colors.glassPanelBorder),
                shadowElevation = 8.dp,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .fillMaxHeight(0.82f),
            ) {
                Column(
                    modifier = Modifier
                        .navigationBarsPadding()
                        .padding(14.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                "照片生成分段耗时",
                                style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.SemiBold,
                                color = colors.onBackground,
                            )
                            Text(
                                "生成完成后复制报告，用于定位 25 秒异常",
                                fontSize = 11.sp,
                                color = colors.onSurfaceVariant,
                            )
                        }
                        GlassButton(
                            onClick = {
                                clipboard.setText(AnnotatedString(PhotoGenerationProbe.report()))
                                Toast.makeText(context, "生成耗时报告已复制", Toast.LENGTH_SHORT).show()
                            },
                            contentPadding = PaddingValues(8.dp),
                        ) {
                            Icon(
                                Icons.Default.ContentCopy,
                                contentDescription = "复制生成耗时报告",
                                tint = colors.accentBlue,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                        GlassButton(
                            onClick = { PhotoGenerationProbe.clear() },
                            contentPadding = PaddingValues(8.dp),
                        ) {
                            Icon(
                                Icons.Default.DeleteSweep,
                                contentDescription = "清空生成耗时",
                                tint = colors.onSurfaceVariant,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                        GlassButton(
                            onClick = { open = false },
                            contentPadding = PaddingValues(8.dp),
                        ) {
                            Icon(
                                Icons.Default.Close,
                                contentDescription = "关闭",
                                tint = colors.onSurfaceVariant,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }
                    Spacer(Modifier.height(10.dp))
                    LazyColumn(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxWidth()
                            .background(Color.Black.copy(alpha = 0.45f), RoundedCornerShape(10.dp))
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                    ) {
                        items(lines) { line ->
                            Text(
                                text = line,
                                color = when {
                                    "failed" in line || "error" in line -> colors.accentOrange
                                    "saved" in line -> colors.statusConnected
                                    else -> Color.White.copy(alpha = 0.82f)
                                },
                                fontFamily = FontFamily.Monospace,
                                fontSize = 9.sp,
                                lineHeight = 12.sp,
                            )
                        }
                    }
                }
            }
        }
    }
}
