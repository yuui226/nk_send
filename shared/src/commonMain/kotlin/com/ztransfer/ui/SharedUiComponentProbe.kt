package com.ztransfer.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.screen.*
import com.ztransfer.ui.theme.*
import com.ztransfer.ui.util.rememberHaptics
import com.ztransfer.viewmodel.TransferStatus

/** Development acceptance surface, not a second product screen or a fake camera session. */
@Composable
fun SharedUiComponentProbe() {
    var mode by remember { mutableStateOf(ThemeMode.SYSTEM) }
    var skin by remember { mutableStateOf(SkinPreset.FROSTED_GLASS) }
    var progress by remember { mutableFloatStateOf(0.45f) }
    var buttonActive by remember { mutableStateOf(false) }
    var clickCount by remember { mutableIntStateOf(0) }
    var feedbackEnabled by remember { mutableStateOf(true) }
    var wheelValue by remember { mutableStateOf("A") }
    var showHelp by remember { mutableStateOf(false) }
    val haptics = rememberHaptics(feedbackEnabled)
    val fireworks = rememberFireworksState()
    val texturePalette = rememberButtonTexturePalette(skin, isZTransferDarkTheme(mode))
    CompositionLocalProvider(LocalButtonTexturePalette provides texturePalette) {
        SharedZTransferTheme(mode, skin) {
            val colors = AppTheme.colors
            Box(Modifier.fillMaxSize()) {
                Column(Modifier.fillMaxSize().background(rememberAppBackgroundBrush())
                    .verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    ZMark(Modifier.height(36.dp))
                    Text("共享 UI 组件验收", style = MaterialTheme.typography.headlineMedium, color = colors.onBackground)
                    Text("此页使用已迁移的安卓原组件；仅检查主题、材质、按钮、图标与进度，不连接相机。", color = colors.onSurfaceVariant)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        ThemeMode.entries.forEach { item -> OutlinedButton(onClick = { mode = item }) { Text(item.name) } }
                    }
                    ButtonSkinDisplayOrder.forEach { item ->
                        OutlinedButton(onClick = { skin = item }) { Text(item.name) }
                    }
                    GlassButton(onClick = { buttonActive = !buttonActive; clickCount++ },
                        active = buttonActive, activeOutline = true, textureSeed = 17) {
                        Text("材质按钮 · 点击 $clickCount 次")
                    }
                    GlassButton(onClick = { clickCount++ }, enabled = false, textureSeed = 29) {
                        Text("禁用按钮 · 不应触发点击")
                    }
                    val cardShape = RoundedCornerShape(20.dp)
                    ConnectionCardSurface(shape = cardShape, tint = colors.accentBlue.copy(alpha = 0.018f),
                        modifier = Modifier.fillMaxWidth().connectionCardMaterialFrame(cardShape)) {
                        Row(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            SkinMaterialBadge(accentColor = colors.accentBlue, textureSeed = 31,
                                modifier = Modifier.size(40.dp)) { tint ->
                                Text("STA", color = tint)
                            }
                            Text("连接卡片材质 · 非连接状态", color = colors.onBackground)
                        }
                    }
                    ReleaseCommitWheel(options = listOf("A", "B", "C", "D", "E"), selected = wheelValue,
                        optionLabel = { it }, onValueCommitted = { wheelValue = it }, onDetent = haptics::tick,
                        label = "松手提交拨轮", modifier = Modifier.fillMaxWidth())
                    Text("已提交值：$wheelValue", color = colors.onBackground)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TipLightbulbButton(onClick = { showHelp = !showHelp }, contentDescription = "共享帮助提示",
                            attention = !showHelp, modifier = Modifier.size(44.dp))
                        OutlinedButton(onClick = { fireworks.launch() }) { Text("烟花") }
                        OutlinedButton(onClick = { feedbackEnabled = !feedbackEnabled }) {
                            Text(if (feedbackEnabled) "关闭触感" else "开启触感")
                        }
                    }
                    if (showHelp) TipBubbleContent("共享帮助组件", listOf(
                        TipBubbleItem("拖动仅预览，松手提交；手势被取消时不提交。", questionExplanation = "此说明不执行相机操作。")))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = haptics::success) { Text("成功触感") }
                        OutlinedButton(onClick = haptics::failure) { Text("失败触感") }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = haptics::startProgressiveHold) { Text("渐强") }
                        OutlinedButton(onClick = haptics::cancelProgressiveHold) { Text("取消") }
                        OutlinedButton(onClick = haptics::completeProgressiveHold) { Text("确认") }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                        BroomMark(Modifier.size(28.dp), contentDescription = "清理图标")
                        FilterMark(Modifier.size(28.dp))
                        RemoteMark(Modifier.size(28.dp))
                        BackToTopMark(Modifier.size(28.dp))
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                        TransferStatus.entries.forEach { status ->
                            val (glyph, tint) = statusGlyph(status)
                            Icon(glyph, contentDescription = status.name, tint = tint)
                        }
                    }
                    ControlTileCornerBadge("ISO", colors.onBackground, colors.buttonSurface, colors.onSurfaceVariant,
                        RoundedCornerShape(6.dp), contentPadding = PaddingValues(8.dp))
                    Slider(value = progress, onValueChange = { progress = it })
                    TransferCardComponentProbe()
                    // Key changes deliberately reset the original forward-only progress animator for probing.
                    val smooth = rememberSmoothTransferProgress(progress, progress)
                    LiquidProgressFill(progress = { smooth.value }, waveEligible = true, seedKey = 1,
                        color = colors.accentBlue, modifier = Modifier.fillMaxWidth().height(20.dp).clip(RoundedCornerShape(10.dp)))
                }
                FireworksOverlay(fireworks, feedbackEnabled)
            }
        }
    }
}
