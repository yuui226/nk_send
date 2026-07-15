package com.ztransfer.ui.screen

import android.content.Intent
import android.net.Uri
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import com.ztransfer.ui.theme.AppTheme
import kotlinx.coroutines.delay

/**
 * 购买对话框:下单 → WebView 打开虎皮椒收银台唤起支付宝/微信 → 轮询到账 → 自动激活。
 * 本地存有未走完的旧单时自动续上(付款后 App 被杀/中途退出都不丢码)。
 * 激活失败不阻塞:码已到手并展示,用户可稍后走"输入激活码"。
 */
@Composable
fun PurchaseDialog(onDismiss: () -> Unit) {
    val colors = AppTheme.colors
    val clipboard = LocalClipboardManager.current

    var order by remember { mutableStateOf<String?>(null) }
    var payUrl by remember { mutableStateOf<String?>(null) }
    var code by remember { mutableStateOf<String?>(null) }
    var activated by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<Int?>(null) }
    var copied by remember { mutableStateOf(false) }

    // 收银台 WebView 默认隐藏在后台加载,用户只看到"正在打开支付宝"。
    // 若收银台页自动唤起支付宝(alipaysLaunched=true)则全程不露脸;
    // 若它需要用户手点(超时仍未唤起),则揭开 WebView 让用户自行操作。
    var alipayLaunched by remember { mutableStateOf(false) }
    var revealCashier by remember { mutableStateOf(false) }

    // 对话框关闭时释放 WebView 的原生资源
    val webViewRef = remember { arrayOfNulls<WebView>(1) }
    DisposableEffect(Unit) {
        onDispose { webViewRef[0]?.destroy() }
    }

    // 收银台加载后给 4 秒自动唤起支付宝的机会;仍没跳(且没直接查到已付)就揭开页面兜底。
    LaunchedEffect(payUrl) {
        if (payUrl != null) {
            delay(4000)
            if (!alipayLaunched && code == null) revealCashier = true
        }
    }

    // 建单/续单:先试本地记录的旧单(可能已支付未领码),没有或已失效再新建。
    LaunchedEffect(Unit) {
        val resumed = LicenseManager.pendingOrder()
        var r: LicenseManager.OrderResult? =
            if (resumed != null) LicenseManager.orderStatus(resumed, wantUrl = true) else null
        // 旧单已失效,或还挂着待支付但收银台链接已过期拿不到——都落回新建订单
        if (r == null || r is LicenseManager.OrderResult.Failed ||
            (r is LicenseManager.OrderResult.Pending && r.payUrl == null)
        ) r = LicenseManager.createOrder()
        when (r) {
            is LicenseManager.OrderResult.Pending -> { order = r.order; payUrl = r.payUrl }
            is LicenseManager.OrderResult.Paid -> { order = r.order; code = r.code }
            LicenseManager.OrderResult.Unreachable -> error = R.string.err_purchase_unreachable
            is LicenseManager.OrderResult.Failed -> error = R.string.err_purchase_failed
        }
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

    Dialog(onDismissRequest = onDismiss) {
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
                    // 到账:展示激活码(点击复制),已自动激活或提示手动输入
                    code != null -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
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
                                else if (activated) R.string.purchase_keep_code
                                else R.string.purchase_paid_not_active
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant
                        )
                    }

                    error != null -> Text(
                        stringResource(error!!),
                        style = MaterialTheme.typography.bodyMedium,
                        color = colors.accentOrange
                    )

                    // 支付中:收银台 WebView 在后台加载并唤起支付宝。默认不可见(高度 0),
                    // 仅在超时未自动唤起时揭开(revealCashier)让用户手动完成。
                    payUrl != null -> Column {
                        if (!revealCashier) {
                            Column(
                                horizontalAlignment = Alignment.CenterHorizontally,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                CircularProgressIndicator(color = colors.accentBlue)
                                Spacer(Modifier.height(12.dp))
                                Text(
                                    stringResource(R.string.purchase_opening_alipay),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = colors.onSurfaceVariant
                                )
                            }
                        }
                        AndroidView(
                            factory = { ctx ->
                                WebView(ctx).apply {
                                    settings.javaScriptEnabled = true
                                    settings.domStorageEnabled = true
                                    webViewClient = object : WebViewClient() {
                                        override fun shouldOverrideUrlLoading(
                                            view: WebView?, request: WebResourceRequest?,
                                        ): Boolean {
                                            val url = request?.url?.toString() ?: return false
                                            if (url.startsWith("http://") || url.startsWith("https://")) return false
                                            // alipays:// weixin:// intent:// 等自定义 scheme 转交系统唤起;
                                            // 未装对应 App 时吞掉异常,页面留在收银台自身的降级引导上。
                                            runCatching {
                                                val intent = if (url.startsWith("intent:"))
                                                    Intent.parseUri(url, Intent.URI_INTENT_SCHEME)
                                                else Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                                ctx.startActivity(intent)
                                                alipayLaunched = true
                                            }
                                            return true
                                        }
                                    }
                                    loadUrl(payUrl!!)
                                    webViewRef[0] = this
                                }
                            },
                            // 隐藏态高度 0(仍在窗口内加载并执行 JS,可正常触发 scheme 唤起)
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(if (revealCashier) 380.dp else 0.dp)
                        )
                        if (revealCashier) {
                            Spacer(Modifier.height(8.dp))
                            Text(
                                stringResource(R.string.purchase_waiting),
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.onSurfaceVariant
                            )
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
