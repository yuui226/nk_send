package com.ztransfer.ui.screen

import android.provider.DocumentsContract
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.ztransfer.AppLocale
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import com.ztransfer.update.AppUpdateManager
import com.ztransfer.ui.theme.*
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

// 客服/购买 QQ 号（用户使用场景多为连着相机 Wi-Fi 无外网，只能靠复制号码离线联系）。
internal const val QQ_NUMBER = "953000922"
// 定价不在这里了:由服务端下发(LicenseManager.pricing),改价改服务器的 pricing.json 即可,
// 不用发版。兜底常量见 LicenseManager.FALLBACK_PRICE_FEN。

/**
 * 轻量设置面板（全屏覆盖层，非系统 Dialog），从顶栏设置按钮变形弹出、关闭缩回按钮
 * （见 [AnchorPopup]）。内容按功能分为三块玻璃分区卡片：传输目录 / 显示 / 通用，
 * 每块内部用细分隔线切分子项——区域清晰、留白克制，替代旧版一长条竖列。
 */
@Composable
fun SettingsOverlay(
    viewModel: TransferViewModel,
    anchorBounds: Rect?,
    onDismiss: () -> Unit,
    // 已解锁时右上角徽标点击的回调（放烟花彩蛋）；由承载页提供其页面级 FireworksState。
    onPlayFireworks: () -> Unit = {},
    // 手动检查更新时只做本地判断：连着相机热点就提示需要互联网，不发无意义请求。
    cameraUsesWifi: Boolean = false,
    // 购买期间临时松开对相机 Wi-Fi 的占用（相机热点没外网，付款联不上）；由承载页接到 CameraViewModel。
    onHoldCameraWifi: (Boolean) -> Unit = {}
) {
    val state by viewModel.state.collectAsState()
    val colors = AppTheme.colors
    val isPro by LicenseManager.isPro.collectAsState()

    val directoryPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocumentTree()
    ) { uri ->
        // 持久化授权在 setTransferDirUri 内统一处理，这里不重复申请。
        uri?.let { viewModel.setTransferDirUri(it) }
    }

    // try/catch 内不能调用 composable，回退文案先在组合期取出。
    val dirSetFallback = stringResource(R.string.dir_set)
    val dirText: String? = state.transferDirUri?.let { dir ->
        try {
            val uri = android.net.Uri.parse(dir)
            val docId = DocumentsContract.getTreeDocumentId(uri)
            if (docId.startsWith("primary:")) "/sdcard/${docId.removePrefix("primary:")}" else docId
        } catch (e: Exception) {
            dirSetFallback
        }
    }

    // 右上角"解锁高级版"徽标打开的介绍对话框（免费/高级版对比 + 解锁按钮复制 QQ 号）。
    var showPro by remember { mutableStateOf(false) }
    // 页脚"我要换机"打开的对话框（取激活码 + 换机后果告知）。
    var showSwitchDevice by remember { mutableStateOf(false) }
    val subExpired by LicenseManager.subExpired.collectAsState()

    // 页脚底部玻璃提示（反馈复制确认 / 隐藏入口的恢复免费版确认共用）；
    // 文案与可见性分开存，消失动画期间仍有文字可渲染；nonce 保证连续触发重启计时。
    val clipboard = LocalClipboardManager.current
    var footerHintText by remember { mutableStateOf("") }
    var footerHintVisible by remember { mutableStateOf(false) }
    var footerHintNonce by remember { mutableStateOf(0) }
    fun showFooterHint(text: String) {
        footerHintText = text
        footerHintVisible = true
        footerHintNonce++
    }
    LaunchedEffect(footerHintNonce) {
        if (footerHintVisible) {
            delay(1800)
            footerHintVisible = false
        }
    }

    // 面板顶边贴按钮下缘 + 8dp；按钮尚未测量时按顶栏下方近似定位。
    val density = LocalDensity.current
    val panelTop = if (anchorBounds != null) {
        with(density) { anchorBounds.bottom.toDp() } + 8.dp
    } else 76.dp

    AnchorPopup(
        anchorBounds = anchorBounds,
        onDismiss = onDismiss,
        panelModifier = Modifier
            .padding(start = 12.dp, end = 12.dp, top = panelTop)
            .navigationBarsPadding()   // 小屏时面板底部不顶进导航栏
            .fillMaxWidth(),
        overlayContent = {
            // 底部玻璃提示（与列表页提示条同款视觉）：文案由触发方传入。
            AnimatedVisibility(
                visible = footerHintVisible,
                enter = fadeIn() + slideInVertically { it / 2 },
                exit = fadeOut() + slideOutVertically { it / 2 },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .navigationBarsPadding()
                    .padding(bottom = 28.dp)
            ) {
                Surface(
                    shape = RoundedCornerShape(18.dp),
                    color = colors.glassSurfaceHeavy,
                    shadowElevation = 6.dp,
                    border = BorderStroke(1.dp, colors.glassPanelBorder)
                ) {
                    Text(
                        text = footerHintText,
                        textAlign = TextAlign.Center,
                        style = MaterialTheme.typography.labelLarge,
                        color = colors.onBackground,
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp)
                    )
                }
            }
        }
    ) { close ->
        Column(
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .padding(16.dp)
        ) {
            // ---------- 标题栏：标题 + 右上角"高级版"入口（全 app 唯一购买入口）+ 关闭 ----------
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    stringResource(R.string.settings),
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    color = colors.onBackground
                )
                Spacer(Modifier.weight(1f))
                // 未解锁：金徽标"解锁高级版"，点击开介绍弹窗。
                // 已解锁：金徽标改显"高级版"，点击不弹窗，放烟花彩蛋（与连接页同一效果）。
                if (isPro) {
                    ProBadgeButton(
                        label = stringResource(R.string.pro_label),
                        onClick = onPlayFireworks
                    )
                } else {
                    ProBadgeButton(
                        label = stringResource(R.string.unlock_pro),
                        onClick = { showPro = true }
                    )
                }
                Spacer(Modifier.width(8.dp))
                IconButton(onClick = close, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Default.Close, contentDescription = stringResource(R.string.cd_close), tint = colors.onSurfaceVariant)
                }
            }
            if (showPro) {
                ProDialog(
                    onDismiss = { showPro = false },
                    onCelebrate = onPlayFireworks,
                    onHoldCameraWifi = onHoldCameraWifi,
                    // 到期的老用户从这里再买 = 续原来那个码,不发新码。
                    renew = subExpired
                )
            }

            // 到期日与续费入口不放这儿:裸在面板上显乱,已挪到连接页徽标左侧的"续费"
            // 玻璃按钮(点开 RenewDialog);那里也是全 app 唯一确定有外网、付得了款的页面。

            Spacer(Modifier.height(14.dp))

            // ---------- 卡片一：传输目录（标题行右上放"更改"按钮，路径独占下方整行）----------
            // "更改"按钮上移到标题行：长路径在下方整行展示、最多两行省略，不再被按钮抢宽度遮挡。
            // 未设目录时橙色描边强调：因点图未设目录被弹到这里的新用户能立刻明白来意。
            SettingsCard(
                borderColor = if (dirText == null) colors.accentOrange.copy(alpha = 0.8f) else colors.glassPanelBorder
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(modifier = Modifier.weight(1f)) {
                        SectionLabel(stringResource(R.string.transfer_directory))
                    }
                    Spacer(Modifier.width(10.dp))
                    GlassButton(
                        onClick = { directoryPicker.launch(null) },
                        shape = RoundedCornerShape(12.dp),
                        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 6.dp),
                        modifier = Modifier.height(30.dp)
                    ) {
                        Icon(Icons.Default.Edit, contentDescription = null, tint = colors.accentBlue, modifier = Modifier.size(14.dp))
                        Text(
                            stringResource(if (dirText != null) R.string.change_directory else R.string.choose_directory),
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.SemiBold,
                            color = colors.onBackground
                        )
                    }
                }
                Spacer(Modifier.height(10.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Default.LocationOn,
                        contentDescription = null,
                        tint = if (dirText != null) colors.statusConnected else colors.accentOrange,
                        modifier = Modifier.size(16.dp)
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = dirText ?: stringResource(R.string.dir_not_set),
                        style = MaterialTheme.typography.bodyMedium,
                        color = if (dirText != null) colors.onBackground else colors.onSurfaceVariant,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f)
                    )
                }
            }

            Spacer(Modifier.height(12.dp))

            // ---------- 卡片二：显示（列数 / 外观 / 语言）----------
            SettingsCard {
                // 每行列数
                SectionLabel(stringResource(R.string.columns))
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    (1..4).forEach { col ->
                        SelectionChip(
                            label = "$col",
                            selected = state.thumbnailColumns == col,
                            onClick = { viewModel.setThumbnailColumns(col) },
                            textStyle = MaterialTheme.typography.titleMedium,
                            modifier = Modifier.weight(1f)
                        )
                    }
                }

                CardDivider()

                // 外观（深浅色主题）
                SectionLabel(stringResource(R.string.appearance))
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ThemeMode.entries.forEach { mode ->
                        SelectionChip(
                            label = stringResource(when (mode) {
                                ThemeMode.SYSTEM -> R.string.theme_system
                                ThemeMode.DARK -> R.string.theme_dark
                                ThemeMode.LIGHT -> R.string.theme_light
                            }),
                            selected = state.themeMode == mode,
                            onClick = { viewModel.setThemeMode(mode) },
                            modifier = Modifier.weight(1f)
                        )
                    }
                }

                CardDivider()

                // 语言：收起时只占一行（标签 + 当前语言小玻璃按钮），点按钮向下展开选项。
                // 语言名一律用其自身语言书写（国际惯例，不随界面语言翻译），仅"跟随系统"本地化。
                val languages = listOf(
                    AppLocale.SYSTEM to stringResource(R.string.language_system),
                    "en" to "English",
                    "zh-Hans" to "简体中文",
                    "zh-Hant" to "繁體中文"
                )
                val activity = LocalContext.current.findActivity()
                var languageExpanded by remember { mutableStateOf(false) }
                val chevron by animateFloatAsState(
                    targetValue = if (languageExpanded) 180f else 0f,
                    label = "langChevron"
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(modifier = Modifier.weight(1f)) {
                        SectionLabel(stringResource(R.string.language))
                    }
                    GlassButton(
                        onClick = { languageExpanded = !languageExpanded },
                        shape = RoundedCornerShape(14.dp),
                        contentPadding = PaddingValues(start = 14.dp, end = 8.dp),
                        modifier = Modifier.height(28.dp)
                    ) {
                        Text(
                            languages.firstOrNull { it.first == state.appLanguage }?.second
                                ?: languages.first().second,
                            style = MaterialTheme.typography.labelMedium,
                            color = colors.onBackground
                        )
                        Icon(
                            Icons.Default.KeyboardArrowDown,
                            contentDescription = null,
                            tint = colors.onSurfaceVariant,
                            modifier = Modifier
                                .size(16.dp)
                                .graphicsLayer { rotationZ = chevron }
                        )
                    }
                }
                AnimatedVisibility(
                    visible = languageExpanded,
                    enter = fadeIn() + expandVertically(),
                    exit = fadeOut() + shrinkVertically()
                ) {
                    Column {
                        Spacer(Modifier.height(8.dp))
                        languages.chunked(2).forEachIndexed { rowIndex, rowItems ->
                            if (rowIndex > 0) Spacer(Modifier.height(8.dp))
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                rowItems.forEach { (tag, label) ->
                                    val selected = state.appLanguage == tag
                                    SelectionChip(
                                        label = label,
                                        selected = selected,
                                        onClick = {
                                            if (!selected) {
                                                viewModel.setAppLanguage(tag)
                                                // attachBaseContext 在重建时重读偏好，语言即刻生效。
                                                activity?.recreate()
                                            }
                                        },
                                        modifier = Modifier.weight(1f)
                                    )
                                }
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(12.dp))

            // ---------- 卡片三：通用（触感反馈 / 屏幕常亮）----------
            SettingsCard {
                // 触感反馈
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(modifier = Modifier.weight(1f)) {
                        SectionLabel(stringResource(R.string.haptic_feedback))
                    }
                    Switch(
                        checked = state.hapticsEnabled,
                        onCheckedChange = { viewModel.setHapticsEnabled(it) }
                    )
                }

                CardDivider()

                // 屏幕常亮（默认开）：前台不熄屏，防系统冻结进程/Wi-Fi 打盹断连。
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f)) {
                        SectionLabel(stringResource(R.string.keep_screen_on))
                        Spacer(Modifier.height(2.dp))
                        Text(
                            stringResource(R.string.keep_screen_on_desc),
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    Switch(
                        checked = state.keepScreenOn,
                        onCheckedChange = { viewModel.setKeepScreenOn(it) }
                    )
                }
            }

            Spacer(Modifier.height(14.dp))

            // ---------- 页脚：左侧版本号，右侧毛玻璃"反馈"按钮（点击复制 QQ 号）----------
            // 版本号兼作隐蔽调试入口：已解锁时 1.5s 内连点 7 次恢复免费版（只清本地
            // 通行证，重新输入激活码即恢复）——发版前自测免费限制用。无水波纹、
            // 无任何视觉暗示，成功才弹底部确认。
            var versionTaps by remember { mutableStateOf(0) }
            var lastVersionTapAt by remember { mutableStateOf(0L) }
            val revertedHint = stringResource(R.string.revert_free)
            val qqCopiedHint = stringResource(R.string.feedback_qq_copied, QQ_NUMBER)
            // 手动检查会绕过自动检查间隔和“忽略此版本”。有新版直接显示更新弹窗；
            // 无新版或检查失败才在页脚显示短提示。
            var checkingUpdate by remember { mutableStateOf(false) }
            val updateScope = rememberCoroutineScope()
            val latestHint = stringResource(R.string.update_latest)
            val checkFailedHint = stringResource(R.string.update_check_failed)
            val internetRequiredHint = stringResource(R.string.err_purchase_no_network)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = stringResource(R.string.version_label, BuildConfig.VERSION_NAME),
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.onSurfaceVariant.copy(alpha = 0.7f),
                    modifier = Modifier.clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null
                    ) {
                        val now = System.currentTimeMillis()
                        versionTaps = if (now - lastVersionTapAt < 1500) versionTaps + 1 else 1
                        lastVersionTapAt = now
                        if (versionTaps >= 7 && isPro) {
                            versionTaps = 0
                            LicenseManager.revertToFree()
                            showFooterHint(revertedHint)
                        }
                    }
                )
                Spacer(Modifier.weight(1f))
                GlassButton(
                    onClick = {
                        if (cameraUsesWifi) {
                            showFooterHint(internetRequiredHint)
                        } else if (!checkingUpdate) {
                            checkingUpdate = true
                            updateScope.launch {
                                when (AppUpdateManager.check(force = true)) {
                                    is LicenseManager.UpdateResult.Available -> Unit
                                    LicenseManager.UpdateResult.UpToDate -> showFooterHint(latestHint)
                                    LicenseManager.UpdateResult.Unreachable -> showFooterHint(checkFailedHint)
                                }
                                checkingUpdate = false
                            }
                        }
                    },
                    shape = RoundedCornerShape(14.dp),
                    contentPadding = PaddingValues(horizontal = 14.dp),
                    modifier = Modifier.height(28.dp)
                ) {
                    Text(
                        stringResource(if (checkingUpdate) R.string.checking_update else R.string.check_update),
                        style = MaterialTheme.typography.labelMedium,
                        color = colors.onBackground
                    )
                }
                Spacer(Modifier.width(8.dp))
                // 高级版专属"我要换机":与"反馈"并列在页脚——都是不常用的出口动作,
                // 一年用一次的东西不该占正文位置。取码与换机后果都在弹窗里说。
                if (isPro) {
                    GlassButton(
                        onClick = { showSwitchDevice = true },
                        shape = RoundedCornerShape(14.dp),
                        contentPadding = PaddingValues(horizontal = 14.dp),
                        modifier = Modifier.height(28.dp)
                    ) {
                        Text(
                            stringResource(R.string.settings_view_code),
                            style = MaterialTheme.typography.labelMedium,
                            color = colors.onBackground
                        )
                    }
                    Spacer(Modifier.width(8.dp))
                }
                GlassButton(
                    onClick = {
                        clipboard.setText(AnnotatedString(QQ_NUMBER))
                        showFooterHint(qqCopiedHint)
                    },
                    shape = RoundedCornerShape(14.dp),
                    contentPadding = PaddingValues(horizontal = 14.dp),
                    modifier = Modifier.height(28.dp)
                ) {
                    Text(
                        stringResource(R.string.feedback),
                        style = MaterialTheme.typography.labelMedium,
                        color = colors.onBackground
                    )
                }
            }
            if (showSwitchDevice) {
                SwitchDeviceDialog(onDismiss = { showSwitchDevice = false })
            }
        }
    }
}

/**
 * 设置分区卡片：面板内的一块玻璃子容器——极淡的内嵌底色 + 细描边圆角，
 * 把相关设置聚成一个视觉区域。[borderColor] 可覆盖描边（如目录未设时橙色强调）。
 */
@Composable
private fun SettingsCard(
    modifier: Modifier = Modifier,
    borderColor: Color = AppTheme.colors.glassPanelBorder,
    content: @Composable ColumnScope.() -> Unit
) {
    val shape = RoundedCornerShape(14.dp)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            // onBackground 极低透明度：深色主题下是白色微提亮、浅色下是黑色微压暗，两套都成立。
            .background(AppTheme.colors.onBackground.copy(alpha = 0.04f))
            .border(1.dp, borderColor, shape)
            .padding(14.dp),
        content = content
    )
}

/** 卡片内子项之间的细分隔线（上下留呼吸间距）。 */
@Composable
private fun CardDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 12.dp)
            .height(1.dp)
            .background(AppTheme.colors.glassPanelBorder)
    )
}

/**
 * 金色闪亮胶囊按钮（购买入口专用）：金渐变 + 缓慢周期性扫过的高光，
 * 刻意比周围的玻璃元素更亮眼。入口处 [label] 用"解锁高级版"/"高级版"，
 * ProDialog 内的购买主按钮用 [big]=true 的大号形态（配 fillMaxWidth 使用，内容居中）。
 * 金色在深浅两套主题下都成立，文字/图标用深棕保证对比度。
 */
@Composable
internal fun ProBadgeButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    big: Boolean = false
) {
    // 高光带相位：-1（完全在按钮左侧外）扫到 +2（完全出右侧），尾段停顿让闪光有呼吸感。
    val sheen = rememberInfiniteTransition(label = "proSheen")
    val sheenX by sheen.animateFloat(
        initialValue = -1f,
        targetValue = 2f,
        animationSpec = infiniteRepeatable(
            animation = tween(2600, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "proSheenX"
    )
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(if (big) 16.dp else 14.dp),
        color = Color.Transparent,
        shadowElevation = 4.dp,
        modifier = modifier.height(if (big) 46.dp else 28.dp)
    ) {
        Box(
            // big（定宽定高）需铺满 Surface 让内容居中；小号保持包裹内容，别撑满屏宽。
            modifier = (if (big) Modifier.fillMaxSize() else Modifier).background(
                Brush.verticalGradient(listOf(Color(0xFFFFE082), Color(0xFFF0A93B)))
            ),
            contentAlignment = Alignment.Center
        ) {
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .graphicsLayer { translationX = size.width * sheenX }
                    .background(
                        Brush.horizontalGradient(
                            listOf(Color.Transparent, Color.White.copy(alpha = 0.55f), Color.Transparent)
                        )
                    )
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(if (big) 6.dp else 4.dp),
                modifier = Modifier
                    .fillMaxHeight()
                    .padding(horizontal = 12.dp)
            ) {
                Icon(
                    Icons.Default.WorkspacePremium,
                    contentDescription = null,
                    tint = Color(0xFF5D4023),
                    modifier = Modifier.size(if (big) 19.dp else 15.dp)
                )
                Text(
                    label,
                    style = if (big) MaterialTheme.typography.labelLarge else MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Bold,
                    color = Color(0xFF4A3216)
                )
            }
        }
    }
}

/** 设置面板的选中态胶囊（列数/外观/语言三组选项共用）：选中 = 主题蓝底 + 反色字。 */
@Composable
private fun SelectionChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    textStyle: TextStyle = MaterialTheme.typography.labelLarge
) {
    val colors = AppTheme.colors
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(8.dp),
        color = if (selected) colors.accentBlue else colors.surfaceVariant,
        modifier = modifier.height(40.dp)
    ) {
        Box(contentAlignment = Alignment.Center) {
            Text(
                text = label,
                style = textStyle,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
                color = if (selected) colors.onAccent else colors.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        fontWeight = FontWeight.SemiBold,
        color = AppTheme.colors.onBackground
    )
}
