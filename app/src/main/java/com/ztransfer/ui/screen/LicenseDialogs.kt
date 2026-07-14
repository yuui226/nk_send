package com.ztransfer.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import androidx.compose.ui.text.font.FontWeight
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

// 高级版列/定价的金色文字(与 ProBadgeButton 的金渐变同族,压深一档保证浅色玻璃上可读)。
private val ProGold = Color(0xFFE09B2D)
// 对比表的免费/高级版两个值列的定宽(功能名占弹性剩余宽度)。
private val CompareColWidth = 64.dp

/**
 * 高级版介绍对话框("解锁高级版"徽标打开,设置面板与传输页共用):
 * 免费/高级版三列对比表(窄弹窗适配) + 金色"解锁"按钮复制 QQ 号购买。
 * [showEnterCode] 控制"输入激活码"入口(6 位限长在 ActivationDialog 内):
 * 传输页开;设置面板关——设置只在连着相机 Wi-Fi 时可达,无外网激活必失败。
 * 触限处只弹轻量提示引导到这里,不直接打断弹窗。
 */
@Composable
fun ProDialog(onDismiss: () -> Unit, showEnterCode: Boolean = false) {
    val colors = AppTheme.colors
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }
    // 激活输入框叠在本弹窗之上;关闭后回到本弹窗(激活成功后由用户自行关闭)。
    var showActivation by remember { mutableStateOf(false) }
    if (showActivation) {
        ActivationDialog(onDismiss = { showActivation = false })
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = colors.glassSurfaceHeavy,
        title = { Text(stringResource(R.string.pro_version), color = colors.onBackground) },
        text = {
            Column {
                // 表头:功能列留白,免费/高级版两列与行内值列同宽对齐。
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Spacer(Modifier.weight(1f))
                    Text(
                        stringResource(R.string.tier_free),
                        style = MaterialTheme.typography.labelMedium,
                        color = colors.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.width(CompareColWidth)
                    )
                    Text(
                        stringResource(R.string.pro_version),
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.Bold,
                        color = ProGold,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.width(CompareColWidth)
                    )
                }
                Spacer(Modifier.height(4.dp))
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(1.dp)
                        .background(colors.onSurfaceVariant.copy(alpha = 0.2f))
                )
                CompareRow(
                    stringResource(R.string.compare_transfer),
                    stringResource(R.string.compare_transfer_free, LicenseManager.FREE_DAILY_TRANSFER_LIMIT),
                    stringResource(R.string.compare_unlimited)
                )
                CompareRow(stringResource(R.string.compare_batch), "—", "✓")
                CompareRow(
                    stringResource(R.string.compare_remote),
                    stringResource(
                        R.string.compare_remote_free,
                        (LicenseManager.FREE_REMOTE_TRIAL_MS / 60_000L).toInt()
                    ),
                    stringResource(R.string.compare_no_limit)
                )
                // 卖点行:买断/无订阅是相对订阅制竞品的核心差异,常驻表格下方。
                Spacer(Modifier.height(8.dp))
                Text(
                    stringResource(R.string.pro_perks),
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.onSurfaceVariant
                )
                // 定价行:PRO_PRICE 留空（定价未定）时整行不显示。
                if (PRO_PRICE.isNotEmpty()) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        stringResource(R.string.pro_price_line, PRO_PRICE),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = ProGold
                    )
                }
                if (copied) {
                    Spacer(Modifier.height(10.dp))
                    Text(
                        stringResource(R.string.qq_group_copied, QQ_NUMBER),
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.statusConnected
                    )
                }
            }
        },
        confirmButton = {
            // 金色闪亮"解锁"按钮(与入口徽标同款):点击复制 QQ 号,提示加号购买。
            ProBadgeButton(
                label = stringResource(R.string.unlock),
                onClick = {
                    clipboard.setText(AnnotatedString(QQ_NUMBER))
                    copied = true
                }
            )
        },
        dismissButton = {
            if (showEnterCode) {
                // 已购码用户的入口:呼出激活输入框(输入限 6 位大写字母,详见 ActivationDialog)。
                TextButton(onClick = { showActivation = true }) {
                    Text(stringResource(R.string.enter_code), color = colors.accentBlue)
                }
            } else {
                TextButton(onClick = onDismiss) {
                    Text(stringResource(R.string.cancel), color = colors.onSurfaceVariant)
                }
            }
        }
    )
}

/** 对比表行:功能名弹性列 + 免费/高级版两个定宽值列(高级版列金色加粗)。 */
@Composable
private fun CompareRow(name: String, free: String, pro: String) {
    val colors = AppTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.padding(vertical = 6.dp)
    ) {
        Text(
            name,
            style = MaterialTheme.typography.bodySmall,
            color = colors.onSurfaceVariant,
            modifier = Modifier.weight(1f)
        )
        Text(
            free,
            style = MaterialTheme.typography.bodySmall,
            color = colors.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.width(CompareColWidth)
        )
        Text(
            pro,
            style = MaterialTheme.typography.bodySmall,
            fontWeight = FontWeight.SemiBold,
            color = ProGold,
            textAlign = TextAlign.Center,
            modifier = Modifier.width(CompareColWidth)
        )
    }
}
