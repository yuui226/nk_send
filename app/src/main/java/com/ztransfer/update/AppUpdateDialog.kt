package com.ztransfer.update

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import java.util.Locale

/** 全局更新弹窗。硬更新不可关闭；自动更新失败时转为蓝奏云手动更新。 */
@Composable
fun AppUpdateHost(
    cameraUsesWifi: Boolean
) {
    val state by AppUpdateManager.state.collectAsState()
    val info = state.infoOrNull() ?: return
    val required = info.isRequired(BuildConfig.VERSION_CODE)
    val context = LocalContext.current
    val activity = context.findActivity() ?: return
    var installerStarted by remember(info.versionCode) { mutableStateOf(false) }
    val manualCopiedHint = stringResource(R.string.update_manual_copied)

    val unknownSourcesLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) {
        val ready = AppUpdateManager.state.value as? AppUpdateManager.UiState.Ready
        if (ready != null && AppUpdateManager.unknownSourcesIntent() == null) {
            AppUpdateManager.launchInstaller(activity, ready)
        }
    }

    fun copyManualUpdateInfo() {
        val text = buildString {
            append(info.fallbackUrl)
            if (info.fallbackPassword.isNotBlank()) {
                append("\n密码:")
                append(info.fallbackPassword)
            }
        }
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("ZTransfer update", text))
    }

    // 自动更新失败时复制手动更新信息；校验完成后自动拉起系统安装流程。
    LaunchedEffect(state) {
        val failed = state as? AppUpdateManager.UiState.Failed
        if (failed != null && info.fallbackUrl.isNotBlank()) {
            copyManualUpdateInfo()
            return@LaunchedEffect
        }
        val ready = state as? AppUpdateManager.UiState.Ready ?: return@LaunchedEffect
        if (installerStarted) return@LaunchedEffect
        installerStarted = true
        val permission = AppUpdateManager.unknownSourcesIntent()
        if (permission != null) unknownSourcesLauncher.launch(permission)
        else AppUpdateManager.launchInstaller(activity, ready)
    }

    fun startDownload() {
        if (cameraUsesWifi) {
            Toast.makeText(context, R.string.update_disconnect_camera_wifi, Toast.LENGTH_SHORT).show()
            return
        }
        AppUpdateManager.download(info)
    }

    fun openFallbackDownload() {
        if (info.fallbackUrl.isBlank()) return
        if (cameraUsesWifi) {
            Toast.makeText(context, R.string.update_disconnect_camera_wifi, Toast.LENGTH_SHORT).show()
            return
        }
        copyManualUpdateInfo()
        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(info.fallbackUrl))) }
    }

    val title = if (required) {
        stringResource(R.string.update_required_title)
    } else {
        stringResource(R.string.update_available_title)
    }

    AlertDialog(
        onDismissRequest = {
            if (!required && (state is AppUpdateManager.UiState.Available || state is AppUpdateManager.UiState.Failed)) {
                AppUpdateManager.postpone(info)
            }
        },
        properties = DialogProperties(
            dismissOnBackPress = !required,
            dismissOnClickOutside = !required
        ),
        title = { Text(title) },
        text = {
            Column {
                Text(stringResource(R.string.update_version, info.versionName))
                if (info.sizeBytes > 0) {
                    Text(
                        stringResource(R.string.update_size, formatSize(info.sizeBytes)),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                if (info.notes.isNotBlank()) {
                    Spacer(Modifier.height(12.dp))
                    Text(info.notes)
                }
                Spacer(Modifier.height(12.dp))
                when (val current = state) {
                    is AppUpdateManager.UiState.Available -> {
                        if (!required) {
                            TextButton(onClick = { AppUpdateManager.ignoreVersion(info) }) {
                                Text(stringResource(R.string.update_ignore_version))
                            }
                        }
                    }
                    is AppUpdateManager.UiState.Resolving -> Text(stringResource(R.string.update_resolving))
                    is AppUpdateManager.UiState.Downloading -> {
                        val p = current.progress
                        if (p == null) LinearProgressIndicator(Modifier.fillMaxWidth())
                        else LinearProgressIndicator(progress = p / 100f, modifier = Modifier.fillMaxWidth())
                        Spacer(Modifier.height(8.dp))
                        Text(if (p == null) stringResource(R.string.update_downloading) else stringResource(R.string.update_downloading_percent, p))
                    }
                    is AppUpdateManager.UiState.Verifying -> Text(stringResource(R.string.update_verifying))
                    is AppUpdateManager.UiState.Ready -> Text(stringResource(R.string.update_ready))
                    is AppUpdateManager.UiState.Failed -> {
                        val manualUpdate = info.fallbackUrl.isNotBlank()
                        Text(
                            if (manualUpdate) manualCopiedHint else failureText(current.failure),
                            color = MaterialTheme.colorScheme.error
                        )
                    }
                    else -> Unit
                }
            }
        },
        confirmButton = {
            when (val current = state) {
                is AppUpdateManager.UiState.Available -> TextButton(
                    onClick = { startDownload() }
                ) { Text(stringResource(R.string.update_now)) }
                is AppUpdateManager.UiState.Failed -> when {
                    info.fallbackUrl.isNotBlank() -> TextButton(onClick = { openFallbackDownload() }) {
                        Text(stringResource(R.string.update_open_download_page))
                    }
                    current.failure != AppUpdateManager.Failure.INSTALLER_UNAVAILABLE ->
                        TextButton(onClick = { startDownload() }) {
                            Text(stringResource(R.string.retry))
                        }
                }
                is AppUpdateManager.UiState.Ready -> TextButton(onClick = {
                    val permission = AppUpdateManager.unknownSourcesIntent()
                    if (permission != null) unknownSourcesLauncher.launch(permission)
                    else AppUpdateManager.launchInstaller(activity, current)
                }) { Text(stringResource(R.string.update_install)) }
                else -> Unit
            }
        },
        dismissButton = {
            if (!required) {
                when (state) {
                    is AppUpdateManager.UiState.Available,
                    is AppUpdateManager.UiState.Failed -> TextButton(onClick = { AppUpdateManager.postpone(info) }) {
                        Text(stringResource(R.string.update_later))
                    }
                    is AppUpdateManager.UiState.Downloading -> TextButton(onClick = { AppUpdateManager.cancelDownload(info) }) {
                        Text(stringResource(R.string.cancel))
                    }
                    else -> Unit
                }
            }
        }
    )
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
