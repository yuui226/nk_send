package com.ztransfer.ui.screen

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import com.ztransfer.ui.theme.AppTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** 激活对话框:显示本机设备码,输入激活码联网激活。成功后短暂显示成功文案自动关闭。 */
@Composable
fun ActivationDialog(onDismiss: () -> Unit) {
    val colors = AppTheme.colors
    val scope = rememberCoroutineScope()
    var input by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<Int?>(null) }        // 文案资源 id
    var errorArg by remember { mutableStateOf("") }              // err_generic 的错误码参数
    var success by remember { mutableStateOf(false) }

    if (success) {
        LaunchedEffect(Unit) { delay(1200); onDismiss() }
    }

    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        containerColor = colors.glassSurfaceHeavy,
        title = { Text(stringResource(R.string.activation_title), color = colors.onBackground) },
        text = {
            Column {
                Text(
                    stringResource(R.string.device_code_label, LicenseManager.displayCode()),
                    style = MaterialTheme.typography.bodyMedium,
                    color = colors.onSurfaceVariant
                )
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = input,
                    // 6 位大写字母(排除 I O);自动转大写、过滤非字母,让用户不必纠结大小写。
                    onValueChange = { raw ->
                        input = raw.uppercase().filter { it in 'A'..'Z' }.take(6)
                        error = null
                    },
                    enabled = !busy && !success,
                    singleLine = true,
                    placeholder = { Text("ABCDEF") },
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(Modifier.height(8.dp))
                when {
                    success -> Text(
                        stringResource(R.string.activation_success),
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.statusConnected
                    )
                    error != null -> Text(
                        if (error == R.string.err_generic) stringResource(R.string.err_generic, errorArg)
                        else stringResource(error!!),
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.accentOrange
                    )
                    else -> Text(
                        stringResource(R.string.activation_privacy),
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.onSurfaceVariant.copy(alpha = 0.7f)
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !busy && !success && input.length == 6,
                onClick = {
                    busy = true; error = null
                    scope.launch {
                        when (val r = LicenseManager.activate(input, BuildConfig.VERSION_NAME)) {
                            LicenseManager.ActivationResult.Success -> success = true
                            LicenseManager.ActivationResult.Unreachable ->
                                error = R.string.err_server_unreachable
                            is LicenseManager.ActivationResult.Rejected -> when (r.code) {
                                "CODE_NOT_FOUND" -> error = R.string.err_code_not_found
                                "CODE_REVOKED" -> error = R.string.err_code_revoked
                                "SLOTS_FULL" -> error = R.string.err_slots_full
                                "RATE_LIMITED" -> error = R.string.err_rate_limited
                                else -> { error = R.string.err_generic; errorArg = r.code }
                            }
                        }
                        busy = false
                    }
                }
            ) {
                Text(
                    stringResource(if (busy) R.string.activating else R.string.activate),
                    color = colors.accentBlue
                )
            }
        },
        dismissButton = {
            TextButton(enabled = !busy, onClick = onDismiss) {
                Text(stringResource(R.string.cancel), color = colors.onSurfaceVariant)
            }
        }
    )
}

/**
 * 付费引导对话框:免费版触限时弹出。[quotaExhausted] 区分"额度用完"与"批量是付费功能"
 * 两种标题;引导路径 = 复制 QQ 群号购买,或直接输入激活码。
 */
@Composable
fun PaywallDialog(
    quotaExhausted: Boolean,
    onDismiss: () -> Unit,
    onEnterCode: () -> Unit
) {
    val colors = AppTheme.colors
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = colors.glassSurfaceHeavy,
        title = {
            Text(
                stringResource(
                    if (quotaExhausted) R.string.paywall_quota_title else R.string.paywall_batch_title
                ),
                color = colors.onBackground
            )
        },
        text = {
            Column {
                Text(
                    stringResource(
                        R.string.paywall_body,
                        LicenseManager.FREE_DAILY_TRANSFER_LIMIT,
                        (LicenseManager.FREE_REMOTE_TRIAL_MS / 60_000L).toInt()
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = colors.onSurfaceVariant
                )
                if (copied) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        stringResource(R.string.qq_group_copied, QQ_GROUP),
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.statusConnected
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onEnterCode) {
                Text(stringResource(R.string.paywall_enter_code), color = colors.accentBlue)
            }
        },
        dismissButton = {
            TextButton(onClick = {
                clipboard.setText(AnnotatedString(QQ_GROUP))
                copied = true
            }) {
                Text(stringResource(R.string.join_qq_group), color = colors.onSurfaceVariant)
            }
        }
    )
}
