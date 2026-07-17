package com.ztransfer.ui.screen

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.WorkspacePremium
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
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
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import androidx.compose.ui.text.font.FontWeight
import com.ztransfer.ui.theme.AppTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.ceil

// 高级版列/定价的金色文字(与 ProBadgeButton 的金渐变同族,压深一档保证浅色玻璃上可读)。
// 购买弹窗的金额也用它——同一笔钱在两屏用同一个金色,视觉上接得上。
internal val ProGold = Color(0xFFE09B2D)
// 对比表的免费/高级版两个值列的定宽(功能名占弹性剩余宽度)。
private val CompareColWidth = 64.dp

// 到期预警的两道门槛:设置页进 30 天转橙提醒,首页进 7 天才值得占一条提示条。
internal const val SUB_WARN_DAYS = 30
internal const val SUB_ALERT_DAYS = 7

/** 订阅到期日(Unix 秒 → yyyy-MM-dd)。数字日期无歧义,不随界面语言换写法。 */
internal fun formatSubDate(sec: Long): String =
    SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(sec * 1000))

/** 距订阅到期还剩几天。向上取整:到期当天该说"剩 1 天",说"剩 0 天"像是已经没了。 */
internal fun subDaysLeft(sec: Long): Int =
    ceil((sec - System.currentTimeMillis() / 1000) / 86400.0).toInt().coerceAtLeast(0)

/**
 * 高级版介绍对话框("解锁高级版"徽标打开,连接页与设置面板共用):
 * 自定义毛玻璃面板(与设置/筛选面板同一玻璃语言,不用 M3 AlertDialog 原生样式)。
 *
 * 面板固定金徽章头部,主体在【购买页】与【激活页】之间**整块互斥切换**(而非向下展开):
 * Compose 的 Dialog 是独立窗口,内容做高度动画会让 WindowManager 逐帧重排窗口——又卡又晃,
 * 且把周围按钮一起顶动。换页只有一次性尺寸变化,干脆利落。
 *   购买页:对比表 → 定价 → 全宽金色"立即购买" → 一排玻璃小按钮[输入激活码 | 恢复授权 | 客服]
 *   激活页:头部左上换成毛玻璃返回箭头 + 设备码 → 输入框 + 激活 → 状态行
 *
 * [showEnterCode] 控制整排次级入口(输入激活码 / 恢复授权 / 客服):仅连接页开——彼时尚未连
 * 相机热点,多半还有外网;设置面板关:连着相机 Wi-Fi 无外网,在线激活/恢复必失败,
 * 而找客服在设置页脚本来就有"反馈"入口,不必重复。
 * 购买同理需要外网,但入口不藏:下单失败的报错文案会引导先断开相机 Wi-Fi。
 */
@Composable
fun ProDialog(
    onDismiss: () -> Unit,
    showEnterCode: Boolean = false,
    onCelebrate: () -> Unit = {},
    // 购买期间需临时松开对相机 Wi-Fi 的占用(相机热点没外网,付款联不上);由承载页接到 CameraViewModel。
    onHoldCameraWifi: (Boolean) -> Unit = {},
    // 订阅到期的老用户从本弹窗再买 = 给原来那个码续期,不该另发新码(见 LicenseManager.createOrder)。
    renew: Boolean = false,
) {
    val colors = AppTheme.colors
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()
    // 服务端下发的定价。启动时拉过一次,这里再拉一次:启动那次多半没赶上(用户开 App 时
    // 可能已经连着相机热点,没外网),而他现在正看着价格准备掏钱。先用缓存画出来,
    // 拉到再静默换掉——不阻塞开窗;只有价格真变了才会跳,那正是该跳的时候。
    LaunchedEffect(Unit) { LicenseManager.refreshPricingOnOpen() }
    val price by LicenseManager.pricing.collectAsState()
    var copied by remember { mutableStateOf(false) }
    // 购买流程叠在本弹窗之上;关闭后回到本弹窗(成功后由用户自行关闭)。
    var showPurchase by remember { mutableStateOf(false) }
    if (showPurchase) {
        PurchaseDialog(
            onDismiss = { showPurchase = false },
            // 购买+激活成功:关掉购买弹窗与本弹窗,再放烟花(烟花在页面顶层,须先关弹窗才可见)。
            onCelebrate = { showPurchase = false; onDismiss(); onCelebrate() },
            onHoldCameraWifi = onHoldCameraWifi,
            renew = renew
        )
    }
    // 激活页状态:codeMode 为真时主体换成激活页;成功后短暂显示成功文案、自动关闭整个弹窗。
    var codeMode by remember { mutableStateOf(false) }
    var input by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<Int?>(null) }        // 文案资源 id
    var errorArg by remember { mutableStateOf("") }              // err_generic 的错误码参数
    var success by remember { mutableStateOf(false) }
    // 恢复已购授权(重装后本地无码时按指纹找回)
    var restoring by remember { mutableStateOf(false) }
    var restoreMsg by remember { mutableStateOf<Int?>(null) }
    // 激活成功 / 恢复成功:短暂显示成功后关闭本弹窗并放烟花庆祝。
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
                    // ---- 头部：购买页是金徽章 + 标题/卖点副标语;激活页左上换成毛玻璃返回箭头,
                    // 标题改"输入激活码"且不带卖点——激活码可能永久也可能几个月,别报"一年有效"。----
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (codeMode) {
                            // 42dp 圆 + 10dp 内边距 + 22dp 图标正好同心;与金徽章同尺寸,换页头部不跳。
                            GlassButton(
                                enabled = !busy && !success,
                                onClick = { codeMode = false; input = ""; error = null },
                                shape = CircleShape,
                                panel = true,
                                contentPadding = PaddingValues(10.dp),
                                modifier = Modifier.size(42.dp)
                            ) {
                                Icon(
                                    Icons.Default.ArrowBack,
                                    contentDescription = stringResource(R.string.cd_back),
                                    tint = colors.onBackground,
                                    modifier = Modifier.size(22.dp)
                                )
                            }
                        } else {
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
                        }
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(
                                stringResource(if (codeMode) R.string.enter_code else R.string.pro_version),
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.Bold,
                                color = colors.onBackground
                            )
                            if (!codeMode) {
                                Text(
                                    stringResource(R.string.pro_perks),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = colors.onSurfaceVariant
                                )
                            }
                        }
                        IconButton(onClick = onDismiss, modifier = Modifier.size(32.dp)) {
                            Icon(Icons.Default.Close, contentDescription = null, tint = colors.onSurfaceVariant)
                        }
                    }

                    Spacer(Modifier.height(16.dp))

                    if (!codeMode) {
                        // ================= 购买页 =================
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
                                stringResource(R.string.compare_unlimited)
                            )
                        }

                        // 定价促销区:红色"限时特惠"角标 + 大号金色现价 + 划线原价,底下压一行
                        // 摊到每天的脚注——"现在买最便宜"的经典促销排布。
                        // 价格来自服务端(启动时静默拉,拉不到就用上次缓存),originalFen 为 0
                        // 则退化为单一价格(无角标无划线)。这里显示的只是展示价:真正收多少
                        // 以下单响应为准(见 PurchaseDialog)。
                        Spacer(Modifier.height(14.dp))
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.Center,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            if (price.originalFen > 0) {
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
                                stringResource(
                                    R.string.price_per_year,
                                    LicenseManager.formatPrice(price.priceFen)
                                ),
                                style = MaterialTheme.typography.headlineSmall,
                                fontWeight = FontWeight.Bold,
                                color = ProGold
                            )
                            if (price.originalFen > 0) {
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    stringResource(
                                        R.string.price_per_year,
                                        LicenseManager.formatPrice(price.originalFen)
                                    ),
                                    style = MaterialTheme.typography.bodyMedium,
                                    textDecoration = TextDecoration.LineThrough,
                                    color = colors.onSurfaceVariant
                                )
                            }
                        }
                        // 年费摊到每天当脚注:一年十几块听着是笔钱,一天几分钱不是。
                        // 压在价格下方而非上方——放上面会和紧跟着的大号金额把同一个数字报两遍。
                        // 摊完不足 1 分就别报了(那会印出"合每天 ¥0.00")。
                        val perDay = LicenseManager.perDayFen(price)
                        if (perDay > 0) {
                            Spacer(Modifier.height(4.dp))
                            Text(
                                stringResource(
                                    R.string.pro_price_per_day,
                                    LicenseManager.formatPrice(perDay)
                                ),
                                style = MaterialTheme.typography.labelSmall,
                                color = colors.onSurfaceVariant,
                                textAlign = TextAlign.Center,
                                modifier = Modifier.fillMaxWidth()
                            )
                        }

                        Spacer(Modifier.height(18.dp))

                        // ---- 主行动：全宽金色"立即购买"（与入口徽标同款扫光），拉起支付流程 ----
                        ProBadgeButton(
                            label = stringResource(R.string.buy_now),
                            onClick = { showPurchase = true },
                            modifier = Modifier.fillMaxWidth(),
                            big = true
                        )

                        // ---- 次级：一排玻璃小按钮,三个平分整行,整排仅连接页给(showEnterCode):
                        // 输入激活码/恢复授权要外网;客服在设置面板也不给——那里页脚有"反馈"入口兜底。----
                        if (showEnterCode) {
                            Spacer(Modifier.height(12.dp))
                            val subShape = RoundedCornerShape(12.dp)
                            val subPadding = PaddingValues(horizontal = 4.dp, vertical = 10.dp)
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                GlassButton(
                                    onClick = { codeMode = true; error = null },
                                    shape = subShape,
                                    panel = true,
                                    contentPadding = subPadding,
                                    modifier = Modifier.weight(1f)
                                ) {
                                    SubActionLabel(stringResource(R.string.enter_code))
                                }
                                GlassButton(
                                    enabled = !restoring && !success,
                                    onClick = {
                                        restoring = true; restoreMsg = null; copied = false
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
                                    },
                                    shape = subShape,
                                    panel = true,
                                    contentPadding = subPadding,
                                    modifier = Modifier.weight(1f)
                                ) {
                                    SubActionLabel(
                                        stringResource(
                                            if (restoring) R.string.restore_restoring else R.string.restore_action
                                        )
                                    )
                                }
                                GlassButton(
                                    onClick = {
                                        clipboard.setText(AnnotatedString(QQ_NUMBER))
                                        copied = true; restoreMsg = null
                                    },
                                    shape = subShape,
                                    panel = true,
                                    contentPadding = subPadding,
                                    modifier = Modifier.weight(1f)
                                ) {
                                    SubActionLabel(stringResource(R.string.contact_support))
                                }
                            }
                            // 按钮反馈共用一行位置:复制客服 QQ(绿)与恢复结果(橙),后点的顶掉先点的。
                            val feedback: Pair<String, Color>? = when {
                                copied -> stringResource(R.string.qq_group_copied, QQ_NUMBER) to colors.statusConnected
                                restoreMsg != null -> stringResource(restoreMsg!!) to colors.accentOrange
                                else -> null
                            }
                            if (feedback != null) {
                                Spacer(Modifier.height(8.dp))
                                Text(
                                    feedback.first,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = feedback.second,
                                    textAlign = TextAlign.Center,
                                    modifier = Modifier.fillMaxWidth()
                                )
                            }
                        }
                    } else {
                        // ================= 激活页（顶掉购买内容，弹窗不增高）=================
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
                                panel = true,
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
                                                "CODE_EXPIRED" -> error = R.string.err_code_expired
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

/**
 * 续费弹窗(连接页徽标左侧"续费"玻璃按钮打开):与高级版介绍弹窗同一玻璃面板语言。
 * 老用户已经买过,不再放对比表——只说三件事:还剩多少天、续一年多少钱、提前续不吃亏
 * (服务器按 max(now, 原到期日) + 1 年算续期,见 LicenseManager.createOrder)。
 * 点"立即续费"叠开付款弹窗(renew = true:给原来那个码续期,不发新码)。
 * 只有订阅用户能走到这儿(永久码没有到期日,连接页不给续费按钮)。
 */
@Composable
fun RenewDialog(
    onDismiss: () -> Unit,
    onCelebrate: () -> Unit = {},
    onHoldCameraWifi: (Boolean) -> Unit = {},
) {
    val colors = AppTheme.colors
    // 同 ProDialog:他正看着价格准备掏钱,开窗时再拉一次展示定价(先画缓存,拉到静默换)。
    LaunchedEffect(Unit) { LicenseManager.refreshPricingOnOpen() }
    val price by LicenseManager.pricing.collectAsState()
    var showPurchase by remember { mutableStateOf(false) }
    if (showPurchase) {
        PurchaseDialog(
            onDismiss = { showPurchase = false },
            onCelebrate = { showPurchase = false; onDismiss(); onCelebrate() },
            onHoldCameraWifi = onHoldCameraWifi,
            renew = true
        )
    }
    val subExp = LicenseManager.subExpiresAtSec()
    val daysLeft = subDaysLeft(subExp)
    val urgent = daysLeft <= SUB_WARN_DAYS

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(22.dp),
            color = colors.glassSurfaceHeavy,
            border = BorderStroke(1.dp, colors.glassPanelBorder),
            tonalElevation = 6.dp
        ) {
            Box {
                // 与解锁/购买弹窗同款毛玻璃高光
                Box(
                    Modifier
                        .matchParentSize()
                        .background(Brush.verticalGradient(listOf(colors.glassSheen, Color.Transparent)))
                )
                Column(Modifier.padding(20.dp)) {
                    // ---- 头部:金徽章 + "续费"标题/到期日副标 + 右上关闭(与 ProDialog 同构) ----
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
                                stringResource(R.string.renew_action),
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.Bold,
                                color = colors.onBackground
                            )
                            Text(
                                stringResource(R.string.sub_expires_on, formatSubDate(subExp)),
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.onSurfaceVariant
                            )
                        }
                        IconButton(onClick = onDismiss, modifier = Modifier.size(32.dp)) {
                            Icon(Icons.Default.Close, contentDescription = null, tint = colors.onSurfaceVariant)
                        }
                    }

                    Spacer(Modifier.height(16.dp))

                    // ---- 剩余天数:玻璃内卡居中一句。进 30 天转橙,与设置页原到期行同一门槛 ----
                    val cardShape = RoundedCornerShape(14.dp)
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .clip(cardShape)
                            .background(colors.onBackground.copy(alpha = 0.04f))
                            .border(1.dp, colors.glassPanelBorder, cardShape)
                            .padding(vertical = 14.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            pluralStringResource(R.plurals.sub_days_left, daysLeft, daysLeft),
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = if (urgent) colors.accentOrange else colors.onBackground
                        )
                    }

                    // ---- 续费价:与 ProDialog 同款促销排布(角标 + 金色现价 + 划线原价) ----
                    Spacer(Modifier.height(14.dp))
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.Center,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        if (price.originalFen > 0) {
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
                            stringResource(
                                R.string.price_per_year,
                                LicenseManager.formatPrice(price.priceFen)
                            ),
                            style = MaterialTheme.typography.headlineSmall,
                            fontWeight = FontWeight.Bold,
                            color = ProGold
                        )
                        if (price.originalFen > 0) {
                            Spacer(Modifier.width(8.dp))
                            Text(
                                stringResource(
                                    R.string.price_per_year,
                                    LicenseManager.formatPrice(price.originalFen)
                                ),
                                style = MaterialTheme.typography.bodyMedium,
                                textDecoration = TextDecoration.LineThrough,
                                color = colors.onSurfaceVariant
                            )
                        }
                    }
                    // 陈述续期规则(服务器按原到期日 + 365 天算),顺带让人明白提前续不亏。
                    Spacer(Modifier.height(4.dp))
                    Text(
                        stringResource(R.string.renew_carry_over),
                        style = MaterialTheme.typography.labelSmall,
                        color = colors.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth()
                    )

                    Spacer(Modifier.height(18.dp))

                    // ---- 主行动:全宽金色"续费",拉起支付流程 ----
                    ProBadgeButton(
                        label = stringResource(R.string.renew_action),
                        onClick = { showPurchase = true },
                        modifier = Modifier.fillMaxWidth(),
                        big = true
                    )
                }
            }
        }
    }
}

/**
 * 换机对话框(设置页脚"我要换机"打开):把激活码交到用户手上,并说清换机的代价。
 *
 * 单设备浮动授权——码在新机激活即顶替旧机(旧机自动掉回免费版),所以取码与告知后果
 * 必须同屏:用户点复制之前就该知道本机会被停用,以及外传会把码刷失效。
 * 激活码平时不出现在任何界面(购买成功页也不给):它是换机凭据,不是日常信息,
 * 只有主动走到这一步的人才需要它。
 */
@Composable
fun SwitchDeviceDialog(onDismiss: () -> Unit) {
    val colors = AppTheme.colors
    val clipboard = LocalClipboardManager.current
    // 非高级版拿不到码(purchasedCode 返回 null),此时本弹窗无内容可给,直接不出现。
    val code = LicenseManager.purchasedCode() ?: return
    var copied by remember { mutableStateOf(false) }

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(22.dp),
            color = colors.glassSurfaceHeavy,
            border = BorderStroke(1.dp, colors.glassPanelBorder),
            tonalElevation = 6.dp
        ) {
            Box {
                // 与解锁/购买弹窗同款毛玻璃高光
                Box(
                    Modifier
                        .matchParentSize()
                        .background(Brush.verticalGradient(listOf(colors.glassSheen, Color.Transparent)))
                )
                Column(Modifier.padding(20.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            stringResource(R.string.settings_view_code),
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = colors.onBackground,
                            modifier = Modifier.weight(1f)
                        )
                        IconButton(onClick = onDismiss, modifier = Modifier.size(32.dp)) {
                            Icon(
                                Icons.Default.Close,
                                contentDescription = stringResource(R.string.cd_close),
                                tint = colors.onSurfaceVariant
                            )
                        }
                    }
                    Spacer(Modifier.height(14.dp))
                    // ---- 码 + 复制:玻璃内卡(与设置分区卡、对比表同族)----
                    // 等宽字体 + 字距:6 位码要照着往新机上敲,O/0、I/1 必须一眼分得开。
                    val cardShape = RoundedCornerShape(14.dp)
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(cardShape)
                            .background(colors.onBackground.copy(alpha = 0.04f))
                            .border(1.dp, colors.glassPanelBorder, cardShape)
                            .padding(start = 16.dp, end = 10.dp, top = 10.dp, bottom = 10.dp)
                    ) {
                        Text(
                            code,
                            style = MaterialTheme.typography.headlineSmall,
                            fontWeight = FontWeight.Bold,
                            fontFamily = FontFamily.Monospace,
                            letterSpacing = 2.sp,
                            color = colors.onBackground,
                            modifier = Modifier.weight(1f)
                        )
                        GlassButton(
                            onClick = {
                                clipboard.setText(AnnotatedString(code))
                                copied = true
                            },
                            shape = RoundedCornerShape(12.dp),
                            panel = true,
                            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp)
                        ) {
                            Text(
                                stringResource(if (copied) R.string.code_copied else R.string.copy_code),
                                style = MaterialTheme.typography.labelLarge,
                                fontWeight = FontWeight.SemiBold,
                                color = if (copied) colors.statusConnected else colors.accentBlue
                            )
                        }
                    }
                    Spacer(Modifier.height(12.dp))
                    Text(
                        stringResource(R.string.settings_code_hint),
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.onSurfaceVariant
                    )
                }
            }
        }
    }
}

/**
 * 购买页次级玻璃按钮的统一文字:撑满按钮内宽居中——
 * 三个按钮平分整行(weight)后各自内容区是定宽,不撑满文字会贴左。
 */
@Composable
private fun SubActionLabel(text: String) {
    val colors = AppTheme.colors
    Text(
        text,
        style = MaterialTheme.typography.labelMedium,
        fontWeight = FontWeight.SemiBold,
        color = colors.accentBlue,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth()
    )
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
