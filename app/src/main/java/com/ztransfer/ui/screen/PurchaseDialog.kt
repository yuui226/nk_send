package com.ztransfer.ui.screen

import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import com.ztransfer.ui.theme.AppTheme
import kotlinx.coroutines.delay

/**
 * 购买对话框:下单 → 展示虎皮椒返回的微信收款二维码 → 用户微信扫码付款 → 轮询到账 → 自动激活。
 * 微信个人支付不支持 App 内直接唤起,故走"显示二维码、引导截图后微信扫一扫"的方式。
 * 本地存有未走完的旧单时自动续上(付款后 App 被杀/中途退出都不丢码)。
 * 激活失败不阻塞:码已到手并展示,用户可稍后走"输入激活码"。
 */
@Composable
fun PurchaseDialog(onDismiss: () -> Unit) {
    val colors = AppTheme.colors
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current

    var order by remember { mutableStateOf<String?>(null) }
    var payQr by remember { mutableStateOf<String?>(null) }        // 二维码图片地址
    var payUrl by remember { mutableStateOf<String?>(null) }       // 手机端支付链接(降级)
    var qrBitmap by remember { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
    var code by remember { mutableStateOf<String?>(null) }
    var activated by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<Int?>(null) }
    var copied by remember { mutableStateOf(false) }
    var showCode by remember { mutableStateOf(false) }   // 成功后默认收起激活码,点"查看"才展开
    var linkCopied by remember { mutableStateOf(false) } // 复制支付链接的反馈
    var qrExpired by remember { mutableStateOf(false) }  // 二维码超 5 分钟未支付 → 提示刷新
    var refreshKey by remember { mutableStateOf(0) }     // 递增触发重新建单(刷新)

    // 建单/续单:首次(refreshKey==0)先试本地旧单,拿不到再新建;刷新(>0)一律新建。
    LaunchedEffect(refreshKey) {
        qrExpired = false
        var r: LicenseManager.OrderResult? = null
        if (refreshKey == 0) {
            val resumed = LicenseManager.pendingOrder()
            r = if (resumed != null) LicenseManager.orderStatus(resumed, wantUrl = true) else null
            // 旧单已失效,或还挂着待支付但二维码/链接都拿不到(已过期)——都落回新建订单
            if (r == null || r is LicenseManager.OrderResult.Failed ||
                (r is LicenseManager.OrderResult.Pending && r.payQr == null && r.payUrl == null)
            ) r = LicenseManager.createOrder()
        } else {
            r = LicenseManager.createOrder()
        }
        when (r) {
            is LicenseManager.OrderResult.Pending -> { order = r.order; payQr = r.payQr; payUrl = r.payUrl }
            is LicenseManager.OrderResult.Paid -> { order = r.order; code = r.code }
            LicenseManager.OrderResult.Unreachable -> error = R.string.err_purchase_unreachable
            is LicenseManager.OrderResult.Failed -> error = R.string.err_purchase_failed
            null -> Unit
        }
    }

    // 二维码 5 分钟有效期:到点仍未支付就标记过期,引导刷新(重拉新码)。
    LaunchedEffect(order) {
        if (order != null && code == null) {
            delay(5 * 60_000)
            if (code == null) qrExpired = true
        }
    }

    // 拉取二维码图片(虎皮椒域名,普通 TLS)。失败则 qrBitmap 保持 null,UI 降级为"打开支付页面"。
    LaunchedEffect(payQr) {
        val url = payQr ?: return@LaunchedEffect
        val bytes = LicenseManager.fetchBytes(url) ?: return@LaunchedEffect
        qrBitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
    }

    // 轮询到账 → 自动激活。网络抖动静默重试;对话框关闭即随组合取消。
    LaunchedEffect(order) {
        val o = order ?: return@LaunchedEffect
        while (code == null) {
            delay(2000)
            val r = LicenseManager.orderStatus(o)
            if (r is LicenseManager.OrderResult.Paid) code = r.code
        }
        when (LicenseManager.activate(code!!, BuildConfig.VERSION_NAME)) {
            LicenseManager.ActivationResult.Success -> {
                activated = true
                LicenseManager.clearPendingOrder()
            }
            else -> Unit
        }
    }

    // 待支付/建单中锁定弹窗:扫码时手机正举着对屏幕,点外部/边缘返回手势极易误触——
    // 误关虽能续单但二维码要重拉。锁定期只留底部显式"取消"退出;拿到码或已报错后恢复随手关。
    val dismissible = code != null || error != null
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            dismissOnBackPress = dismissible,
            dismissOnClickOutside = dismissible
        )
    ) {
        Surface(
            color = colors.glassSurfaceHeavy,
            shape = RoundedCornerShape(28.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(Modifier.padding(24.dp)) {
                Text(
                    stringResource(R.string.unlock_pro),
                    style = MaterialTheme.typography.headlineSmall,
                    color = colors.onBackground
                )
                Spacer(Modifier.height(16.dp))

                when {
                    // 到账后:自动激活成功 → 干净的"已激活",激活码默认收起;
                    // 自动激活失败 → 亮出激活码引导手动输入。
                    code != null -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        if (activated) {
                            Text(
                                stringResource(R.string.purchase_activated),
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                color = colors.statusConnected
                            )
                            Spacer(Modifier.height(10.dp))
                            if (showCode) {
                                // 主动展开:留给一码两机(第二台设备手输)与赠送/转账场景
                                TextButton(onClick = {
                                    clipboard.setText(AnnotatedString(code!!))
                                    copied = true
                                }) {
                                    Text(
                                        code!!,
                                        style = MaterialTheme.typography.headlineSmall,
                                        fontWeight = FontWeight.Bold,
                                        color = colors.onBackground
                                    )
                                }
                                Text(
                                    stringResource(
                                        if (copied) R.string.purchase_code_copied
                                        else R.string.purchase_keep_code
                                    ),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = colors.onSurfaceVariant
                                )
                            } else {
                                TextButton(onClick = { showCode = true }) {
                                    Text(
                                        stringResource(R.string.purchase_view_code),
                                        style = MaterialTheme.typography.bodySmall,
                                        color = colors.onSurfaceVariant
                                    )
                                }
                            }
                        } else {
                            // 已收款但自动激活未成功:亮出码 + 手动输入引导
                            Text(
                                stringResource(R.string.purchase_success),
                                style = MaterialTheme.typography.bodyMedium,
                                color = colors.statusConnected
                            )
                            Spacer(Modifier.height(12.dp))
                            TextButton(onClick = {
                                clipboard.setText(AnnotatedString(code!!))
                                copied = true
                            }) {
                                Text(
                                    code!!,
                                    style = MaterialTheme.typography.headlineMedium,
                                    fontWeight = FontWeight.Bold,
                                    color = colors.onBackground
                                )
                            }
                            Spacer(Modifier.height(8.dp))
                            Text(
                                stringResource(
                                    if (copied) R.string.purchase_code_copied
                                    else R.string.purchase_paid_not_active
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.accentOrange
                            )
                        }
                    }

                    error != null -> Text(
                        stringResource(error!!),
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.accentOrange
                    )

                    // 二维码已过期(5 分钟未支付):引导刷新重拉新码
                    qrExpired -> Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(
                            stringResource(R.string.purchase_qr_expired),
                            style = MaterialTheme.typography.bodyMedium,
                            color = colors.accentOrange
                        )
                        Spacer(Modifier.height(8.dp))
                        TextButton(onClick = {
                            order = null; payQr = null; payUrl = null; qrBitmap = null
                            linkCopied = false; qrExpired = false
                            refreshKey++
                        }) {
                            Text(
                                stringResource(R.string.purchase_qr_refresh),
                                style = MaterialTheme.typography.labelLarge,
                                fontWeight = FontWeight.Bold,
                                color = colors.accentBlue
                            )
                        }
                    }

                    // 待支付:显示微信收款二维码 + 扫码引导
                    order != null && (payQr != null || payUrl != null) ->
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            when {
                                qrBitmap != null -> {
                                    // 二维码放白底上,深色主题下也能被微信正常识别
                                    Box(
                                        Modifier
                                            .background(Color.White, RoundedCornerShape(12.dp))
                                            .padding(12.dp)
                                    ) {
                                        Image(
                                            bitmap = qrBitmap!!,
                                            contentDescription = null,
                                            // 二维码是小尺寸位图,放大用最近邻保持模块边缘锐利,保证可扫
                                            filterQuality = androidx.compose.ui.graphics.FilterQuality.None,
                                            modifier = Modifier.size(200.dp)
                                        )
                                    }
                                    Spacer(Modifier.height(14.dp))
                                    Text(
                                        stringResource(R.string.purchase_scan_hint),
                                        style = MaterialTheme.typography.bodySmall,
                                        color = colors.onSurfaceVariant
                                    )
                                    // 复制支付链接:买家可在电脑浏览器打开该链接显示二维码,用手机微信扫
                                    if (payUrl != null) {
                                        Spacer(Modifier.height(4.dp))
                                        TextButton(onClick = {
                                            clipboard.setText(AnnotatedString(payUrl!!))
                                            linkCopied = true
                                        }) {
                                            Text(
                                                stringResource(
                                                    if (linkCopied) R.string.purchase_link_copied
                                                    else R.string.purchase_copy_link
                                                ),
                                                style = MaterialTheme.typography.bodySmall,
                                                color = colors.accentBlue
                                            )
                                        }
                                    }
                                }
                                // 有二维码地址但图还没拉到:转圈
                                payQr != null -> {
                                    CircularProgressIndicator(color = colors.accentBlue)
                                    Spacer(Modifier.height(12.dp))
                                    Text(
                                        stringResource(R.string.purchase_qr_loading),
                                        style = MaterialTheme.typography.bodySmall,
                                        color = colors.onSurfaceVariant
                                    )
                                }
                                // 只有链接没有二维码:降级为按钮打开支付页
                                else -> {
                                    TextButton(onClick = {
                                        runCatching {
                                            context.startActivity(
                                                Intent(Intent.ACTION_VIEW, Uri.parse(payUrl))
                                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                            )
                                        }
                                    }) {
                                        Text(
                                            stringResource(R.string.purchase_open_link),
                                            color = colors.accentBlue,
                                            fontWeight = FontWeight.Bold
                                        )
                                    }
                                }
                            }
                        }

                    // 建单中
                    else -> Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        CircularProgressIndicator(color = colors.accentBlue)
                        Spacer(Modifier.height(12.dp))
                        Text(
                            stringResource(R.string.purchase_loading),
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant
                        )
                    }
                }

                Spacer(Modifier.height(8.dp))
                TextButton(
                    onClick = onDismiss,
                    modifier = Modifier.align(Alignment.End)
                ) {
                    Text(
                        stringResource(if (code != null) R.string.purchase_done else R.string.cancel),
                        color = if (code != null) colors.accentBlue else colors.onSurfaceVariant
                    )
                }
            }
        }
    }
}
