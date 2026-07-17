package com.ztransfer.ui.screen

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color as AndroidColor
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.provider.MediaStore
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.ztransfer.ui.theme.AppTheme

/**
 * 当前网络是否真的能上外网。相机 Wi-Fi 有连接但无外网,系统会把它标记为"未验证"(VALIDATED 为假),
 * 正好用来在下单前拦住"没网就点购买"——否则要等 8 秒超时才报错。
 * 查的是【默认网络】,也正是微信付款要用的那张网:这里通过 = 微信也能付。
 * 拿不到系统服务时保守返回 true(不误拦,交给后续请求自然失败)。
 */
private fun hasInternet(context: Context): Boolean {
    val cm = context.getSystemService(ConnectivityManager::class.java) ?: return true
    val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return false) ?: return false
    return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
        caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
}

/** 把支付链接画成二维码位图(白底黑码,四周留白便于识别)。 */
private fun encodeQr(text: String, sizePx: Int): Bitmap? = runCatching {
    val hints = mapOf(
        EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M,
        EncodeHintType.MARGIN to 1,
        EncodeHintType.CHARACTER_SET to "UTF-8",
    )
    val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, sizePx, sizePx, hints)
    Bitmap.createBitmap(m.width, m.height, Bitmap.Config.RGB_565).apply {
        for (x in 0 until m.width) for (y in 0 until m.height) {
            setPixel(x, y, if (m[x, y]) AndroidColor.BLACK else AndroidColor.WHITE)
        }
    }
}.getOrNull()

/** 存二维码到系统相册。成功返回 true;失败(如低版本无写权限)返回 false,由 UI 引导改用截图。 */
private fun saveToGallery(context: Context, bitmap: Bitmap, name: String): Boolean = runCatching {
    val values = ContentValues().apply {
        put(MediaStore.Images.Media.DISPLAY_NAME, "$name.png")
        put(MediaStore.Images.Media.MIME_TYPE, "image/png")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures")
        }
    }
    val uri = context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
        ?: return false
    context.contentResolver.openOutputStream(uri)?.use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        ?: return false
    true
}.getOrDefault(false)

/**
 * 购买对话框:下单 → 把手机端支付链接画成二维码 → 用户存相册/截图后用微信扫一扫(相册)付款
 * → 轮询到账 → 自动激活。
 *
 * 版面只服务一件事:【把这张码递进微信】。用户马上要离开本页去微信,所以屏上只留
 * 金额(确认付多少)、码(主角,唯一亮处)、一个动作(保存)、一句下一步(去微信怎么扫)。
 * 关闭只放右上角叉号:待支付时底部若有"取消",指头正要去点保存/截图,极易误触。
 *
 * ★ 为什么"扫自己屏幕上的码"能成(虎皮椒文档 https://www.xunhupay.com/doc/api/pay.html):
 *   手机端要用 `url`(而非 PC 端的 `url_qrcode`)。`url` 是个分发页:在微信里打开会自动跳
 *   JSAPI 付款页。所以把 `url` 编成二维码后,它是【普通 https 网址码】——微信允许从相册扫
 *   普通网址码(只有 weixin:// 收款码才被禁),扫开即在微信内付款。
 *   我们自己画码而不是塞它的 H5 页:排版自己说了算,还能一键存相册。
 *
 * 本地存有未走完的旧单时自动续上(付款后 App 被杀/中途退出都不丢码)。
 * 激活失败不阻塞:码已到手并展示,用户可稍后走"输入激活码"。
 */
@Composable
fun PurchaseDialog(
    onDismiss: () -> Unit,
    onCelebrate: () -> Unit = {},
    onHoldCameraWifi: (Boolean) -> Unit = {},
    // 续费单(现有码延期)而非新购;成败文案以【服务器回的 renew】为准,本参数只负责下单时告知服务器。
    renew: Boolean = false,
) {
    val colors = AppTheme.colors
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    // 购买期间主动断开相机(CameraViewModel.holdCameraWifi):关闭 PTP 会话让相机
    // 自行关掉 Wi-Fi 热点,并松开 requestNetwork 占用——相机热点没有外网,不断开则
    // 我们下单和微信付款都联不上网。弹窗关闭时握回来,相机由既有的自动重连接管。
    DisposableEffect(Unit) {
        onHoldCameraWifi(false)
        onDispose { onHoldCameraWifi(true) }
    }

    var order by remember { mutableStateOf<String?>(null) }
    var payUrl by remember { mutableStateOf<String?>(null) }   // 手机端支付链接(虎皮椒 url)
    var qr by remember { mutableStateOf<Bitmap?>(null) }
    var saved by remember { mutableStateOf(false) }
    // 存相册失败单独记,不能并进 error(见下方保存按钮处的注释)
    var saveFailed by remember { mutableStateOf(false) }
    var code by remember { mutableStateOf<String?>(null) }
    var activated by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<Int?>(null) }
    var copied by remember { mutableStateOf(false) }
    var expired by remember { mutableStateOf(false) }    // 超 5 分钟未支付 → 提示重新发起
    var refreshKey by remember { mutableStateOf(0) }     // 递增触发重新建单
    var restored by remember { mutableStateOf(false) }   // 本机已拥有 → 免费恢复(而非新购买)
    var paidRenew by remember { mutableStateOf(false) }  // 服务器判定的续费单 → 成功页说"续费成功"
    // 本单锁定的实收价(分)。头部报的是它,不是缓存的展示价——展示价可能过时
    // (App 常连着相机热点拉不到新价),而这个数是服务器建单时现读的,扫出来的码就是它。
    var orderPriceFen by remember { mutableStateOf(0) }

    // 建单/续单:首次(refreshKey==0)先试本地旧单,拿不到再新建;刷新(>0)一律新建。
    LaunchedEffect(refreshKey) {
        expired = false; saved = false; saveFailed = false; qr = null
        // 付款全流程都要外网。刚松开相机 Wi-Fi 后系统切到蜂窝需要一两秒,
        // 故给一段等待再判定"没网",避免刚进来就误报。
        var online = hasInternet(context)
        var waited = 0
        while (!online && waited < 6000) {
            delay(300); waited += 300
            online = hasInternet(context)
        }
        if (!online) {
            error = R.string.err_purchase_no_network
            return@LaunchedEffect
        }
        var r: LicenseManager.OrderResult? = null
        if (refreshKey == 0) {
            val resumed = LicenseManager.pendingOrder()
            r = if (resumed != null) LicenseManager.orderStatus(resumed, wantUrl = true) else null
            if (r == null || r is LicenseManager.OrderResult.Failed ||
                (r is LicenseManager.OrderResult.Pending && r.payUrl == null)
            ) r = LicenseManager.createOrder(renew)
        } else {
            r = LicenseManager.createOrder(renew)
        }
        when (r) {
            is LicenseManager.OrderResult.Pending -> {
                order = r.order; payUrl = r.payUrl; paidRenew = r.renew; orderPriceFen = r.priceFen
            }
            // order 为空 = 服务器认出本机已拥有、免费恢复(见 createOrder 的 already_pro)
            is LicenseManager.OrderResult.Paid -> {
                order = r.order; code = r.code; paidRenew = r.renew
                if (r.order.isEmpty()) restored = true
            }
            LicenseManager.OrderResult.Unreachable -> error = R.string.err_purchase_unreachable
            is LicenseManager.OrderResult.Failed -> error = R.string.err_purchase_failed
            null -> Unit
        }
    }

    // 画码(编码在后台线程,别卡住动画)
    LaunchedEffect(payUrl) {
        val u = payUrl ?: return@LaunchedEffect
        qr = withContext(Dispatchers.Default) { encodeQr(u, 720) }
    }

    // 支付链接 5 分钟有效期:到点未支付就标记过期,引导重新发起。
    LaunchedEffect(order) {
        if (order != null && code == null) {
            delay(5 * 60_000)
            if (code == null) expired = true
        }
    }

    // 轮询到账 → 自动激活。过期即停止轮询,不再空打死单。
    LaunchedEffect(order) {
        val o = order ?: return@LaunchedEffect
        while (code == null && !expired) {
            delay(2000)
            val r = LicenseManager.orderStatus(o)
            if (r is LicenseManager.OrderResult.Paid) { code = r.code; paidRenew = r.renew }
        }
        val c = code ?: return@LaunchedEffect
        when (LicenseManager.activate(c, BuildConfig.VERSION_NAME)) {
            LicenseManager.ActivationResult.Success -> {
                activated = true
                LicenseManager.clearPendingOrder()
            }
            else -> Unit
        }
    }

    // 关闭统一走右上角叉号:成功后关闭顺带放烟花(与"完成"同一动作)。
    val close: () -> Unit = { if (activated) onCelebrate() else onDismiss() }
    // 待支付期锁掉点外部/返回手势:用户正要去截图或切微信,误触就白等一场。
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
            Box {
                // 与解锁弹窗同款毛玻璃高光,两屏是同一流程的上下文
                Box(
                    Modifier
                        .matchParentSize()
                        .background(Brush.verticalGradient(listOf(colors.glassSheen, Color.Transparent)))
                )
                Column(Modifier.padding(20.dp)) {
                    // ---- 头部:左边说清"付什么、多少钱",右边叉号退出 ----
                    // 钱已经付完就撤掉金额:那时这里是庆祝页,只该说"解锁了",再挂个价签是提醒他刚花了钱。
                    Row(verticalAlignment = Alignment.Top) {
                        Column(Modifier.weight(1f)) {
                            if (qr != null && code == null) {
                                Text(
                                    stringResource(R.string.purchase_wechat_title),
                                    style = MaterialTheme.typography.labelMedium,
                                    color = colors.onSurfaceVariant
                                )
                                if (orderPriceFen > 0) {
                                    Text(
                                        stringResource(
                                            R.string.price_per_year,
                                            LicenseManager.formatPrice(orderPriceFen)
                                        ),
                                        style = MaterialTheme.typography.titleLarge,
                                        fontWeight = FontWeight.Bold,
                                        // 与解锁弹窗的定价同一个金色:同一笔钱,视觉接得上
                                        color = ProGold
                                    )
                                }
                            }
                        }
                        IconButton(onClick = close, modifier = Modifier.size(32.dp)) {
                            Icon(
                                Icons.Default.Close,
                                contentDescription = stringResource(R.string.cd_close),
                                tint = colors.onSurfaceVariant
                            )
                        }
                    }

                    Column(
                        Modifier
                            .fillMaxWidth()
                            .padding(top = 4.dp),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        when {
                            // ---- 到账:自动激活成功 → 只报喜,别的什么都不说 ----
                            // 激活码此刻对用户毫无用处(已自动激活),摆在这只会引出"这码干嘛用的"。
                            // 真要它的时机只有换机,那时去设置里的「我要换机」拿(SwitchDeviceDialog)。
                            code != null -> {
                                Spacer(Modifier.height(4.dp))
                                if (activated) {
                                    // 续费的人已经是高级版,再说一遍"已解锁"没意义——他要看的是新的到期日。
                                    // 日期从续费后新通行证的 sub 读;万一读不到(永久码)就退回通用文案。
                                    val newSubExp = remember(activated) { LicenseManager.subExpiresAtSec() }
                                    Text(
                                        when {
                                            restored -> stringResource(R.string.purchase_restored)
                                            paidRenew && newSubExp > 0L ->
                                                stringResource(R.string.purchase_renewed, formatSubDate(newSubExp))
                                            else -> stringResource(R.string.purchase_activated)
                                        },
                                        style = MaterialTheme.typography.titleMedium,
                                        fontWeight = FontWeight.Bold,
                                        color = colors.statusConnected,
                                        textAlign = TextAlign.Center
                                    )
                                    Spacer(Modifier.height(16.dp))
                                    GlassButton(
                                        shape = RoundedCornerShape(14.dp),
                                        panel = true,
                                        contentPadding = PaddingValues(horizontal = 26.dp, vertical = 12.dp),
                                        onClick = onCelebrate
                                    ) {
                                        Text(
                                            stringResource(R.string.purchase_done),
                                            style = MaterialTheme.typography.labelLarge,
                                            fontWeight = FontWeight.Bold,
                                            color = colors.accentBlue
                                        )
                                    }
                                } else {
                                    // 已收款但自动激活未成功:亮出码 + 手动输入引导。
                                    // 这里不再报"支付成功已激活"——它和下面那句"自动激活未成功"直接打架。
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
                                    Text(
                                        stringResource(
                                            if (copied) R.string.purchase_code_copied
                                            else R.string.purchase_paid_not_active
                                        ),
                                        style = MaterialTheme.typography.bodySmall,
                                        color = colors.accentOrange,
                                        textAlign = TextAlign.Center
                                    )
                                }
                            }

                            // ---- 出错(多为没外网):说明 + 重试 ----
                            error != null -> {
                                Spacer(Modifier.height(8.dp))
                                Text(
                                    stringResource(error!!),
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = colors.accentOrange,
                                    textAlign = TextAlign.Center
                                )
                                Spacer(Modifier.height(12.dp))
                                GlassButton(
                                    shape = RoundedCornerShape(14.dp),
                                    panel = true,
                                    contentPadding = PaddingValues(horizontal = 26.dp, vertical = 12.dp),
                                    onClick = { error = null; refreshKey++ }
                                ) {
                                    Text(
                                        stringResource(R.string.retry),
                                        style = MaterialTheme.typography.labelLarge,
                                        fontWeight = FontWeight.Bold,
                                        color = colors.accentBlue
                                    )
                                }
                            }

                            // ---- 超时:重新发起 ----
                            expired -> {
                                Spacer(Modifier.height(8.dp))
                                Text(
                                    stringResource(R.string.purchase_qr_expired),
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = colors.accentOrange
                                )
                                Spacer(Modifier.height(12.dp))
                                GlassButton(
                                    shape = RoundedCornerShape(14.dp),
                                    panel = true,
                                    contentPadding = PaddingValues(horizontal = 26.dp, vertical = 12.dp),
                                    onClick = { order = null; payUrl = null; refreshKey++ }
                                ) {
                                    Text(
                                        stringResource(R.string.purchase_qr_refresh),
                                        style = MaterialTheme.typography.labelLarge,
                                        fontWeight = FontWeight.Bold,
                                        color = colors.accentBlue
                                    )
                                }
                            }

                            // ---- 主角:码。全屏唯一的亮处,不加任何装饰,扫得出最重要 ----
                            qr != null -> {
                                Spacer(Modifier.height(14.dp))
                                // 码底必须是纯白(扫得出优先,不随主题变)。但浅色主题下白卡会糊在
                                // 浅玻璃面板上,故补一圈与对比表同族的描边把边界界定出来;深色下它很淡,不碍事。
                                val qrShape = RoundedCornerShape(16.dp)
                                Box(
                                    Modifier
                                        .clip(qrShape)
                                        .background(Color.White)
                                        .border(1.dp, colors.glassPanelBorder, qrShape)
                                        .padding(12.dp)
                                ) {
                                    Image(
                                        bitmap = qr!!.asImageBitmap(),
                                        contentDescription = null,
                                        // 码是位图,放大用最近邻保持模块边缘锐利,保证扫得出
                                        filterQuality = FilterQuality.None,
                                        modifier = Modifier.size(232.dp)
                                    )
                                }
                                Spacer(Modifier.height(18.dp))
                                // 唯一动作
                                GlassButton(
                                    shape = RoundedCornerShape(14.dp),
                                    panel = true,
                                    contentPadding = PaddingValues(horizontal = 26.dp, vertical = 12.dp),
                                    onClick = {
                                        scope.launch {
                                            val b = qr ?: return@launch
                                            val ok = withContext(Dispatchers.IO) {
                                                saveToGallery(context, b, "ZTransfer-pay-${System.currentTimeMillis()}")
                                            }
                                            saved = ok
                                            saveFailed = !ok
                                        }
                                    }
                                ) {
                                    Text(
                                        stringResource(
                                            if (saved) R.string.purchase_saved else R.string.purchase_save_qr
                                        ),
                                        style = MaterialTheme.typography.labelLarge,
                                        fontWeight = FontWeight.Bold,
                                        color = if (saved) colors.statusConnected else colors.accentBlue
                                    )
                                }
                                Spacer(Modifier.height(12.dp))
                                // 存不进相册就让他截图——但码必须还在屏幕上,否则"请改用截图"是句空话。
                                // 所以保存失败【绝不能】写进 error:那个分支排在码前面,会把码整个顶掉,
                                // 只留一个"重试"按钮把正在付的单废掉重建(Android 8~9 上没有
                                // WRITE_EXTERNAL_STORAGE,存相册必失败,那就成了永远付不了款的死循环)。
                                Text(
                                    stringResource(
                                        if (saveFailed) R.string.purchase_save_failed
                                        else R.string.purchase_scan_hint
                                    ),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = if (saveFailed) colors.accentOrange else colors.onSurfaceVariant,
                                    textAlign = TextAlign.Center
                                )
                            }

                            // ---- 建单/画码中 ----
                            else -> {
                                Spacer(Modifier.height(24.dp))
                                CircularProgressIndicator(color = colors.accentBlue)
                                Spacer(Modifier.height(14.dp))
                                Text(
                                    stringResource(R.string.purchase_loading),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = colors.onSurfaceVariant
                                )
                                Spacer(Modifier.height(24.dp))
                            }
                        }
                    }
                }
            }
        }
    }
}
