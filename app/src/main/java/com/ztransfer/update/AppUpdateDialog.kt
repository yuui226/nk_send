package com.ztransfer.update

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import com.ztransfer.ui.screen.GlassButton
import com.ztransfer.ui.screen.GlassSurface
import com.ztransfer.ui.theme.AppTheme
import java.util.Locale

/** 全局更新弹窗。硬更新不可关闭；自动更新失败时转为浏览器手动下载。 */
@Composable
fun AppUpdateHost(
    cameraUsesWifi: Boolean
) {
    val state by AppUpdateManager.state.collectAsState()
    LaunchedEffect(cameraUsesWifi) {
        AppUpdateManager.setCameraApConnected(cameraUsesWifi)
    }
    val info = state.infoOrNull() ?: return
    val required = info.isRequired(BuildConfig.VERSION_CODE)
    val context = LocalContext.current
    val activity = context.findActivity() ?: return
    var installerStarted by remember(info.versionCode) { mutableStateOf(false) }
    var inlineHint by remember(info.versionCode) { mutableStateOf<String?>(null) }
    val fixedUrl = stringResource(R.string.update_fixed_download_url)
    var manualBrowserChosen by remember { mutableStateOf(false) }
    val disconnectCameraHint = stringResource(R.string.update_disconnect_camera_wifi)

    val unknownSourcesLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) {
        val ready = AppUpdateManager.state.value as? AppUpdateManager.UiState.Ready
        if (ready != null && !manualBrowserChosen && AppUpdateManager.unknownSourcesIntent() == null) {
            AppUpdateManager.launchInstaller(activity, ready)
        }
    }

    // Keep automatic installation, unless the user explicitly switches to browser download.
    LaunchedEffect(state) {
        if (manualBrowserChosen) return@LaunchedEffect
        val ready = state as? AppUpdateManager.UiState.Ready ?: return@LaunchedEffect
        if (installerStarted) return@LaunchedEffect
        installerStarted = true
        val permission = AppUpdateManager.unknownSourcesIntent()
        if (permission != null) unknownSourcesLauncher.launch(permission)
        else AppUpdateManager.launchInstaller(activity, ready)
    }

    fun startDownload() {
        if (cameraUsesWifi) {
            inlineHint = disconnectCameraHint
            return
        }
        inlineHint = null
        manualBrowserChosen = false
        AppUpdateManager.download(info)
    }

    fun openFallbackDownload() {
        if (cameraUsesWifi) {
            inlineHint = disconnectCameraHint
            return
        }
        inlineHint = null
        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(fixedUrl))) }
            .onSuccess {
                manualBrowserChosen = true
                // Optional downloads can stop; required updates keep their gate but do not
                // interrupt the browser by automatically launching the installer afterwards.
                if (!required) AppUpdateManager.cancelDownload(info)
            }
            .onFailure { inlineHint = context.getString(R.string.update_browser_unavailable) }
    }

    val title = if (info.versionCode == 0) {
        stringResource(if (state is AppUpdateManager.UiState.Failed) R.string.update_check_failed else R.string.checking_update)
    } else if (required) {
        stringResource(R.string.update_required_title)
    } else {
        stringResource(R.string.update_available_title)
    }
    val colors = AppTheme.colors
    val panelShape = RoundedCornerShape(22.dp)
    val showStatus = inlineHint != null ||
        state is AppUpdateManager.UiState.Resolving ||
        state is AppUpdateManager.UiState.Downloading ||
        state is AppUpdateManager.UiState.Verifying ||
        state is AppUpdateManager.UiState.Failed

    Dialog(
        onDismissRequest = {
            if (required) return@Dialog
            when (state) {
                is AppUpdateManager.UiState.Downloading -> AppUpdateManager.cancelDownload(info)
                is AppUpdateManager.UiState.Available,
                is AppUpdateManager.UiState.Failed -> AppUpdateManager.postpone(info)
                else -> Unit
            }
        },
        properties = DialogProperties(
            dismissOnBackPress = !required,
            dismissOnClickOutside = !required
        )
    ) {
        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = panelShape,
            color = colors.glassSurfaceHeavy,
            border = BorderStroke(1.dp, colors.glassPanelBorder),
            shadowElevation = 10.dp,
            tonalElevation = 0.dp
        ) {
            Box {
                Box(
                    Modifier
                        .matchParentSize()
                        .background(
                            Brush.verticalGradient(
                                listOf(colors.glassSheen, Color.Transparent)
                            )
                        )
                )
                Column(Modifier.padding(20.dp)) {
                    Text(
                        title,
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = colors.onBackground
                    )
                    Spacer(Modifier.height(14.dp))
                    if (info.versionName.isNotBlank()) {
                        Text(
                            stringResource(R.string.update_version, info.versionName),
                            style = MaterialTheme.typography.bodyLarge,
                            color = colors.onBackground
                        )
                    }
                    if (info.sizeBytes > 0) {
                        Spacer(Modifier.height(2.dp))
                        Text(
                            stringResource(R.string.update_size, formatSize(info.sizeBytes)),
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant
                        )
                    }
                    if (info.notes.isNotBlank()) {
                        Spacer(Modifier.height(12.dp))
                        Text(
                            info.notes,
                            style = MaterialTheme.typography.bodyMedium,
                            color = colors.onBackground
                        )
                    }
                    if (showStatus) {
                        Spacer(Modifier.height(14.dp))
                        GlassSurface(
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(14.dp),
                            panel = true,
                            tint = if (inlineHint != null || state is AppUpdateManager.UiState.Failed) {
                                colors.statusError.copy(alpha = 0.08f)
                            } else {
                                Color.Transparent
                            }
                        ) {
                            Column(Modifier.padding(horizontal = 14.dp, vertical = 11.dp)) {
                                if (inlineHint != null) {
                                    Text(
                                        inlineHint!!,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = colors.statusError
                                    )
                                } else {
                                    when (val current = state) {
                                        is AppUpdateManager.UiState.Resolving -> Text(
                                            stringResource(R.string.update_resolving),
                                            style = MaterialTheme.typography.bodySmall,
                                            color = colors.onSurfaceVariant
                                        )
                                        is AppUpdateManager.UiState.Downloading -> {
                                            val progress = current.progress
                                            if (progress == null) {
                                                LinearProgressIndicator(
                                                    modifier = Modifier.fillMaxWidth(),
                                                    color = colors.accentBlue,
                                                    trackColor = colors.glassPanelBorder
                                                )
                                            } else {
                                                LinearProgressIndicator(
                                                    progress = progress / 100f,
                                                    modifier = Modifier.fillMaxWidth(),
                                                    color = colors.accentBlue,
                                                    trackColor = colors.glassPanelBorder
                                                )
                                            }
                                            Spacer(Modifier.height(8.dp))
                                            Text(
                                                if (progress == null) {
                                                    stringResource(R.string.update_downloading)
                                                } else {
                                                    stringResource(
                                                        R.string.update_downloading_percent,
                                                        progress
                                                    )
                                                },
                                                style = MaterialTheme.typography.bodySmall,
                                                color = colors.onSurfaceVariant
                                            )
                                        }
                                        is AppUpdateManager.UiState.Verifying -> Text(
                                            stringResource(R.string.update_verifying),
                                            style = MaterialTheme.typography.bodySmall,
                                            color = colors.onSurfaceVariant
                                        )
                                        is AppUpdateManager.UiState.Failed -> {
                                            val failure = failureText(current.failure)
                                            Text(
                                                failure,
                                                style = MaterialTheme.typography.bodySmall,
                                                color = colors.statusError
                                            )
                                        }
                                        else -> Unit
                                    }
                                }
                            }
                        }
                    }

                    Spacer(Modifier.height(18.dp))
                    when (val current = state) {
                        is AppUpdateManager.UiState.Available -> {
                            if (required) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.End
                                ) {
                                    UpdateGlassButton(
                                        label = stringResource(R.string.update_now),
                                        onClick = ::startDownload,
                                        prominent = true
                                    )
                                }
                            } else {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    UpdateGlassButton(
                                        label = stringResource(R.string.update_ignore_version),
                                        onClick = { AppUpdateManager.ignoreVersion(info) },
                                        modifier = Modifier.weight(1f),
                                        centerContent = true
                                    )
                                    UpdateGlassButton(
                                        label = stringResource(R.string.update_later),
                                        onClick = { AppUpdateManager.postpone(info) },
                                        modifier = Modifier.weight(1f),
                                        centerContent = true
                                    )
                                    UpdateGlassButton(
                                        label = stringResource(R.string.update_now),
                                        onClick = ::startDownload,
                                        modifier = Modifier.weight(1f),
                                        prominent = true,
                                        centerContent = true
                                    )
                                }
                            }
                        }
                        is AppUpdateManager.UiState.Ready -> Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.End
                        ) {
                            UpdateGlassButton(
                                label = stringResource(R.string.update_install),
                                onClick = {
                                    manualBrowserChosen = false
                                    val permission = AppUpdateManager.unknownSourcesIntent()
                                    if (permission != null) {
                                        unknownSourcesLauncher.launch(permission)
                                    } else {
                                        AppUpdateManager.launchInstaller(activity, current)
                                    }
                                },
                                prominent = true
                            )
                        }
                        else -> Unit
                    }
                    if (state is AppUpdateManager.UiState.Downloading ||
                        state is AppUpdateManager.UiState.Verifying ||
                        state is AppUpdateManager.UiState.Ready ||
                        state is AppUpdateManager.UiState.Failed) {
                        if (state is AppUpdateManager.UiState.Ready) Spacer(Modifier.height(8.dp))
                        UpdateManualDownloadActions(onBrowserDownload = ::openFallbackDownload)
                    }
                }
            }
        }
    }
}

/** The same two exits remain available throughout download, verification and installation. */
@Composable
private fun UpdateManualDownloadActions(onBrowserDownload: () -> Unit) {
    val context = LocalContext.current
    val url = stringResource(R.string.update_fixed_download_url)
    var copied by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        UpdateGlassButton(
            label = stringResource(if (copied) R.string.code_copied else R.string.update_copy_download_link),
            onClick = {
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText("ZTransfer download", url))
                copied = true
            },
            modifier = Modifier.weight(1f), centerContent = true,
        )
        UpdateGlassButton(
            label = stringResource(R.string.update_browser_download),
            onClick = onBrowserDownload,
            modifier = Modifier.weight(1f), centerContent = true,
        )
    }
}

@Composable
private fun UpdateGlassButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    prominent: Boolean = false,
    centerContent: Boolean = false
) {
    val colors = AppTheme.colors
    GlassButton(
        onClick = onClick,
        modifier = modifier.height(40.dp),
        shape = RoundedCornerShape(14.dp),
        contentPadding = PaddingValues(horizontal = 11.dp, vertical = 9.dp),
        panel = !prominent,
        active = prominent,
        activeColor = colors.accentBlue,
        showSheen = false
    ) {
        Text(
            label,
            modifier = if (centerContent) Modifier.fillMaxWidth() else Modifier,
            textAlign = if (centerContent) TextAlign.Center else TextAlign.Start,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.labelMedium,
            color = colors.onBackground
        )
    }
}

@Composable
private fun failureText(failure: AppUpdateManager.Failure): String = stringResource(
    when (failure) {
        AppUpdateManager.Failure.RESOLVE -> R.string.update_error_resolve
        AppUpdateManager.Failure.DOWNLOAD -> R.string.update_error_download
        AppUpdateManager.Failure.INVALID_APK -> R.string.update_error_invalid_apk
        AppUpdateManager.Failure.INSTALLER_UNAVAILABLE -> R.string.update_error_installer
    }
)

private fun AppUpdateManager.UiState.infoOrNull(): LicenseManager.UpdateInfo? = when (this) {
    is AppUpdateManager.UiState.Available -> info
    is AppUpdateManager.UiState.Resolving -> info
    is AppUpdateManager.UiState.Downloading -> info
    is AppUpdateManager.UiState.Verifying -> info
    is AppUpdateManager.UiState.Ready -> info
    is AppUpdateManager.UiState.Failed -> info
    else -> null
}

private fun formatSize(bytes: Long): String = String.format(Locale.getDefault(), "%.1f MB", bytes / 1_048_576.0)

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
