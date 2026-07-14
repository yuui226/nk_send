package com.ztransfer.ui.screen

import android.provider.DocumentsContract
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
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
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
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
import com.ztransfer.ui.theme.*
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.delay

// 客服/购买 QQ 号（用户使用场景多为连着相机 Wi-Fi 无外网，只能靠复制号码离线联系）。
internal const val QQ_NUMBER = "953000922"
// 高级版展示定价（纯文案，改价只动这里）。留空 = 弹窗不显示价格行（定价未定）。
internal const val PRO_PRICE = ""

/**
 * 轻量设置面板（全屏覆盖层，非系统 Dialog），下拉弹窗观感：
 * 面板顶边贴在触发按钮（[anchorBounds]，在同一 Compose 根坐标系）下缘、左缘与按钮对齐，
 * 以按钮中心为缩放原点"从按钮变形展开"（原点在面板左上角附近，展开方向自然朝右下），
 * 关闭时反向收回到按钮再消失。放在与按钮同一 composition 内，避免跨窗口坐标不一致。
 */
@Composable
fun SettingsOverlay(
    viewModel: TransferViewModel,
    anchorBounds: Rect?,
    onDismiss: () -> Unit
) {
    val state by viewModel.state.collectAsState()
    val colors = AppTheme.colors

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

    // 变形动画进度：0=收在按钮处（不可见），1=完全展开。
    var panelBounds by remember { mutableStateOf<Rect?>(null) }
    val progress = remember { Animatable(0f) }
    var closing by remember { mutableStateOf(false) }

    // 右上角"解锁高级版"徽标打开的介绍对话框（免费/高级版对比 + 解锁按钮复制 QQ 号）。
    var showPro by remember { mutableStateOf(false) }

    // 页脚"反馈"按钮复制 QQ 号后的底部提示；nonce 保证连续点击重启计时。
    val clipboard = LocalClipboardManager.current
    var feedbackCopied by remember { mutableStateOf(false) }
    var feedbackNonce by remember { mutableStateOf(0) }
    LaunchedEffect(feedbackNonce) {
        if (feedbackCopied) {
            delay(1800)
            feedbackCopied = false
        }
    }

    // 面板测量完成即入场展开。
    LaunchedEffect(panelBounds, closing) {
        if (!closing && panelBounds != null && progress.value < 1f) {
            progress.animateTo(1f, Motion.overlayExpand)
        }
    }
    // 关闭：反向收回后再真正移除。
    LaunchedEffect(closing) {
        if (closing) {
            progress.animateTo(0f, Motion.overlayCollapse)
            onDismiss()
        }
    }
    val startClose: () -> Unit = { closing = true }

    BackHandler(enabled = !closing) { startClose() }

    Box(modifier = Modifier.fillMaxSize()) {
        // 遮罩：随进度淡入；点击外部关闭。拖动一并消费，防止滚动穿透到底下的列表。
        Box(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer { alpha = progress.value }
                .background(colors.scrim)
                .pointerInput(Unit) { detectTapGestures { startClose() } }
                .pointerInput(Unit) { detectDragGestures { change, _ -> change.consume() } }
        )

        // 面板：贴在按钮下缘的下拉位置，以按钮中心为原点缩放展开。
        // 顶边 = 按钮底边 + 8dp（padding 参与测量，剩余高度自动约束，内容超出由内部滚动兜底）。
        val density = LocalDensity.current
        val panelTop = if (anchorBounds != null) {
            with(density) { anchorBounds.bottom.toDp() } + 8.dp
        } else 76.dp   // 兜底：按钮尚未测量时按顶栏下方近似定位
        Surface(
            modifier = Modifier
                .align(Alignment.TopStart)
                .padding(start = 12.dp, end = 12.dp, top = panelTop)
                .navigationBarsPadding()   // 小屏时面板底部不顶进导航栏
                .fillMaxWidth()
                .onGloballyPositioned { panelBounds = it.boundsInRoot() }
                .graphicsLayer {
                    val b = panelBounds
                    if (b != null && b.width > 0f && b.height > 0f && anchorBounds != null) {
                        // 按钮中心相对于面板自身的比例位置（可超出 0..1，即原点落在面板外）。
                        transformOrigin = TransformOrigin(
                            (anchorBounds.center.x - b.left) / b.width,
                            (anchorBounds.center.y - b.top) / b.height
                        )
                    }
                    val p = progress.value
                    // 从"约按钮大小"(6%)在按钮位置放大到全尺寸——明显地"从 Z传 按钮长出来"，
                    // 关闭时反向缩回按钮再消失（从哪来回哪去）。
                    val s = 0.06f + 0.94f * p
                    scaleX = s
                    scaleY = s
                    // 透明度更快到达不透明，放大过程中面板已清晰可见。
                    alpha = (p * 2f).coerceAtMost(1f)
                }
                // 消费面板内点击，避免穿透到遮罩误关闭。
                .pointerInput(Unit) { detectTapGestures { } },
            shape = RoundedCornerShape(20.dp),
            // 毛玻璃：底色保持较高不透明度（不那么透明，保证可读）+ 细描边。
            color = colors.glassSurfaceHeavy,
            border = BorderStroke(1.dp, colors.glassPanelBorder),
            tonalElevation = 6.dp
        ) {
          Box {
            // 自上而下淡出的高光叠层，营造毛玻璃质感。
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .background(
                        Brush.verticalGradient(
                            listOf(colors.glassSheen, Color.Transparent)
                        )
                    )
            )
            Column(
                modifier = Modifier
                    .verticalScroll(rememberScrollState())
                    .padding(20.dp)
            ) {
                // 标题栏：标题 + 右上角"高级版"入口（全 app 唯一购买入口）+ 关闭。
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        stringResource(R.string.settings),
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = colors.onBackground
                    )
                    Spacer(Modifier.weight(1f))
                    ProBadgeButton(
                        label = stringResource(R.string.unlock_pro),
                        onClick = { showPro = true }
                    )
                    Spacer(Modifier.width(8.dp))
                    IconButton(onClick = startClose, modifier = Modifier.size(32.dp)) {
                        Icon(Icons.Default.Close, contentDescription = stringResource(R.string.cd_close), tint = colors.onSurfaceVariant)
                    }
                }
                if (showPro) {
                    ProDialog(onDismiss = { showPro = false })
                }

                Spacer(Modifier.height(16.dp))

                // ---------- 传输目录 ----------
                SectionLabel(stringResource(R.string.transfer_directory))
                Spacer(Modifier.height(8.dp))
                Surface(
                    shape = RoundedCornerShape(10.dp),
                    color = colors.surfaceVariant,
                    // 未设目录时橙色描边强调：因点图未设目录被弹到这里的新用户能立刻明白来意。
                    border = if (dirText == null) BorderStroke(1.dp, colors.accentOrange.copy(alpha = 0.8f)) else null,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier.padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
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
                Spacer(Modifier.height(10.dp))
                Button(
                    onClick = { directoryPicker.launch(null) },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = colors.accentBlue),
                    shape = RoundedCornerShape(12.dp)
                ) {
                    Icon(Icons.Default.Edit, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(if (dirText != null) R.string.change_directory else R.string.choose_directory))
                }

                Spacer(Modifier.height(20.dp))

                // ---------- 每行列数 ----------
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

                Spacer(Modifier.height(20.dp))

                // ---------- 外观（深浅色主题）----------
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

                Spacer(Modifier.height(20.dp))

                // ---------- 语言：收起时只占一行（标签 + 当前语言小玻璃按钮），
                // 点按钮向下展开选项，比常驻 2×2 大胶囊省一大截面板高度 ----------
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
                    Column(modifier = Modifier.weight(1f)) {
                        SectionLabel(stringResource(R.string.language))
                    }
                    // 与页脚"反馈"按钮同款规格的小玻璃按钮，显示当前语言 + 展开箭头。
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

                Spacer(Modifier.height(20.dp))

                // ---------- 触感反馈 ----------
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f)) {
                        SectionLabel(stringResource(R.string.haptic_feedback))
                    }
                    Switch(
                        checked = state.hapticsEnabled,
                        onCheckedChange = { viewModel.setHapticsEnabled(it) }
                    )
                }

                Spacer(Modifier.height(20.dp))

                // ---------- 屏幕常亮（默认开）：前台不熄屏，防系统冻结进程/Wi-Fi 打盹断连 ----------
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f)) {
                        SectionLabel(stringResource(R.string.keep_screen_on))
                        Text(
                            stringResource(R.string.keep_screen_on_desc),
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant
                        )
                    }
                    Switch(
                        checked = state.keepScreenOn,
                        onCheckedChange = { viewModel.setKeepScreenOn(it) }
                    )
                }

                Spacer(Modifier.height(20.dp))

                // ---------- 页脚：左侧版本号，右侧毛玻璃"反馈"按钮（点击复制 QQ 号，
                // 面板底部弹玻璃提示：请加 QQ 反馈）----------
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = stringResource(R.string.version_label, BuildConfig.VERSION_NAME),
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.onSurfaceVariant.copy(alpha = 0.7f)
                    )
                    Spacer(Modifier.weight(1f))
                    GlassButton(
                        onClick = {
                            clipboard.setText(AnnotatedString(QQ_NUMBER))
                            feedbackCopied = true
                            feedbackNonce++
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
            }
          }
        }

        // 底部玻璃提示：反馈按钮复制 QQ 号后的确认（与列表页提示条同款视觉），在遮罩与面板之上。
        AnimatedVisibility(
            visible = feedbackCopied,
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
                    text = stringResource(R.string.feedback_qq_copied, QQ_NUMBER),
                    textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.labelLarge,
                    color = colors.onBackground,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp)
                )
            }
        }
    }
}

/**
 * 金色闪亮胶囊按钮（购买入口专用）：金渐变 + 缓慢周期性扫过的高光，
 * 刻意比周围的玻璃元素更亮眼。入口处 [label] 用"解锁高级版"，
 * ProDialog 内的确认按钮用"解锁"。金色在深浅两套主题下都成立，
 * 文字/图标用深棕保证对比度。
 */
@Composable
internal fun ProBadgeButton(label: String, onClick: () -> Unit) {
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
        shape = RoundedCornerShape(14.dp),
        color = Color.Transparent,
        shadowElevation = 4.dp,
        modifier = Modifier.height(28.dp)
    ) {
        Box(
            modifier = Modifier.background(
                Brush.verticalGradient(listOf(Color(0xFFFFE082), Color(0xFFF0A93B)))
            )
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
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                modifier = Modifier
                    .fillMaxHeight()
                    .padding(horizontal = 12.dp)
            ) {
                Icon(
                    Icons.Default.WorkspacePremium,
                    contentDescription = null,
                    tint = Color(0xFF5D4023),
                    modifier = Modifier.size(15.dp)
                )
                Text(
                    label,
                    style = MaterialTheme.typography.labelMedium,
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
