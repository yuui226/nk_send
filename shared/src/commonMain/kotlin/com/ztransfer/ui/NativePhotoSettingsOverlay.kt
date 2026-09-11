package com.ztransfer.ui

import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.screen.*
import com.ztransfer.ui.theme.AppTheme

/** Product settings adapter: uses the original shared controls and the existing preference owners. */
@Composable
internal fun NativePhotoSettingsOverlay(model: NativeFilesPageModel, layout: NativeBrowseLayout,
    text: NativeSettingsPageText, anchor: Rect, appearance: NativeAppearanceModel, onDismiss: () -> Unit) {
    val appearanceState by appearance.state.collectAsState()
    val transfers by model.transferPreferences.collectAsState()
    val automatic by model.automaticTransfer.state.collectAsState()
    var confirmTransferReset by remember(model) { mutableStateOf(false) }
    var confirmSandbox by remember(model) { mutableStateOf(false) }
    val recoveryText = nativeTransferRecoveryText(appearanceState.resolvedLanguage)
    val directory by model.directory.state.collectAsState()
    val openingAnchor = remember { anchor }
    val density = LocalDensity.current
    val panelTop = with(density) { openingAnchor.bottom.toDp() } + 8.dp
    SharedAnchorPopup(anchorBounds = openingAnchor, onDismiss = onDismiss,
        panelModifier = Modifier.padding(start = 12.dp, end = 12.dp, top = panelTop).navigationBarsPadding().fillMaxWidth(),
        animateScale = false,
    ) { close ->
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(text.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold,
                    color = AppTheme.colors.onBackground)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = close, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Default.Close, text.close, tint = AppTheme.colors.onSurfaceVariant)
                }
            }
            if (model.canOpenPhotoEffects()) {
                TextButton(onClick = { model.openPhotoEffects(); close() }) {
                    Text(nativeActionText(appearanceState.resolvedLanguage, "照片效果", "Photo effects", "照片效果"))
                }
            }
            Spacer(Modifier.height(14.dp))
            SharedPhotoListSettingsCard(layout.columns, layout.collapseBursts, layout.tapToPreview, appearanceState.hapticsEnabled, text,
                onColumns = { model.changeLayout(it, model.layout.value.collapseBursts) },
                onCollapseBursts = { model.changeLayout(model.layout.value.columns, it) },
                onTapToPreview = model::setTapToPreview)
            Spacer(Modifier.height(14.dp))
            // All three controls use the same preferences document and existing transfer queue.
            SharedSettingsCard {
                SharedTransferDirectoryHeader(directory.description?.let { NativeTransferMessages.render(it, appearanceState.resolvedLanguage) }, false, text, model.directory::choose)
                TextButton(enabled = !directory.selecting, onClick = { confirmSandbox = true }) {
                    Text(nativeActionText(appearanceState.resolvedLanguage, "切回应用目录 / 修复保存目标", "Use app storage / repair destination", "切回應用程式目錄 / 修復儲存目標"))
                }
                if (directory.selecting) LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                directory.message?.let {
                    Text(NativeTransferMessages.render(it, appearanceState.resolvedLanguage), color = AppTheme.colors.accentOrange, style = MaterialTheme.typography.bodySmall)
                }
                SharedCardDivider()
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                    SharedBooleanSettingsWheel(label = text.label(SettingsTextKey.organize_transfers_by_date),
                        checked = transfers.organizeByDate, onCheckedChange = model::setOrganizeByDate,
                        hapticsEnabled = appearanceState.hapticsEnabled, modifier = Modifier.weight(1f), text = text)
                    SharedBooleanSettingsWheel(label = text.label(SettingsTextKey.defer_transfer_start),
                        checked = transfers.deferStart, onCheckedChange = model::setDeferStart,
                        hapticsEnabled = appearanceState.hapticsEnabled, modifier = Modifier.weight(1f), text = text)
                }
                if (automatic.available) {
                    SharedBooleanSettingsWheel(label = text.label(SettingsTextKey.auto_transfer_new_media),
                        checked = automatic.enabled, onCheckedChange = model.automaticTransfer::setEnabled,
                        enabled = !automatic.failed && (automatic.canEnable || automatic.enabled),
                        hapticsEnabled = appearanceState.hapticsEnabled, text = text)
                    if (!automatic.canEnable) Text(text.label(SettingsTextKey.dir_please_set),
                        color = AppTheme.colors.accentOrange, style = MaterialTheme.typography.bodySmall)
                    if (automatic.failed) TextButton(onClick = { confirmTransferReset = true }) {
                        Text(recoveryText.reset, color = AppTheme.colors.accentOrange)
                    }
                }
            }
            Spacer(Modifier.height(14.dp))
            SharedAppearanceSettingsCard(appearanceState.theme, appearanceState.language, "system", appearanceState.skin,
                appearanceState.hapticsEnabled, appearanceState.keepScreenOn, text,
                onTheme = { appearance.setThemeName(it.name) }, onLanguage = appearance::setLanguage,
                onSkin = { appearance.setSkinName(it.name) }, onHaptics = appearance::setHapticsEnabled,
                onKeepScreenOn = appearance::setKeepScreenOn, close = close)
            Spacer(Modifier.height(14.dp))
            NativeProductInformation(appearance, model)
        }
    }
    if (confirmSandbox) AlertDialog(onDismissRequest = { confirmSandbox = false },
        title = { Text(nativeActionText(appearanceState.resolvedLanguage, "使用应用目录？", "Use app storage?", "使用應用程式目錄？")) },
        text = { Text(nativeActionText(appearanceState.resolvedLanguage, "只在队列暂停且当前文件结束后切换。后续任务保存到应用目录；原目录文件和授权保留。未知保存目标偏好将备份后重置。", "Switch only while idle after the current file ends. Subsequent tasks use app storage; existing files and grants remain. Unknown destination preferences are backed up and reset.", "只在佇列暫停且目前檔案結束後切換。後續任務存至應用程式目錄；原目錄檔案與授權保留。未知儲存目標偏好將備份後重置。")) },
        confirmButton = { TextButton(onClick = { confirmSandbox = false; model.directory.useSandboxAfterConfirmation() }) { Text(recoveryText.reset) } },
        dismissButton = { TextButton(onClick = { confirmSandbox = false }) { Text(recoveryText.cancel) } })
    if (confirmTransferReset) AlertDialog(onDismissRequest = { confirmTransferReset = false },
        title = { Text(recoveryText.title) }, text = { Text(recoveryText.message) },
        confirmButton = { TextButton(onClick = {
            confirmTransferReset = false
            if (model.automaticTransfer.resetAfterConfirmation()) model.reloadTransferPreferences()
        }) { Text(recoveryText.reset) } },
        dismissButton = { TextButton(onClick = { confirmTransferReset = false }) { Text(recoveryText.cancel) } })
}
