package com.ztransfer.ui.screen

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.WorkspacePremium
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import androidx.compose.ui.text.font.FontWeight
import com.ztransfer.ui.theme.AppTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

// 高级版列/定价的金色文字(与 ProBadgeButton 的金渐变同族,压深一档保证浅色玻璃上可读)。
private val ProGold = Color(0xFFE09B2D)
// 对比表的免费/高级版两个值列的定宽(功能名占弹性剩余宽度)。
private val CompareColWidth = 64.dp

/**
 * 高级版介绍对话框("解锁高级版"徽标打开,连接页与设置面板共用):
 * 自定义毛玻璃面板(与设置/筛选面板同一玻璃语言,不用 M3 AlertDialog 原生样式)——
 * 金徽章头部(标题 + 卖点副标语 + 右上关闭) → 玻璃内卡对比表 → 定价行 →
 * 全宽金色"立即购买"大按钮(拉起支付购买流程) → 底部"输入激活码/联系客服"同规格对齐。
 * [showEnterCode] 控制"输入激活码"入口(点击在面板内向下展开内联激活区,不叠第二层弹窗):
 * 仅连接页开——彼时尚未连相机热点,多半还有外网;其余入口(设置面板)关,
 * 连着相机 Wi-Fi 无外网,在线激活必失败。购买同理需要外网,但入口不藏:
 * 下单失败的报错文案会引导先断开相机 Wi-Fi。
 * 触限处只弹轻量提示引导到这里,不直接打断弹窗。
 */
@Composable
fun ProDialog(onDismiss: () -> Unit, showEnterCode: Boolean = false, onCelebrate: () -> Unit = {}) {
    val colors = AppTheme.colors
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()
    var copied by remember { mutableStateOf(false) }
    // 购买流程叠在本弹窗之上;关闭后回到本弹窗(成功后由用户自行关闭)。
    var showPurchase by remember { mutableStateOf(false) }
    if (showPurchase) {
        PurchaseDialog(
            onDismiss = { showPurchase = false },
            // 购买+激活成功:关掉购买弹窗与本弹窗,再放烟花(烟花在页面顶层,须先关弹窗才可见)。
            onCelebrate = { showPurchase = false; onDismiss(); onCelebrate() }
        )
    }
    // 内联激活区状态:点"输入激活码"展开;成功后短暂显示成功文案、自动关闭整个弹窗。
    var codeMode by remember { mutableStateOf(false) }
    var input by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<Int?>(null) }        // 文案资源 id
    var errorArg by remember { mutableStateOf("") }              // err_generic 的错误码参数
    var success by remember { mutableStateOf(false) }
    // 恢复已购授权(重装后本地无码时按指纹找回)
    var restoring by remember { mutableStateOf(false) }
    var restoreMsg by remember { mutableStateOf<Int?>(null) }
    // 内联激活成功 / 恢复授权成功:短暂显示成功后关闭本弹窗并放烟花庆祝。
    if (success) {
        LaunchedEffect(Unit) { delay(1200); onDismiss(); onCelebrate() }
    }

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(22.dp),
            color = colors.glassSurfaceHeavy,
            border = BorderStroke(1.dp, colors.glassPanelBorder),
            tonalElevation = 6.dp
        ) {
            Box {
                // 自上而下淡出的高光叠层，与设置/筛选面板同款毛玻璃质感。
                Box(
                    Modifier
                        .matchParentSize()
                        .background(Brush.verticalGradient(listOf(colors.glassSheen, Color.Transparent)))
                )
                Column(Modifier.padding(20.dp)) {
                    // ---- 头部：金徽章 + 标题/卖点副标语 + 右上关闭 ----
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            modifier = Modifier
                                .size(42.dp)
                                .clip(CircleShape)
                                .background(ProGold.copy(alpha = 0.16f)),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                Icons.Default.WorkspacePremium,
                                contentDescription = null,
                                tint = ProGold,
                                modifier = Modifier.size(24.dp)
                            )
                        }
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(
                                stringResource(R.string.pro_version),
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.Bold,
                                color = colors.onBackground
                            )
                            Text(
                                stringResource(R.string.pro_perks),
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.onSurfaceVariant
                            )
                        }
                        IconButton(onClick = onDismiss, modifier = Modifier.size(32.dp)) {
                            Icon(Icons.Default.Close, contentDescription = null, tint = colors.onSurfaceVariant)
                        }
                    }

                    Spacer(Modifier.height(16.dp))

                    // ---- 对比表：玻璃内卡承载（与设置分区卡片同族），表头 + 三行 ----
                    val cardShape = RoundedCornerShape(14.dp)
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .clip(cardShape)
                            .background(colors.onBackground.copy(alpha = 0.04f))
                            .border(1.dp, colors.glassPanelBorder, cardShape)
                            .padding(horizontal = 14.dp, vertical = 10.dp)
                    ) {
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
                        Spacer(Modifier.height(6.dp))
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .height(1.dp)
                                .background(colors.glassPanelBorder)
                        )
                        CompareRow(
                            stringResource(R.string.compare_transfer),
                            stringResource(R.string.compare_transfer_free, LicenseManager.FREE_DAILY_TRANSFER_LIMIT),
                            stringResource(R.string.compare_unlimited)
                        )
                        CompareRow(
                            stringResource(R.string.compare_filesize),
                            stringResource(
                                R.string.compare_filesize_free,
                                LicenseManager.FREE_MAX_FILE_BYTES / (1024 * 1024)
                            ),
                            stringResource(R.string.compare_unlimited)
                        )
                        CompareRow(
                            stringResource(R.string.compare_remote),
                            stringResource(
                                R.string.compare_remote_free,
                                (LicenseManager.FREE_REMOTE_DAILY_MS / 60_000L).toInt()
                            ),
                            stringResource(R.string.compare_no_limit)
                        )
                    }

                    // 定价促销区:红色"限时特惠"角标 + 大号金色现价 + 划线原价——
                    // "现在买最便宜"的经典促销排布。PRO_PRICE 留空整区不显示;
                    // PRO_PRICE_ORIGINAL 留空则退化为单一价格(无角标无划线)。
                    if (PRO_PRICE.isNotEmpty()) {
                        Spacer(Modifier.height(14.dp))
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.Center,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            if (PRO_PRICE_ORIGINAL.isNotEmpty()) {
                                Surface(
                                    shape = RoundedCornerShape(6.dp),
                                    color = Color(0xFFE53935)
                                ) {
                                    Text(
                                        stringResource(R.string.price_promo_tag),
                                        style = MaterialTheme.typography.labelSmall,
                                        fontWeight = FontWeight.Bold,
                                        color = Color.White,
                                        modifier = Modifier.padding(horizontal = 7.dp, vertical = 3.dp)
                                    )
                                }
                                Spacer(Modifier.width(10.dp))
                            }
                            Text(
                                PRO_PRICE,
                                style = MaterialTheme.typography.headlineSmall,
                                fontWeight = FontWeight.Bold,
                                color = ProGold
                            )
                            if (PRO_PRICE_ORIGINAL.isNotEmpty()) {
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    PRO_PRICE_ORIGINAL,
                                    style = MaterialTheme.typography.bodyMedium,
                                    textDecoration = TextDecoration.LineThrough,
                                    color = colors.onSurfaceVariant
                                )
                            }
                        }
                    }

                    Spacer(Modifier.height(18.dp))

                    // ---- 主行动：全宽金色"立即购买"（与入口徽标同款扫光），拉起支付流程 ----
                    ProBadgeButton(
                        label = stringResource(R.string.buy_now),
                        onClick = { showPurchase = true },
                        modifier = Modifier.fillMaxWidth(),
                        big = true
                    )

                    Spacer(Modifier.height(6.dp))

                    // ---- 次级行动：输入激活码（仅连接页）居左 / 联系客服居右，同规格 TextButton 对齐 ----
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        if (showEnterCode) {
                            // 已购码用户的入口:在面板内向下展开内联激活区(再点收起)。
                            TextButton(onClick = { codeMode = !codeMode }) {
                                Text(
                                    stringResource(R.string.enter_code),
                                    style = MaterialTheme.typography.labelMedium,
                                    color = colors.accentBlue
                                )
                            }
                        }
                        Spacer(Modifier.weight(1f))
                        // 人工兜底入口:复制客服 QQ(支付异常/换绑等场景)。
                        TextButton(onClick = {
                            clipboard.setText(AnnotatedString(QQ_NUMBER))
                            copied = true
                        }) {
                            Text(
                                if (copied) stringResource(R.string.qq_group_copied, QQ_NUMBER)
                                else stringResource(R.string.contact_support),
                                style = MaterialTheme.typography.labelMedium,
                                textAlign = TextAlign.End,
                                color = if (copied) colors.statusConnected else colors.accentBlue
                            )
                        }
                    }

                    // ---- 恢复已购授权:重装/清数据后本地没码时,按设备指纹找回(需外网,仅连接页显示)----
                    if (showEnterCode) {
                        TextButton(
                            enabled = !restoring && !success,
                            onClick = {
                                restoring = true; restoreMsg = null
                                scope.launch {
                                    when (LicenseManager.restorePurchase()) {
                                        LicenseManager.RestoreResult.Success -> success = true
                                        LicenseManager.RestoreResult.NotFound ->
                                            restoreMsg = R.string.restore_none
                                        LicenseManager.RestoreResult.Unreachable ->
                                            restoreMsg = R.string.err_server_unreachable
                                    }
                                    restoring = false
                                }
                            }
                        ) {
                            Text(
                                stringResource(if (restoring) R.string.restore_restoring else R.string.restore_action),
                                style = MaterialTheme.typography.labelMedium,
                                color = colors.onSurfaceVariant
                            )
                        }
                        if (restoreMsg != null) {
                            Text(
                                stringResource(restoreMsg!!),
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.accentOrange,
                                modifier = Modifier.padding(start = 12.dp, bottom = 4.dp)
                            )
                        }
                    }

                    // ---- 内联激活区：面板向下增高展开（设备码 + 输入框 + 激活按钮 + 状态行）----
                    AnimatedVisibility(
                        visible = codeMode,
                        enter = fadeIn() + expandVertically(),
                        exit = fadeOut() + shrinkVertically()
                    ) {
                        Column(Modifier.padding(top = 4.dp)) {
                            Text(
                                stringResource(R.string.device_code_label, LicenseManager.displayCode()),
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.onSurfaceVariant
                            )
                            Spacer(Modifier.height(8.dp))
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                OutlinedTextField(
                                    value = input,
                                    // 6 位大写字母(排除 I O);自动转大写、过滤非字母,让用户不必纠结大小写。
                                    onValueChange = { raw ->
                                        input = raw.uppercase().filter { it in 'A'..'Z' }.take(6)
                                        error = null
                                    },
                                    enabled = !busy && !success,
                                    singleLine = true,
                                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
                                    modifier = Modifier.weight(1f)
                                )
                                Spacer(Modifier.width(10.dp))
                                GlassButton(
                                    enabled = !busy && !success && input.length == 6,
                                    shape = RoundedCornerShape(14.dp),
                                    contentPadding = PaddingValues(horizontal = 18.dp, vertical = 14.dp),
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
                                        style = MaterialTheme.typography.labelLarge,
                                        fontWeight = FontWeight.SemiBold,
                                        color = colors.accentBlue
                                    )
                                }
                            }
                            Spacer(Modifier.height(8.dp))
                            when {
                                success -> Text(
                                    stringResource(R.string.activation_success),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = colors.statusConnected
                                )
                                error != null -> Text(
                                    if (error == R.string.err_generic) stringResource(R.string.err_generic, errorArg)
                                    else stringResource(error!!),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = colors.accentOrange
                                )
                                else -> Text(
                                    stringResource(R.string.activation_privacy),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = colors.onSurfaceVariant.copy(alpha = 0.7f)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/** 对比表行:功能名弹性列 + 免费/高级版两个定宽值列(高级版列金色加粗)。 */
@Composable
private fun CompareRow(name: String, free: String, pro: String) {
    val colors = AppTheme.colors
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.padding(vertical = 7.dp)
    ) {
        Text(
            name,
            style = MaterialTheme.typography.bodySmall,
            color = colors.onBackground,
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
