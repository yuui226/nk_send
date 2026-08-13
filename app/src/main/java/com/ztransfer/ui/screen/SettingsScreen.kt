package com.ztransfer.ui.screen

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Shader
import android.provider.DocumentsContract
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
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
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.ztransfer.AppLocale
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.effects.FavoriteFrameWatermarkEffect
import com.ztransfer.effects.FavoritePhotoFilter
import com.ztransfer.effects.orderWithFavorites
import com.ztransfer.frame.PhotoFrameExporter
import com.ztransfer.frame.PhotoFrameMetadata
import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.PhotoFrameWatermarkColor
import com.ztransfer.frame.PhotoFrameWatermarkContent
import com.ztransfer.frame.PhotoFrameWatermarkEffect
import com.ztransfer.frame.PhotoFrameWatermarkFont
import com.ztransfer.frame.PhotoFrameWatermarkPosition
import com.ztransfer.frame.DEFAULT_PHOTO_FRAME_WATERMARK_TEXT
import com.ztransfer.frame.MAX_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT
import com.ztransfer.frame.MAX_PHOTO_FRAME_WATERMARK_SIZE_PERCENT
import com.ztransfer.frame.MIN_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT
import com.ztransfer.frame.MIN_PHOTO_FRAME_WATERMARK_SIZE_PERCENT
import com.ztransfer.frame.limitPhotoFrameWatermarkText
import com.ztransfer.frame.isPhotoPlacement
import com.ztransfer.frame.normalizeCaptureDateTime
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.filter.BuiltInPhotoFilters
import com.ztransfer.filter.PhotoFilterRenderer
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.filter.normalizePhotoFilterIntensity
import com.ztransfer.filter.DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT
import com.ztransfer.license.LicenseManager
import com.ztransfer.update.AppUpdateManager
import com.ztransfer.ui.theme.*
import com.ztransfer.ui.util.rememberHaptics
import com.ztransfer.viewmodel.TransferViewModel
import com.ztransfer.viewmodel.PhotoExif
import com.ztransfer.viewmodel.effectivePhotoFrameWatermark
import com.ztransfer.viewmodel.freeEditionPhotoFrameWatermark
import com.ztransfer.viewmodel.photoFrameWatermark
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

// 客服/购买 QQ 号（用户使用场景多为连着相机 Wi-Fi 无外网，只能靠复制号码离线联系）。
internal const val QQ_NUMBER = "953000922"
// 定价不在这里了:由服务端下发(LicenseManager.pricing),改价改服务器的 pricing.json 即可,
// 不用发版。兜底常量见 LicenseManager.FALLBACK_PRICE_FEN。

private enum class SettingsPage { MAIN, EFFECTS }

internal fun transferDirectoryNeedsAttention(
    requested: Boolean,
    isDirectorySet: Boolean,
): Boolean = requested && !isDirectorySet

/**
 * 轻量设置面板（全屏覆盖层，非系统 Dialog），从顶栏设置按钮变形弹出、关闭缩回按钮
 * （见 [AnchorPopup]）。内容按功能分为四块玻璃分区卡片：传输目录 / 照片列表 / 通用 / 界面，
 * 每块内部用细分隔线切分子项——区域清晰、留白克制，替代旧版一长条竖列。
 */
@Composable
fun SettingsOverlay(
    viewModel: TransferViewModel,
    showPhotoEffectsEntry: Boolean = true,
    effectPreviewSource: Bitmap? = null,
    effectPreviewCameraManufacturer: String? = null,
    effectPreviewCameraModel: String? = null,
    effectPreviewExif: PhotoExif? = null,
    requestTransferDirectoryAttention: Boolean = false,
    onEffectPreviewRequested: () -> Unit = {},
    anchorBounds: Rect?,
    onDismiss: () -> Unit,
    // 已解锁时右上角徽标点击的回调（放烟花彩蛋）；由承载页提供其页面级 FireworksState。
    onPlayFireworks: () -> Unit = {},
    // 购买期间临时松开对相机 Wi-Fi 的占用（相机热点没外网，付款联不上）；由承载页接到 CameraViewModel。
    onHoldCameraWifi: (Boolean) -> Unit = {}
) {
    val state by viewModel.state.collectAsState()
    // 弹窗一出现就开始准备效果演示图；ViewModel 会按照片身份去重，重复打开不重复读取。
    LaunchedEffect(Unit) { onEffectPreviewRequested() }
    val colors = AppTheme.colors
    val isPro by LicenseManager.isPro.collectAsState()
    val haptics = rememberHaptics(state.hapticsEnabled)
    val context = LocalContext.current
    val activity = context.findActivity()
    val keyboardController = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current
    val effectPreviewMetadata = remember(
        effectPreviewCameraManufacturer,
        effectPreviewCameraModel,
        effectPreviewExif,
    ) {
        cameraEffectPreviewMetadata(
            manufacturer = effectPreviewCameraManufacturer,
            model = effectPreviewCameraModel,
            exif = effectPreviewExif,
        )
    }
    // 当前语言依赖 attachBaseContext，在 Activity 重建后才会全局生效。拨轮提交后走弹窗
    // 自己的 close 动画；此标记让动画完成回调知道随后需要重建，而不是当场硬切页面。
    var recreateAfterDismiss by remember { mutableStateOf(false) }
    // 弹窗打开后锁定入口位置。按钮风格切换会让外部 GlassButton 更换实现并重新测量；
    // 若继续跟踪实时 anchor，面板会在用户眼前上下跳动，关闭动画的归宿也会漂移。
    val openingAnchorBounds = remember { anchorBounds }

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
    val directoryAttentionActive = transferDirectoryNeedsAttention(
        requested = requestTransferDirectoryAttention,
        isDirectorySet = dirText != null,
    )
    val directoryAttentionProgress = remember { Animatable(0f) }
    LaunchedEffect(directoryAttentionActive) {
        if (!directoryAttentionActive) {
            directoryAttentionProgress.snapTo(0f)
            return@LaunchedEffect
        }
        directoryAttentionProgress.snapTo(0.25f)
        repeat(2) {
            directoryAttentionProgress.animateTo(
                1f,
                tween(180, easing = FastOutSlowInEasing),
            )
            directoryAttentionProgress.animateTo(
                0.32f,
                tween(280, easing = FastOutSlowInEasing),
            )
        }
        directoryAttentionProgress.animateTo(
            0.55f,
            tween(220, easing = FastOutSlowInEasing),
        )
    }

    // 右上角"解锁高级版"徽标打开的介绍对话框（免费/高级版对比 + 解锁按钮复制 QQ 号）。
    var showPro by remember { mutableStateOf(false) }
    var showRenewInfo by remember { mutableStateOf(false) }
    // 页脚"我要换机"打开的对话框（取激活码 + 换机后果告知）。
    var showSwitchDevice by remember { mutableStateOf(false) }
    var settingsPage by remember { mutableStateOf(SettingsPage.MAIN) }
    var showPhotoEffectsInfo by remember { mutableStateOf(false) }
    var photoEffectsInfoViewed by remember { mutableStateOf(false) }
    var photoEffectsInfoAnchorBounds by remember { mutableStateOf<Rect?>(null) }
    var expandedEffectsPreview by remember {
        mutableStateOf<ExpandedEffectsPreview?>(null)
    }
    var watermarkImageImporting by remember { mutableStateOf(false) }
    var frameDraftDecorationEnabled by remember { mutableStateOf(state.photoFrameEnabled) }
    var frameDraftBorderEnabled by remember { mutableStateOf(state.photoFrameBorderEnabled) }
    var frameDraftPreset by remember { mutableStateOf(state.photoFramePreset) }
    var watermarkDraft by remember { mutableStateOf(state.photoFrameWatermark) }
    var filterDraftId by remember { mutableStateOf(state.selectedPhotoFilterId) }
    var filterDraftEnabled by remember { mutableStateOf(state.photoFilterEnabled) }
    var filterDraftIntensity by remember {
        mutableIntStateOf(state.photoFilterIntensityPercent)
    }
    // 真实相机图始终直接复用，不能在主设置页主动清空，否则进入效果页的第一帧会无谓闪空。
    // 兜底图延迟生成：给内存缩略图和按需 FHD 足够时间，绝大多数已连接场景不会看见假图。
    var generatedEffectPreviewFallback by remember { mutableStateOf<Bitmap?>(null) }
    var effectPreviewFallbackVisible by remember { mutableStateOf(false) }
    LaunchedEffect(settingsPage, effectPreviewSource) {
        effectPreviewFallbackVisible = false
        if (settingsPage != SettingsPage.EFFECTS || effectPreviewSource != null) return@LaunchedEffect
        delay(PHOTO_EFFECTS_FALLBACK_GRACE_MS)
        if (generatedEffectPreviewFallback == null) {
            generatedEffectPreviewFallback = withContext(Dispatchers.Default) {
                createPhotoFramePreviewSource()
            }
        }
        effectPreviewFallbackVisible = true
    }
    val effectPreviewBase = effectPreviewSource
        ?: generatedEffectPreviewFallback.takeIf { effectPreviewFallbackVisible }
    // 缩略图升级为 FHD 或兜底切换为真实图时保留用户刚做的旋转，不让源升级重置界面。
    var effectPreviewRotationQuarterTurns by remember { mutableIntStateOf(0) }
    // 保留当前可见帧，等新照片或旋转结果在后台准备好后再一次性交给 AnimatedContent。
    // 不使用 keyed produceState 的 initialValue，避免每次旋转都先短暂跳回 0°。
    var rotatedEffectPreviewSource by remember {
        mutableStateOf(effectPreviewBase?.let { RotatedPreviewSource(it, 0) })
    }
    LaunchedEffect(effectPreviewBase, effectPreviewRotationQuarterTurns) {
        val source = effectPreviewBase ?: run {
            rotatedEffectPreviewSource = null
            return@LaunchedEffect
        }
        val requestedQuarterTurns = effectPreviewRotationQuarterTurns
        if (Math.floorMod(requestedQuarterTurns, 4) == 0) {
            rotatedEffectPreviewSource = RotatedPreviewSource(source, requestedQuarterTurns)
            return@LaunchedEffect
        }
        val rotatedBitmap = withContext(Dispatchers.Default) {
            rotatePreviewBitmap(source, requestedQuarterTurns)
        }
        rotatedEffectPreviewSource = RotatedPreviewSource(rotatedBitmap, requestedQuarterTurns)
    }
    val rotateEffectPreview = {
        effectPreviewRotationQuarterTurns = (effectPreviewRotationQuarterTurns + 1) % 4
    }
    val mainSettingsScroll = rememberScrollState()
    val photoEffectsEditorScroll = rememberScrollState()
    LaunchedEffect(settingsPage) {
        showPhotoEffectsInfo = false
        if (settingsPage == SettingsPage.EFFECTS) {
            photoEffectsInfoViewed = false
            photoEffectsEditorScroll.scrollTo(0)
        }
    }
    fun commitPhotoFrameDraft() {
        focusManager.clearFocus()
        keyboardController?.hide()
        if (frameDraftDecorationEnabled) {
            viewModel.setPhotoFrameConfiguration(
                borderEnabled = frameDraftBorderEnabled,
                preset = frameDraftPreset,
                watermark = watermarkDraft.takeIf { isPro },
            )
        } else {
            viewModel.setPhotoFrameEnabled(false)
        }
    }
    fun commitPhotoFilterDraft() {
        viewModel.setPhotoFilterConfiguration(
            selectedId = filterDraftId,
            intensityPercent = filterDraftIntensity,
            enabled = filterDraftEnabled && filterDraftId != null,
        )
    }
    fun commitPhotoEffectsDraft() {
        commitPhotoFilterDraft()
        commitPhotoFrameDraft()
    }

    // 页脚底部玻璃提示（反馈复制确认 / 隐藏入口的恢复免费版确认共用）；
    // 文案与可见性分开存，消失动画期间仍有文字可渲染；nonce 保证连续触发重启计时。
    val clipboard = LocalClipboardManager.current
    var footerHintText by remember { mutableStateOf("") }
    var footerHintVisible by remember { mutableStateOf(false) }
    var footerHintNonce by remember { mutableIntStateOf(0) }
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
    val watermarkImageImportFailed = stringResource(R.string.photo_frame_image_import_failed)
    val watermarkFavoriteImageMissing =
        stringResource(R.string.photo_effect_favorite_image_missing)
    val watermarkProOnlyHint = stringResource(R.string.photo_frame_watermark_pro_only)
    val watermarkImagePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        watermarkImageImporting = true
        viewModel.importPhotoFrameWatermarkImage(uri) { result ->
            watermarkImageImporting = false
            result.fold(
                onSuccess = { imageHash ->
                    val updatedWatermark = watermarkDraft.copy(
                        content = PhotoFrameWatermarkContent.IMAGE,
                        imageHash = imageHash,
                    )
                    watermarkDraft = updatedWatermark
                    // 图片选择完成即保存配置；即使用户随后直接杀掉应用，私有副本仍会被选中。
                    viewModel.setPhotoFrameConfiguration(
                        frameDraftBorderEnabled,
                        frameDraftPreset,
                        updatedWatermark,
                    )
                    if (frameDraftBorderEnabled) {
                        viewModel.updateFavoriteFrameEffect(
                            frameDraftPreset,
                            updatedWatermark,
                        )
                    }
                },
                onFailure = { showFooterHint(watermarkImageImportFailed) },
            )
        }
    }

    // 面板顶边贴按钮下缘 + 8dp；按钮尚未测量时按顶栏下方近似定位。
    val density = LocalDensity.current
    val panelTop = if (openingAnchorBounds != null) {
        with(density) { openingAnchorBounds.bottom.toDp() } + 8.dp
    } else 76.dp

    AnchorPopup(
        anchorBounds = openingAnchorBounds,
        onDismiss = {
            if (settingsPage == SettingsPage.EFFECTS) commitPhotoEffectsDraft()
            // AnchorPopup 只会在收起动画 animateTo(0f) 完成后调用这里，因此语言切换不会
            // 再硬切掉弹窗；关闭按钮、返回键和点遮罩三条路径都共用这一时序。
            onDismiss()
            if (recreateAfterDismiss) activity?.recreate()
        },
        panelModifier = Modifier
            .padding(start = 12.dp, end = 12.dp, top = panelTop)
            .navigationBarsPadding()   // 小屏时面板底部不顶进导航栏
            .fillMaxWidth(),
        animateScale = false,
        overlayContent = {
            if (showPhotoEffectsInfo) {
                PhotoEffectsInfoBubble(
                    anchorBounds = photoEffectsInfoAnchorBounds,
                    onDismiss = { showPhotoEffectsInfo = false },
                    description = stringResource(R.string.photo_effects_info_description),
                    gestureHint = stringResource(R.string.photo_effects_gesture_hint),
                )
            }
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
        BackHandler(
            enabled = settingsPage != SettingsPage.MAIN && expandedEffectsPreview == null
        ) {
            if (settingsPage == SettingsPage.EFFECTS) commitPhotoEffectsDraft()
            settingsPage = SettingsPage.MAIN
        }
        AnimatedContent(
            targetState = settingsPage,
            transitionSpec = {
                val enteringEditor = targetState != SettingsPage.MAIN
                val enter = if (enteringEditor) {
                    slideInHorizontally(Motion.pageSlide) { it / 3 }
                } else {
                    slideInHorizontally(Motion.pageSlide) { -it / 3 }
                }
                val exit = if (enteringEditor) {
                    slideOutHorizontally(Motion.pageSlide) { -it / 3 }
                } else {
                    slideOutHorizontally(Motion.pageSlide) { it / 3 }
                }
                (enter + fadeIn(Motion.overlayExpand))
                    .togetherWith(exit + fadeOut(Motion.overlayCollapse))
                    .using(
                        SizeTransform(
                            clip = false,
                            sizeAnimationSpec = { _, _ -> tween(340, easing = FastOutSlowInEasing) },
                        )
                    )
            },
            contentAlignment = Alignment.TopCenter,
            label = "settingsDetailPage",
            modifier = Modifier.fillMaxWidth(),
        ) { page ->
            Column(
                modifier = Modifier
                    .clearFocusOnBackgroundTap(page != SettingsPage.MAIN) {
                        focusManager.clearFocus()
                    }
                    .verticalScroll(
                        when (page) {
                            SettingsPage.MAIN -> mainSettingsScroll
                            SettingsPage.EFFECTS -> photoEffectsEditorScroll
                        }
                    )
                    // 照片效果页整体压一层轻遮罩，让成片边缘与玻璃弹窗背景分离；
                    // 遮罩位于所有内容下方，不给预览图增加舞台、外框或内边距。
                    .background(
                        when {
                            page != SettingsPage.EFFECTS -> Color.Transparent
                            colors.background.luminance() < 0.5f ->
                                Color.White.copy(alpha = 0.07f)
                            else -> Color.Black.copy(alpha = 0.13f)
                        }
                    )
                    .padding(16.dp)
            ) {
            // ---------- 标题栏：二级页复用全局 GlassButton 返回；主设置保留原关闭入口 ----------
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (page != SettingsPage.MAIN) {
                    GlassButton(
                        onClick = {
                            focusManager.clearFocus()
                            if (page == SettingsPage.EFFECTS) commitPhotoEffectsDraft()
                            settingsPage = SettingsPage.MAIN
                        },
                        modifier = Modifier.height(36.dp),
                    ) {
                        Icon(
                            Icons.Default.ArrowBack,
                            contentDescription = stringResource(R.string.cd_back),
                            tint = colors.onBackground,
                            modifier = Modifier.size(20.dp),
                        )
                    }
                    Spacer(Modifier.width(10.dp))
                }
                Text(
                    stringResource(
                        when (page) {
                            SettingsPage.MAIN -> R.string.settings
                            SettingsPage.EFFECTS -> R.string.photo_effects
                        }
                    ),
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    color = colors.onBackground
                )
                Spacer(Modifier.weight(1f))
                if (page == SettingsPage.MAIN) {
                    // 未解锁：金徽标"解锁高级版"，点击开介绍弹窗。
                    // 已解锁：金徽标改显"高级版"，点击不弹窗，放烟花彩蛋。
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
                } else {
                    TipLightbulbButton(
                        onClick = {
                            photoEffectsInfoViewed = true
                            showPhotoEffectsInfo = true
                        },
                        contentDescription = stringResource(R.string.photo_effects_info_title),
                        attention = !photoEffectsInfoViewed,
                        modifier = Modifier
                            .size(28.dp)
                            .onGloballyPositioned {
                                photoEffectsInfoAnchorBounds = it.boundsInRoot()
                            },
                    )
                }
            }

            if (page == SettingsPage.EFFECTS) {
                Spacer(Modifier.height(14.dp))
                val previewFilter = state.photoFilters
                    .firstOrNull { it.id == filterDraftId }
                    ?.takeIf { filterDraftEnabled }
                    ?.let { PhotoFilterSelection(it, filterDraftIntensity) }
                val previewFilterPrefetch = remember(
                    state.photoFilters,
                    state.favoritePhotoFilters,
                    state.transferPhotoFilterIntensities,
                    filterDraftId,
                    filterDraftEnabled,
                ) {
                    nextPhotoFilterSelections(
                        filters = state.photoFilters,
                        favoriteCatalogKeys = state.favoritePhotoFilters.map { it.catalogKey },
                        rememberedIntensities = state.transferPhotoFilterIntensities,
                        selectedId = filterDraftId,
                        enabled = filterDraftEnabled,
                    )
                }
                val editorWatermark = when {
                    !frameDraftDecorationEnabled -> PhotoFrameWatermark(enabled = false)
                    isPro -> watermarkDraft.withEditorPlacementConstraints(
                        borderEnabled = frameDraftDecorationEnabled && frameDraftBorderEnabled,
                    )
                    // 免费版真实导出固定使用默认水印；预览必须走同一规则。
                    else -> freeEditionPhotoFrameWatermark()
                }
                // 文本框每次按键只更新编辑草稿；FHD 预览在短暂停顿后取最新文本，避免为必然
                // 被下一次按键淘汰的中间字符串反复合成。displayText 归一化也跳过空白等价配置。
                val requestedRenderWatermark = if (
                    editorWatermark.content == PhotoFrameWatermarkContent.TEXT
                ) {
                    editorWatermark.copy(text = editorWatermark.displayText)
                } else {
                    editorWatermark
                }
                var renderWatermark by remember {
                    mutableStateOf(requestedRenderWatermark)
                }
                LaunchedEffect(requestedRenderWatermark) {
                    val previous = renderWatermark
                    val changesTextOnly = previous.text != requestedRenderWatermark.text &&
                        previous.copy(text = requestedRenderWatermark.text) == requestedRenderWatermark
                    if (changesTextOnly) delay(PHOTO_EFFECTS_TEXT_PREVIEW_DELAY_MS)
                    renderWatermark = requestedRenderWatermark
                }
                val rotatedPreview = rotatedEffectPreviewSource
                AnimatedContent(
                    // 只为“等待图片 → 有图片”做进场动画。旋转、缩略图升级 FHD、
                    // 兜底切真实图都必须复用同一个渲染组件，让旧成片保持到新成片就绪。
                    targetState = rotatedPreview != null,
                    transitionSpec = {
                        (fadeIn(tween(220, easing = FastOutSlowInEasing)) togetherWith
                            fadeOut(tween(140, easing = LinearEasing))).using(
                            SizeTransform(
                                clip = false,
                                sizeAnimationSpec = { _, _ ->
                                    tween(240, easing = FastOutSlowInEasing)
                                },
                            )
                        )
                    },
                    contentAlignment = Alignment.TopCenter,
                    label = "photoEffectsPreviewSource",
                    modifier = Modifier.fillMaxWidth(),
                ) { hasPreview ->
                    if (hasPreview) {
                        val previewSource = rotatedEffectPreviewSource
                        if (previewSource != null) {
                            PhotoEffectsRenderedPreview(
                                source = previewSource.bitmap,
                                metadata = effectPreviewMetadata,
                                sourceRotationQuarterTurns = previewSource.quarterTurns,
                                requestedRotationQuarterTurns = effectPreviewRotationQuarterTurns,
                                // previewSource 已经完成物理旋转，直接看当前宽高；不能再按
                                // quarterTurns 交换一次，否则 90°/270° 会把横竖方向算反。
                                requestedPortrait = previewSource.bitmap.height >
                                    previewSource.bitmap.width,
                                onRotate = rotateEffectPreview,
                                borderEnabled =
                                    frameDraftDecorationEnabled && frameDraftBorderEnabled,
                                preset = frameDraftPreset,
                                watermark = renderWatermark,
                                filter = previewFilter,
                                prefetchFilters = previewFilterPrefetch,
                                onOpen = { bitmap, anchorRect ->
                                    focusManager.clearFocus()
                                    keyboardController?.hide()
                                    expandedEffectsPreview =
                                        ExpandedEffectsPreview(bitmap, anchorRect)
                                },
                            )
                        } else {
                            PhotoEffectsPreviewLoadingPlaceholder()
                        }
                    } else {
                        PhotoEffectsPreviewLoadingPlaceholder()
                    }
                }
                Spacer(Modifier.height(10.dp))
                PhotoFilterEditor(
                    filters = state.photoFilters,
                    favoriteFilters = state.favoritePhotoFilters,
                    rememberedIntensities = state.transferPhotoFilterIntensities,
                    selectedId = filterDraftId,
                    enabled = filterDraftEnabled,
                    intensityPercent = filterDraftIntensity,
                    onDisabled = { filterDraftEnabled = false },
                    onSelected = {
                        filterDraftId = it
                        filterDraftEnabled = true
                    },
                    onIntensityChanged = { filterId, intensity ->
                        filterDraftIntensity = intensity
                        viewModel.rememberTransferPhotoFilterIntensity(filterId, intensity)
                    },
                    onFavoriteToggled = viewModel::toggleFavoritePhotoFilter,
                    hapticsEnabled = state.hapticsEnabled,
                )
                Spacer(Modifier.height(10.dp))
                PhotoFrameWatermarkEditor(
                    favoriteEffects = state.favoriteFrameEffects,
                    borderEnabled = frameDraftDecorationEnabled && frameDraftBorderEnabled,
                    preset = frameDraftPreset,
                    // 高级版编辑器必须保留正在输入的原始草稿（包括暂时为空）；若在这里
                    // 经过 effectivePhotoFrameWatermark，空值会在每次重组时立刻变回默认值，
                    // 用户就无法真正清空后重新输入。预览渲染自身仍会使用 displayText。
                    watermark = editorWatermark,
                    watermarkContentSource = watermarkDraft,
                    isPro = isPro,
                    hapticsEnabled = state.hapticsEnabled,
                    onBorderEnabledChanged = { enabled ->
                        frameDraftBorderEnabled = enabled
                        frameDraftDecorationEnabled = enabled || (isPro && watermarkDraft.enabled)
                    },
                    onPresetChanged = { frameDraftPreset = it },
                    onWatermarkChanged = { updated ->
                        if (isPro) {
                            watermarkDraft = mergeWatermarkEditKeepingPreferredPosition(
                                preferred = watermarkDraft,
                                edited = updated,
                            )
                            frameDraftDecorationEnabled = frameDraftBorderEnabled || updated.enabled
                        }
                    },
                    onFavoriteWatermarkApplied = { favoriteWatermark ->
                        if (isPro) {
                            watermarkDraft = favoriteWatermark
                            frameDraftDecorationEnabled =
                                frameDraftBorderEnabled || favoriteWatermark.enabled
                        }
                    },
                    onWatermarkPositionChanged = { position ->
                        if (isPro) watermarkDraft = watermarkDraft.copy(position = position)
                    },
                    onWatermarkTextCommitted = { text ->
                        if (isPro) {
                            val updated = watermarkDraft.copy(text = text)
                            watermarkDraft = updated
                            viewModel.setPhotoFrameConfiguration(
                                frameDraftDecorationEnabled && frameDraftBorderEnabled,
                                frameDraftPreset,
                                updated,
                            )
                        }
                    },
                    imageImporting = watermarkImageImporting,
                    onFavoriteToggled = viewModel::toggleFavoriteFrameEffect,
                    onFavoriteUpdated = viewModel::updateFavoriteFrameEffect,
                    onFavoriteImageMissing = {
                        showFooterHint(watermarkFavoriteImageMissing)
                    },
                    onProRequired = { showFooterHint(watermarkProOnlyHint) },
                    onImageRequested = {
                        if (!watermarkImageImporting && isPro) {
                            watermarkImagePicker.launch(
                                PickVisualMediaRequest(
                                    ActivityResultContracts.PickVisualMedia.ImageOnly
                                )
                            )
                        }
                    },
                )
            } else {
            if (showPro) {
                ProDialog(
                    onDismiss = { showPro = false },
                    onCelebrate = onPlayFireworks,
                    onHoldCameraWifi = onHoldCameraWifi,
                    renew = false
                )
            }
            if (showRenewInfo) {
                RenewDialog(
                    onDismiss = { showRenewInfo = false },
                    onCelebrate = onPlayFireworks,
                    onHoldCameraWifi = onHoldCameraWifi,
                )
            }

            // 过期用户在此也进入统一的 RenewDialog，避免绕过套餐与价格确认。

            Spacer(Modifier.height(14.dp))

            // ---------- 传输目录：标题、单行路径与更改按钮并排；未设置时保留橙色强调 ----------
            SettingsCard(
                modifier = Modifier.graphicsLayer {
                    val scale = 1f + directoryAttentionProgress.value * 0.008f
                    scaleX = scale
                    scaleY = scale
                },
                borderColor = if (dirText == null) {
                    colors.accentOrange.copy(alpha = 0.8f)
                } else {
                    colors.glassPanelBorder
                },
                attentionColor = colors.accentOrange.takeIf { directoryAttentionActive },
                attentionProgress = directoryAttentionProgress.value,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Default.LocationOn,
                        contentDescription = null,
                        tint = if (dirText != null) colors.statusConnected else colors.accentOrange,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(Modifier.width(10.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        SectionLabel(stringResource(R.string.transfer_directory))
                        Text(
                            text = dirText ?: stringResource(
                                if (directoryAttentionActive) {
                                    R.string.dir_please_set
                                } else {
                                    R.string.dir_not_set
                                }
                            ),
                            style = if (directoryAttentionActive) {
                                MaterialTheme.typography.labelLarge
                            } else {
                                MaterialTheme.typography.bodySmall
                            },
                            fontWeight = if (directoryAttentionActive) {
                                FontWeight.Bold
                            } else {
                                FontWeight.Normal
                            },
                            color = if (dirText != null) colors.onSurfaceVariant else colors.accentOrange,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    Spacer(Modifier.width(10.dp))
                    GlassButton(
                        onClick = { directoryPicker.launch(null) },
                        shape = RoundedCornerShape(12.dp),
                        contentPadding = PaddingValues(horizontal = 12.dp),
                        modifier = Modifier.height(30.dp)
                    ) {
                        Text(
                            stringResource(if (dirText != null) R.string.change_directory else R.string.choose_directory),
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.SemiBold,
                            color = colors.onBackground
                        )
                    }
                }
            }

            Spacer(Modifier.height(8.dp))

            // ---------- 照片列表：布局和操作方式 ----------
            val photoInteractionChoices = listOf(
                false to stringResource(R.string.tap_transfer_hold_preview),
                true to stringResource(R.string.tap_preview_hold_transfer),
            )
            SettingsCard {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.heightIn(min = 44.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.weight(1f),
                    ) {
                        SectionLabel(
                            stringResource(R.string.columns),
                            modifier = Modifier.weight(1f)
                        )
                        Spacer(Modifier.width(6.dp))
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            modifier = Modifier.width(88.dp),
                        ) {
                            (2..4).forEach { col ->
                                SelectionChip(
                                    label = "$col",
                                    selected = state.thumbnailColumns == col,
                                    onClick = { viewModel.setThumbnailColumns(col) },
                                    textStyle = MaterialTheme.typography.labelLarge,
                                    compact = true,
                                    modifier = Modifier.weight(1f)
                                )
                            }
                        }
                    }
                    CompactVerticalDivider()
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .weight(1f)
                            .padding(start = 12.dp),
                    ) {
                        SectionLabel(
                            stringResource(R.string.collapse_burst_photos),
                            modifier = Modifier.weight(1f)
                        )
                        SettingsSwitch(
                            checked = state.collapseBurstPhotos,
                            onCheckedChange = viewModel::setCollapseBurstPhotos,
                            hapticsEnabled = state.hapticsEnabled,
                        )
                    }
                }

                CardDivider()

                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.heightIn(min = 44.dp),
                ) {
                    SectionLabel(
                        stringResource(R.string.photo_interaction),
                        modifier = Modifier.weight(0.72f),
                    )
                    Spacer(Modifier.width(8.dp))
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        modifier = Modifier.weight(2f),
                    ) {
                        photoInteractionChoices.forEach { (tapToPreview, label) ->
                            SelectionChip(
                                label = label,
                                selected = state.tapToPreview == tapToPreview,
                                onClick = {
                                    if (state.tapToPreview != tapToPreview) {
                                        haptics.tick()
                                        viewModel.setTapToPreview(tapToPreview)
                                    }
                                },
                                textStyle = MaterialTheme.typography.labelMedium,
                                compact = true,
                                height = 42.dp,
                                maxLines = 2,
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(8.dp))

            if (showPhotoEffectsEntry) {
            // ---------- 照片效果：主页面只展示当前状态，所有开关与参数统一在二级页设置 ----------
            val selectedPhotoFilter = state.photoFilters.firstOrNull {
                it.id == state.selectedPhotoFilterId
            }
            val frameChoices = listOf(
                PhotoFramePreset.MIST to stringResource(R.string.photo_frame_mist),
                PhotoFramePreset.CINEMA to stringResource(R.string.photo_frame_cinema),
                PhotoFramePreset.MINIMAL to stringResource(R.string.photo_frame_minimal),
                PhotoFramePreset.FROSTED to stringResource(R.string.photo_frame_frosted),
                PhotoFramePreset.PLAQUE to stringResource(R.string.photo_frame_plaque),
                PhotoFramePreset.IMMERSIVE to stringResource(R.string.photo_frame_immersive),
                PhotoFramePreset.BRAND_INSET to
                    stringResource(R.string.photo_frame_brand_inset),
                PhotoFramePreset.BRAND_GALLERY to
                    stringResource(R.string.photo_frame_brand_gallery),
            )
            val selectedFrameChoice = frameChoices.first { it.first == state.photoFramePreset }
            val visibleWatermark = if (state.photoFrameEnabled) {
                effectivePhotoFrameWatermark(
                    isPro,
                    state.photoFrameWatermark,
                    borderEnabled = state.photoFrameBorderEnabled,
                )
            } else {
                PhotoFrameWatermark(enabled = false)
            }
            val watermarkSummary = if (visibleWatermark.enabled) {
                if (visibleWatermark.content == PhotoFrameWatermarkContent.IMAGE) {
                    stringResource(R.string.photo_frame_image_watermark)
                } else {
                    visibleWatermark.displayText
                }
            } else {
                stringResource(R.string.photo_frame_no_watermark)
            }
            val filterSummaryLines = selectedPhotoFilter
                ?.takeIf { state.photoFilterEnabled }
                ?.let {
                    listOf(
                        photoFilterDisplayName(it),
                        stringResource(
                            R.string.photo_filter_intensity_summary,
                            state.photoFilterIntensityPercent,
                        ),
                    )
                }
                ?: listOf(stringResource(R.string.photo_filter_off_option))
            val frameSummary = if (state.photoFrameEnabled && state.photoFrameBorderEnabled) {
                selectedFrameChoice.second
            } else {
                stringResource(R.string.photo_frame_off)
            }
            val decorationSummaryLines = listOf(
                stringResource(R.string.photo_frame_summary_line, frameSummary),
                stringResource(R.string.photo_watermark_summary_line, watermarkSummary),
            )
            val openEffectsEditor = {
                filterDraftId = state.selectedPhotoFilterId
                    ?: state.photoFilters.firstOrNull()?.id
                filterDraftIntensity = state.photoFilterIntensityPercent
                filterDraftEnabled = state.photoFilterEnabled
                frameDraftDecorationEnabled = state.photoFrameEnabled
                // 总开关关闭时 ViewModel 会保留上次的子配置。编辑草稿必须从当前实际
                // 输出状态开始，避免用户只打开水印时把隐藏的旧边框一起恢复。
                frameDraftBorderEnabled = state.photoFrameEnabled && state.photoFrameBorderEnabled
                frameDraftPreset = state.photoFramePreset
                watermarkDraft = state.photoFrameWatermark.copy(
                    enabled = state.photoFrameEnabled && state.photoFrameWatermark.enabled,
                    text = state.photoFrameWatermark.displayText,
                )
                onEffectPreviewRequested()
                settingsPage = SettingsPage.EFFECTS
            }
            SettingsCard(
                borderColor = colors.accentOrange.copy(
                    alpha = if (state.photoFilterEnabled || state.photoFrameEnabled) 0.56f
                    else 0.30f
                ),
                pressAccentColor = colors.accentOrange,
                onClick = openEffectsEditor,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SectionLabel(
                        stringResource(R.string.photo_effects),
                        color = colors.accentOrange,
                        modifier = Modifier.weight(1f),
                    )
                    Icon(
                        Icons.Default.ChevronRight,
                        contentDescription = stringResource(R.string.photo_effects_open_editor),
                        tint = colors.onSurfaceVariant,
                        modifier = Modifier.size(20.dp),
                    )
                }
                CardDivider()
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(IntrinsicSize.Min),
                ) {
                    PhotoEffectSummaryItem(
                        label = stringResource(R.string.photo_filter),
                        valueLines = filterSummaryLines,
                        accentColor = colors.accentOrange,
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxHeight(),
                    )
                    PhotoEffectSummaryItem(
                        label = stringResource(R.string.photo_frame_and_watermark_short),
                        valueLines = decorationSummaryLines,
                        accentColor = colors.accentBlue,
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxHeight(),
                    )
                }
            }

            Spacer(Modifier.height(8.dp))
            }

            // ---------- 明暗、语言、按钮材质：同款拨轮，全部只在松手后提交 ----------
            val themeChoices = ThemeMode.entries.map { mode ->
                mode to stringResource(
                    when (mode) {
                        ThemeMode.SYSTEM -> R.string.theme_system
                        ThemeMode.DARK -> R.string.theme_dark
                        ThemeMode.LIGHT -> R.string.theme_light
                    }
                )
            }
            val selectedTheme = themeChoices.first { it.first == state.themeMode }
            val languages = listOf(
                AppLocale.SYSTEM to stringResource(R.string.language_system),
                "en" to "English",
                "zh-Hans" to "简体中文",
                "zh-Hant" to "繁體中文",
            )
            val selectedLanguage = languages.firstOrNull { it.first == state.appLanguage }
                ?: languages.first()
            val skinChoices = ButtonSkinDisplayOrder.map { skin ->
                skin to stringResource(skin.displayNameResId)
            }
            val selectedSkin = skinChoices.first { it.first == state.skinPreset }
            SettingsCard {
                BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
                    val wheelWidth = (maxWidth - 16.dp) / 3f
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        ReleaseCommitWheel(
                            options = themeChoices,
                            selected = selectedTheme,
                            optionLabel = { it.second },
                            onValueCommitted = { viewModel.setThemeMode(it.first) },
                            onDetent = haptics::tick,
                            label = stringResource(R.string.light_dark_mode),
                            modifier = Modifier.width(wheelWidth),
                        )
                        ReleaseCommitWheel(
                            options = languages,
                            selected = selectedLanguage,
                            optionLabel = { it.second },
                            onValueCommitted = { language ->
                                if (language.first != state.appLanguage) {
                                    viewModel.setAppLanguage(language.first)
                                    recreateAfterDismiss = true
                                    close()
                                }
                            },
                            onDetent = haptics::tick,
                            label = stringResource(R.string.language),
                            modifier = Modifier.width(wheelWidth),
                        )
                        ReleaseCommitWheel(
                            options = skinChoices,
                            selected = selectedSkin,
                            optionLabel = { it.second },
                            onValueCommitted = { viewModel.setSkinPreset(it.first) },
                            onDetent = haptics::tick,
                            label = stringResource(R.string.button_style),
                            modifier = Modifier.width(wheelWidth),
                        )
                    }
                }

                CardDivider()

                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.heightIn(min = 44.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.weight(1f),
                    ) {
                        SectionLabel(
                            stringResource(R.string.haptic_feedback),
                            modifier = Modifier.weight(1f)
                        )
                        SettingsSwitch(
                            checked = state.hapticsEnabled,
                            onCheckedChange = viewModel::setHapticsEnabled,
                            hapticsEnabled = state.hapticsEnabled,
                            isHapticsPreference = true,
                        )
                    }
                    CompactVerticalDivider()
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .weight(1f)
                            .padding(start = 12.dp),
                    ) {
                        SectionLabel(
                            stringResource(R.string.keep_screen_on),
                            modifier = Modifier.weight(1f)
                        )
                        SettingsSwitch(
                            checked = state.keepScreenOn,
                            onCheckedChange = viewModel::setKeepScreenOn,
                            hapticsEnabled = state.hapticsEnabled,
                        )
                    }
                }
            }

            Spacer(Modifier.height(14.dp))

            // ---------- 页脚：左侧版本号，右侧毛玻璃"反馈"按钮（点击复制 QQ 号）----------
            // 版本号兼作隐蔽调试入口：已解锁时 1.5s 内连点 7 次恢复免费版（只清本地
            // 通行证，重新输入激活码即恢复）——发版前自测免费限制用。无水波纹、
            // 无任何视觉暗示，成功才弹底部确认。
            var versionTaps by remember { mutableIntStateOf(0) }
            var lastVersionTapAt by remember { mutableLongStateOf(0L) }
            val revertedHint = stringResource(R.string.revert_free)
            val qqCopiedHint = stringResource(R.string.feedback_qq_copied, QQ_NUMBER)
            // 手动检查会绕过自动检查间隔和“忽略此版本”。有新版直接显示更新弹窗；
            // 无新版或检查失败才在页脚显示短提示。
            var checkingUpdate by remember { mutableStateOf(false) }
            val updateScope = rememberCoroutineScope()
            val latestHint = stringResource(R.string.update_latest)
            val checkFailedHint = stringResource(R.string.update_check_failed)
            Row(verticalAlignment = Alignment.CenterVertically) {
                VersionPlaque(
                    text = stringResource(R.string.version_label, BuildConfig.VERSION_NAME),
                    onClick = {
                        val now = System.currentTimeMillis()
                        versionTaps = if (now - lastVersionTapAt < 1500) versionTaps + 1 else 1
                        lastVersionTapAt = now
                        if (versionTaps >= 7 && isPro) {
                            versionTaps = 0
                            LicenseManager.revertToFree()
                            showFooterHint(revertedHint)
                        }
                    },
                )
                Spacer(Modifier.weight(1f))
                GlassButton(
                    onClick = {
                        if (!checkingUpdate) {
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
    }
    expandedEffectsPreview?.let { preview ->
        // asImageBitmap() 每次调用都会创建包装对象；若直接在参数里调用，设置页动画或
        // 高清源升级引发重组时会改变 ZoomablePreviewViewport 的 stateKey，把用户正在
        // 进行的双指缩放重置为 1x。按底层 Bitmap 身份固定包装对象，缩放状态才稳定。
        val previewImage = remember(preview.bitmap) { preview.bitmap.asImageBitmap() }
        SinglePhotoPreviewOverlay(
            bitmap = previewImage,
            title = stringResource(R.string.photo_effects),
            anchorRect = preview.anchorRect,
            onDismiss = { expandedEffectsPreview = null },
        )
    }
}

private data class ExpandedEffectsPreview(
    val bitmap: Bitmap,
    val anchorRect: Rect,
)

@Composable
internal fun PhotoEffectsInfoBubble(
    anchorBounds: Rect?,
    onDismiss: () -> Unit,
    description: String,
    gestureHint: String,
    extraHint: String? = null,
    parentTopInset: Dp = 0.dp,
) {
    val colors = AppTheme.colors
    val density = LocalDensity.current
    val panelTop = anchorBounds?.let {
        with(density) { it.bottom.toDp() } - parentTopInset + 8.dp
    } ?: 64.dp
    AnchorPopup(
        anchorBounds = anchorBounds,
        onDismiss = onDismiss,
        panelModifier = Modifier
            .padding(start = 18.dp, end = 18.dp, top = panelTop)
            .widthIn(min = 260.dp, max = 420.dp),
        panelAlignment = Alignment.TopEnd,
        shape = RoundedCornerShape(16.dp),
        dim = false,
    ) { _ ->
        Column(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
        ) {
            Text(
                description,
                style = MaterialTheme.typography.bodySmall,
                color = colors.onSurfaceVariant,
            )
            if (!extraHint.isNullOrBlank()) {
                Spacer(Modifier.height(7.dp))
                Text(
                    extraHint,
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.onSurfaceVariant,
                )
            }
            Spacer(Modifier.height(7.dp))
            Text(
                gestureHint,
                style = MaterialTheme.typography.bodySmall,
                color = colors.onSurfaceVariant,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                stringResource(R.string.photo_effects_wheel_hint),
                style = MaterialTheme.typography.bodySmall,
                color = colors.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun PhotoEffectSummaryItem(
    label: String,
    valueLines: List<String>,
    accentColor: Color,
    modifier: Modifier = Modifier,
) {
    val colors = AppTheme.colors
    val shape = RoundedCornerShape(10.dp)
    Column(
        modifier = modifier
            .clip(shape)
            .background(accentColor.copy(alpha = 0.07f))
            .border(1.dp, accentColor.copy(alpha = 0.18f), shape)
            .padding(horizontal = 9.dp, vertical = 7.dp),
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            color = accentColor,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.height(3.dp))
        valueLines.forEachIndexed { index, value ->
            if (index > 0) Spacer(Modifier.height(1.dp))
            Text(
                text = value,
                style = MaterialTheme.typography.bodySmall,
                color = colors.onSurfaceVariant,
                maxLines = 2,
            )
        }
    }
}

@Composable
internal fun PhotoFilterEditor(
    filters: List<PhotoFilterPreset>,
    favoriteFilters: List<FavoritePhotoFilter>,
    rememberedIntensities: Map<String, Int>,
    selectedId: String?,
    enabled: Boolean,
    intensityPercent: Int,
    onDisabled: () -> Unit,
    onSelected: (String) -> Unit,
    onIntensityChanged: (String, Int) -> Unit,
    onFavoriteToggled: (String) -> Unit,
    hapticsEnabled: Boolean,
) {
    val colors = AppTheme.colors
    val filterAccent = colors.accentBlue
    val favoritePalette = rememberPhotoEffectFavoriteButtonPalette()
    val haptics = rememberHaptics(hapticsEnabled)
    val selected = filters.firstOrNull { it.id == selectedId }
    val normalizedIntensity = normalizePhotoFilterIntensity(intensityPercent)
    val intensityChoices = remember { (100 downTo 2 step 2).toList() }
    val favoriteByCatalogKey = favoriteFilters.associateBy { it.catalogKey }
    val orderedFilters = orderWithFavorites(
        items = filters,
        favoriteKeys = favoriteFilters.map { it.catalogKey },
        keyOf = { filter -> BuiltInPhotoFilters.catalogKey(filter.id) ?: filter.id },
    )
    val offLabel = stringResource(R.string.photo_filter_off_option)
    val filterLabelsById = orderedFilters.associate { filter ->
        filter.id to photoFilterDisplayName(filter)
    }
    val filterOptionIds: List<String?> = listOf(null) + orderedFilters.map { it.id }
    val selectedOptionId = selectedId?.takeIf { enabled && it in filterLabelsById }
    fun rememberedIntensity(filterId: String): Int {
        val catalogKey = BuiltInPhotoFilters.catalogKey(filterId)
        return catalogKey?.let(rememberedIntensities::get)
            ?: DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT
    }
    SettingsCard(
        borderColor = filterAccent.copy(alpha = 0.24f),
        tintColor = filterAccent,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ReleaseCommitWheel(
                options = filterOptionIds,
                selected = selectedOptionId,
                optionLabel = { filterId ->
                    if (filterId == null) {
                        offLabel
                    } else {
                        filterLabelsById[filterId].orEmpty()
                    }
                },
                favoriteOption = { filterId ->
                    filterId != null && BuiltInPhotoFilters.catalogKey(filterId)
                        ?.let(favoriteByCatalogKey::containsKey) == true
                },
                favoriteIconColor = favoritePalette.activeIcon,
                onValueCommitted = { filterId ->
                    if (filterId == null) {
                        onDisabled()
                    } else {
                        onSelected(filterId)
                        onIntensityChanged(filterId, rememberedIntensity(filterId))
                    }
                },
                onDetent = haptics::tick,
                label = stringResource(R.string.photo_filter),
                wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                accentColor = filterAccent,
                modifier = Modifier.weight(PHOTO_EFFECTS_PRIMARY_WHEEL_WEIGHT),
            )
            ReleaseCommitWheel(
                options = intensityChoices,
                selected = normalizedIntensity,
                optionLabel = { "$it%" },
                onValueCommitted = { intensity ->
                    selected?.takeIf { enabled }?.let { preset ->
                        onIntensityChanged(preset.id, intensity)
                    }
                },
                onDetent = haptics::tick,
                label = stringResource(R.string.photo_filter_intensity),
                enabled = enabled && selected != null,
                wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                accentColor = filterAccent,
                modifier = Modifier.weight(PHOTO_EFFECTS_SECONDARY_WHEEL_WEIGHT),
            )
            FavoriteToggleButton(
                favorite = selected?.let { preset ->
                    BuiltInPhotoFilters.catalogKey(preset.id)
                        ?.let(favoriteByCatalogKey::containsKey)
                } == true && enabled,
                enabled = enabled && selected != null,
                onClick = {
                    selected?.let { preset ->
                        haptics.tick()
                        onFavoriteToggled(preset.id)
                    }
                },
            )
        }
    }
}

internal fun nextPhotoFilterSelections(
    filters: List<PhotoFilterPreset>,
    favoriteCatalogKeys: List<String>,
    rememberedIntensities: Map<String, Int>,
    selectedId: String?,
    enabled: Boolean,
    count: Int = PHOTO_EFFECTS_FORWARD_PREFETCH_COUNT,
): List<PhotoFilterSelection> {
    if (!enabled || selectedId == null || count <= 0) return emptyList()
    val ordered = orderWithFavorites(
        items = filters,
        favoriteKeys = favoriteCatalogKeys,
        keyOf = { filter -> BuiltInPhotoFilters.catalogKey(filter.id) ?: filter.id },
    )
    val selectedIndex = ordered.indexOfFirst { it.id == selectedId }
    if (selectedIndex < 0 || selectedIndex == ordered.lastIndex) return emptyList()
    return ordered.asSequence()
        .drop(selectedIndex + 1)
        .take(count)
        .map { preset ->
            val catalogKey = BuiltInPhotoFilters.catalogKey(preset.id) ?: preset.id
            PhotoFilterSelection(
                preset = preset,
                intensityPercent = rememberedIntensities[catalogKey]
                    ?: DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT,
            )
        }
        .toList()
}

internal data class PhotoEffectFavoriteButtonPalette(
    val inactiveIcon: Color,
    val activeIcon: Color,
    val activeMaterial: Color,
)

internal fun photoEffectFavoriteButtonPalette(
    skin: SkinPreset,
    dark: Boolean,
    defaultInactiveIcon: Color,
    defaultActive: Color,
): PhotoEffectFavoriteButtonPalette = when (skin) {
    SkinPreset.FROSTED_GLASS -> PhotoEffectFavoriteButtonPalette(
        inactiveIcon = defaultInactiveIcon,
        activeIcon = defaultActive,
        activeMaterial = defaultActive,
    )

    SkinPreset.TITANIUM -> PhotoEffectFavoriteButtonPalette(
        inactiveIcon = if (dark) Color(0xFFE4ECEF) else Color(0xFF344149),
        activeIcon = if (dark) Color(0xFFFFE9C7) else Color(0xFF5A2800),
        activeMaterial = defaultActive,
    )

    SkinPreset.WOOD -> PhotoEffectFavoriteButtonPalette(
        inactiveIcon = if (dark) Color(0xFFF1D6A7) else Color(0xFF472A18),
        activeIcon = if (dark) Color(0xFFFFF0C7) else Color(0xFF4A210D),
        activeMaterial = defaultActive,
    )

    SkinPreset.CAMERA_CONTROLS -> PhotoEffectFavoriteButtonPalette(
        inactiveIcon = Color(0xFFD5D8DA),
        activeIcon = Color(0xFFFFE2A3),
        activeMaterial = defaultActive,
    )
}

@Composable
private fun FavoriteToggleButton(
    favorite: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val palette = rememberPhotoEffectFavoriteButtonPalette()
    val markColor by animateColorAsState(
        targetValue = if (favorite) palette.activeIcon else palette.inactiveIcon,
        animationSpec = tween(180),
        label = "photoEffectFavoriteColor",
    )
    GlassButton(
        onClick = onClick,
        enabled = enabled,
        active = favorite,
        activeColor = palette.activeMaterial,
        activeOutline = true,
        // 钛合金凹刻与相机键帽丝印会重绘内容；显式传入同一动画色，确保实体材质
        // 与毛玻璃、木纹主题拥有一致的收藏过渡，同时保持各自合适的对比度。
        materialContentColor = markColor,
        shape = RoundedCornerShape(13.dp),
        contentPadding = PaddingValues(0.dp),
        modifier = Modifier.size(PHOTO_EFFECTS_CONTROL_HEIGHT),
    ) {
        AnimatedContent(
            targetState = favorite,
            transitionSpec = {
                (scaleIn(tween(190), initialScale = 0.55f) + fadeIn(tween(150))) togetherWith
                    (scaleOut(tween(130), targetScale = 0.72f) + fadeOut(tween(110)))
            },
            label = "photoEffectFavorite",
        ) { selected ->
            Icon(
                imageVector = if (selected) Icons.Rounded.Star else Icons.Rounded.StarBorder,
                contentDescription = stringResource(
                    if (selected) R.string.photo_effect_favorite_remove
                    else R.string.photo_effect_favorite_add,
                ),
                tint = markColor,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

@Composable
private fun rememberPhotoEffectFavoriteButtonPalette(): PhotoEffectFavoriteButtonPalette {
    val colors = AppTheme.colors
    val buttonSkin = LocalButtonTexturePalette.current?.skin ?: SkinPreset.FROSTED_GLASS
    val buttonDark = colors.background.luminance() < 0.5f
    return remember(
        buttonSkin,
        buttonDark,
        colors.onSurfaceVariant,
        colors.accentOrange,
    ) {
        photoEffectFavoriteButtonPalette(
            skin = buttonSkin,
            dark = buttonDark,
            defaultInactiveIcon = colors.onSurfaceVariant,
            defaultActive = colors.accentOrange,
        )
    }
}

/** Draws a bitmap without distortion while its fitted bounds rotate inside a resizing viewport. */
@Composable
private fun FittedRotatingBitmap(
    image: ImageBitmap,
    rotationDegrees: Float,
    modifier: Modifier = Modifier,
    description: String? = null,
) {
    val accessibleModifier = if (description == null) {
        modifier
    } else {
        modifier.semantics { contentDescription = description }
    }
    androidx.compose.foundation.Canvas(accessibleModifier) {
        if (size.width <= 0f || size.height <= 0f || image.width <= 0 || image.height <= 0) {
            return@Canvas
        }
        val radians = Math.toRadians(rotationDegrees.toDouble())
        val cosine = abs(cos(radians)).toFloat()
        val sine = abs(sin(radians)).toFloat()
        val rotatedWidth = image.width * cosine + image.height * sine
        val rotatedHeight = image.width * sine + image.height * cosine
        val scale = minOf(size.width / rotatedWidth, size.height / rotatedHeight)
        val drawWidth = (image.width * scale).roundToInt().coerceAtLeast(1)
        val drawHeight = (image.height * scale).roundToInt().coerceAtLeast(1)
        val destinationOffset = IntOffset(
            x = ((size.width - drawWidth) / 2f).roundToInt(),
            y = ((size.height - drawHeight) / 2f).roundToInt(),
        )
        rotate(degrees = rotationDegrees, pivot = center) {
            drawImage(
                image = image,
                dstOffset = destinationOffset,
                dstSize = IntSize(drawWidth, drawHeight),
            )
        }
    }
}

@Composable
private fun photoFilterDisplayName(filter: PhotoFilterPreset): String =
    BuiltInPhotoFilters.nameResId(filter.id)?.let { stringResource(it) } ?: filter.name

@Composable
internal fun PhotoFrameWatermarkEditor(
    favoriteEffects: List<FavoriteFrameWatermarkEffect>,
    borderEnabled: Boolean,
    preset: PhotoFramePreset,
    watermark: PhotoFrameWatermark,
    watermarkContentSource: PhotoFrameWatermark = watermark,
    isPro: Boolean,
    hapticsEnabled: Boolean,
    onBorderEnabledChanged: (Boolean) -> Unit,
    onPresetChanged: (PhotoFramePreset) -> Unit,
    onWatermarkChanged: (PhotoFrameWatermark) -> Unit,
    onFavoriteWatermarkApplied: (PhotoFrameWatermark) -> Unit,
    onWatermarkPositionChanged: (PhotoFrameWatermarkPosition) -> Unit,
    onWatermarkTextCommitted: (String) -> Unit,
    imageImporting: Boolean,
    onFavoriteToggled: (PhotoFramePreset, PhotoFrameWatermark) -> Unit,
    onFavoriteUpdated: (PhotoFramePreset, PhotoFrameWatermark) -> Unit,
    onFavoriteImageMissing: () -> Unit,
    onProRequired: () -> Unit,
    onImageRequested: () -> Unit,
) {
    val colors = AppTheme.colors
    val frameAccent = colors.accentOrange
    val watermarkAccent = colors.accentPurple
    val favoritePalette = rememberPhotoEffectFavoriteButtonPalette()
    val haptics = rememberHaptics(hapticsEnabled)
    val focusManager = LocalFocusManager.current
    val proLockInteractionSource = remember { MutableInteractionSource() }
    val frameChoicesInCatalogOrder = listOf(
        PhotoFramePreset.MIST to stringResource(R.string.photo_frame_mist),
        PhotoFramePreset.CINEMA to stringResource(R.string.photo_frame_cinema),
        PhotoFramePreset.MINIMAL to stringResource(R.string.photo_frame_minimal),
        PhotoFramePreset.FROSTED to stringResource(R.string.photo_frame_frosted),
        PhotoFramePreset.PLAQUE to stringResource(R.string.photo_frame_plaque),
        PhotoFramePreset.IMMERSIVE to stringResource(R.string.photo_frame_immersive),
        PhotoFramePreset.BRAND_INSET to stringResource(R.string.photo_frame_brand_inset),
        PhotoFramePreset.BRAND_GALLERY to stringResource(R.string.photo_frame_brand_gallery),
    )
    val frameLabels = frameChoicesInCatalogOrder.toMap()
    val favoriteByPreset = favoriteEffects.associateBy { it.framePreset }
    val orderedFramePresets = orderWithFavorites(
        items = frameChoicesInCatalogOrder.map { it.first },
        favoriteKeys = favoriteEffects.map { it.framePreset },
        keyOf = { it },
    )
    val frameOffLabel = stringResource(R.string.photo_frame_off)
    val frameOptionPresets: List<PhotoFramePreset?> =
        listOf(null) + orderedFramePresets
    val fontChoices = listOf(
        PhotoFrameWatermarkFont.SIGNATURE to stringResource(R.string.photo_frame_font_signature),
        PhotoFrameWatermarkFont.ELEGANT to stringResource(R.string.photo_frame_font_elegant),
        PhotoFrameWatermarkFont.CALLIGRAPHY to stringResource(R.string.photo_frame_font_calligraphy),
        PhotoFrameWatermarkFont.SIMPLE to stringResource(R.string.photo_frame_font_simple),
        PhotoFrameWatermarkFont.BOLD to stringResource(R.string.photo_frame_font_bold),
    )
    val sizeChoices = remember {
        (MAX_PHOTO_FRAME_WATERMARK_SIZE_PERCENT downTo
            MIN_PHOTO_FRAME_WATERMARK_SIZE_PERCENT)
            .map { percent -> percent to "$percent%" }
    }
    val positionChoices = listOf(
        PhotoFrameWatermarkPosition.AUTO to stringResource(R.string.photo_frame_position_auto),
        PhotoFrameWatermarkPosition.LEFT to stringResource(R.string.photo_frame_position_left),
        PhotoFrameWatermarkPosition.CENTER to stringResource(R.string.photo_frame_position_center),
        PhotoFrameWatermarkPosition.RIGHT to stringResource(R.string.photo_frame_position_right),
        PhotoFrameWatermarkPosition.PHOTO_TOP_LEFT to stringResource(R.string.photo_frame_position_photo_top_left),
        PhotoFrameWatermarkPosition.PHOTO_TOP_CENTER to stringResource(R.string.photo_frame_position_photo_top_center),
        PhotoFrameWatermarkPosition.PHOTO_TOP_RIGHT to stringResource(R.string.photo_frame_position_photo_top_right),
        PhotoFrameWatermarkPosition.PHOTO_CENTER to stringResource(R.string.photo_frame_position_photo_center),
        PhotoFrameWatermarkPosition.PHOTO_BOTTOM_LEFT to stringResource(R.string.photo_frame_position_photo_bottom_left),
        PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER to stringResource(R.string.photo_frame_position_photo_bottom_center),
        PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT to stringResource(R.string.photo_frame_position_photo_bottom_right),
    )
    val photoPositionChoices = positionChoices.filter { it.first.isPhotoPlacement() }
    val textPositionChoices = if (borderEnabled) positionChoices else photoPositionChoices
    val contentChoices = listOf(
        PhotoFrameWatermarkContent.TEXT to stringResource(R.string.photo_frame_content_text),
        PhotoFrameWatermarkContent.IMAGE to stringResource(R.string.photo_frame_content_image),
    )
    val colorChoices = listOf(
        PhotoFrameWatermarkColor.ADAPTIVE to stringResource(R.string.photo_frame_color_adaptive),
        PhotoFrameWatermarkColor.WHITE to stringResource(R.string.photo_frame_color_white),
        PhotoFrameWatermarkColor.BLACK to stringResource(R.string.photo_frame_color_black),
        PhotoFrameWatermarkColor.GOLD to stringResource(R.string.photo_frame_color_gold),
        PhotoFrameWatermarkColor.MIST_BLUE to stringResource(R.string.photo_frame_color_mist_blue),
        PhotoFrameWatermarkColor.ROSE_GOLD to stringResource(R.string.photo_frame_color_rose_gold),
    )
    val opacityChoices = remember {
        (MAX_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT downTo
            MIN_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT)
            .map { percent -> percent to "$percent%" }
    }
    val effectChoices = listOf(
        PhotoFrameWatermarkEffect.AUTO to stringResource(R.string.photo_frame_effect_auto),
        PhotoFrameWatermarkEffect.NONE to stringResource(R.string.photo_frame_effect_none),
        PhotoFrameWatermarkEffect.SHADOW to stringResource(R.string.photo_frame_effect_shadow),
        PhotoFrameWatermarkEffect.OUTLINE to stringResource(R.string.photo_frame_effect_outline),
    )
    val watermarkEnabledChoices = listOf(
        false to stringResource(R.string.photo_frame_off),
        true to stringResource(R.string.photo_frame_on),
    )

    fun commitWatermarkChange(updated: PhotoFrameWatermark) {
        onWatermarkChanged(updated)
        if (borderEnabled && preset in favoriteByPreset) {
            onFavoriteUpdated(preset, updated)
        }
    }

    fun commitWatermarkPosition(position: PhotoFrameWatermarkPosition) {
        onWatermarkPositionChanged(position)
        if (borderEnabled && preset in favoriteByPreset) {
            onFavoriteUpdated(preset, watermark.copy(position = position))
        }
    }

    SettingsCard(
        borderColor = frameAccent.copy(alpha = 0.24f),
        tintColor = frameAccent,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            ReleaseCommitWheel(
                options = frameOptionPresets,
                selected = preset.takeIf { borderEnabled },
                optionLabel = { framePreset ->
                    if (framePreset == null) {
                        frameOffLabel
                    } else {
                        checkNotNull(frameLabels[framePreset])
                    }
                },
                favoriteOption = { framePreset ->
                    framePreset != null && framePreset in favoriteByPreset
                },
                favoriteIconColor = favoritePalette.activeIcon,
                onValueCommitted = { selectedPreset ->
                    focusManager.clearFocus()
                    if (selectedPreset == null) {
                        onBorderEnabledChanged(false)
                    } else {
                        val favorite = favoriteByPreset[selectedPreset]
                        val favoriteWatermark = favorite?.applyTo(
                            current = watermark,
                            contentSource = watermarkContentSource,
                        )
                        if (favorite != null && favoriteWatermark == null) {
                            onFavoriteImageMissing()
                            return@ReleaseCommitWheel
                        }
                        onPresetChanged(selectedPreset)
                        favoriteWatermark?.let(onFavoriteWatermarkApplied)
                        onBorderEnabledChanged(true)
                    }
                },
                onDetent = haptics::tick,
                label = stringResource(R.string.photo_frame_style_short),
                wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                accentColor = frameAccent,
                modifier = Modifier.weight(PHOTO_EFFECTS_PRIMARY_WHEEL_WEIGHT),
            )
            Box(modifier = Modifier.weight(PHOTO_EFFECTS_SECONDARY_WHEEL_WEIGHT)) {
                ReleaseCommitWheel(
                    options = watermarkEnabledChoices,
                    selected = watermarkEnabledChoices.first {
                        it.first == watermark.enabled
                    },
                    optionLabel = { it.second },
                    onValueCommitted = {
                        focusManager.clearFocus()
                        commitWatermarkChange(watermark.copy(enabled = it.first))
                    },
                    onDetent = haptics::tick,
                    label = stringResource(R.string.photo_frame_watermark_short),
                    enabled = isPro,
                    wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                    accentColor = watermarkAccent,
                    modifier = Modifier.fillMaxWidth(),
                )
                if (!isPro) {
                    Box(
                        modifier = Modifier
                            .matchParentSize()
                            .clip(RoundedCornerShape(13.dp))
                            .clickable(
                                interactionSource = proLockInteractionSource,
                                indication = null,
                                onClick = onProRequired,
                            ),
                    )
                }
            }
            FavoriteToggleButton(
                favorite = borderEnabled && preset in favoriteByPreset,
                enabled = borderEnabled,
                onClick = {
                    haptics.tick()
                    onFavoriteToggled(preset, watermark)
                },
            )
        }

        AnimatedVisibility(
            visible = watermark.enabled,
            enter = fadeIn() + expandVertically(),
            exit = fadeOut() + shrinkVertically(),
        ) {
            Column(
                modifier = Modifier.clickable(
                    enabled = !isPro,
                    interactionSource = proLockInteractionSource,
                    indication = null,
                    onClick = onProRequired,
                )
                    .padding(top = 8.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(watermarkAccent.copy(alpha = 0.055f))
                    .border(
                        1.dp,
                        watermarkAccent.copy(alpha = 0.18f),
                        RoundedCornerShape(12.dp),
                    )
                    .padding(8.dp),
            ) {
                BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
                    val contentWheelWidth = (maxWidth - 8.dp) / 3f
                    val editorWidth = maxWidth - contentWheelWidth - 8.dp
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.Bottom,
                    ) {
                        ReleaseCommitWheel(
                            options = contentChoices,
                            selected = contentChoices.first { it.first == watermark.content },
                            optionLabel = { it.second },
                            onValueCommitted = { choice ->
                                focusManager.clearFocus()
                                when (choice.first) {
                                    PhotoFrameWatermarkContent.TEXT -> commitWatermarkChange(
                                        watermark.copy(content = PhotoFrameWatermarkContent.TEXT)
                                    )
                                    PhotoFrameWatermarkContent.IMAGE -> {
                                        if (watermark.imageHash == null) {
                                            onImageRequested()
                                        } else {
                                            commitWatermarkChange(
                                                watermark.copy(
                                                    content = PhotoFrameWatermarkContent.IMAGE,
                                                )
                                            )
                                        }
                                    }
                                }
                            },
                            onDetent = haptics::tick,
                            label = stringResource(R.string.photo_frame_watermark_content),
                            enabled = isPro && !imageImporting,
                            wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                            accentColor = watermarkAccent,
                            modifier = Modifier.width(contentWheelWidth),
                        )
                        if (watermark.content == PhotoFrameWatermarkContent.TEXT) {
                            WatermarkTextField(
                                value = watermark.text,
                                enabled = isPro,
                                onValueChange = { value ->
                                    onWatermarkChanged(
                                        watermark.copy(
                                            text = limitPhotoFrameWatermarkText(value)
                                        )
                                    )
                                },
                                onEditingFinished = onWatermarkTextCommitted,
                                modifier = Modifier.width(editorWidth),
                            )
                        } else {
                            GlassButton(
                                onClick = onImageRequested,
                                enabled = isPro && !imageImporting,
                                shape = RoundedCornerShape(13.dp),
                                modifier = Modifier
                                    .width(editorWidth)
                                    .height(PHOTO_EFFECTS_CONTROL_HEIGHT),
                            ) {
                                if (imageImporting) {
                                    CircularProgressIndicator(
                                        color = watermarkAccent,
                                        strokeWidth = 2.dp,
                                        modifier = Modifier.size(18.dp),
                                    )
                                } else {
                                    Icon(
                                        Icons.Default.Image,
                                        contentDescription = null,
                                        tint = watermarkAccent,
                                        modifier = Modifier.size(18.dp),
                                    )
                                    Spacer(Modifier.width(6.dp))
                                    Text(
                                        stringResource(R.string.photo_frame_replace_image),
                                        style = MaterialTheme.typography.labelMedium,
                                        color = colors.onBackground,
                                    )
                                }
                            }
                        }
                    }
                }
                Spacer(Modifier.height(10.dp))
                BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
                    val wheelWidth = (maxWidth - 16.dp) / 3f
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (watermark.content == PhotoFrameWatermarkContent.TEXT) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            ReleaseCommitWheel(
                                options = fontChoices,
                                selected = fontChoices.first { it.first == watermark.font },
                                optionLabel = { it.second },
                                onValueCommitted = {
                                    focusManager.clearFocus()
                                    commitWatermarkChange(watermark.copy(font = it.first))
                                },
                                onDetent = haptics::tick,
                                label = stringResource(R.string.photo_frame_watermark_font),
                                enabled = isPro,
                                wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                                accentColor = watermarkAccent,
                                modifier = Modifier.width(wheelWidth),
                            )
                            ReleaseCommitWheel(
                                options = sizeChoices,
                                selected = sizeChoices.first { it.first == watermark.sizePercent },
                                optionLabel = { it.second },
                                onValueCommitted = {
                                    focusManager.clearFocus()
                                    commitWatermarkChange(watermark.copy(sizePercent = it.first))
                                },
                                onDetent = haptics::tick,
                                label = stringResource(R.string.photo_frame_watermark_size),
                                enabled = isPro,
                                wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                                accentColor = watermarkAccent,
                                modifier = Modifier.width(wheelWidth),
                            )
                            ReleaseCommitWheel(
                                options = opacityChoices,
                                selected = opacityChoices.first {
                                    it.first == watermark.opacityPercent
                                },
                                optionLabel = { it.second },
                                onValueCommitted = {
                                    focusManager.clearFocus()
                                    commitWatermarkChange(
                                        watermark.copy(opacityPercent = it.first)
                                    )
                                },
                                onDetent = haptics::tick,
                                label = stringResource(R.string.photo_frame_watermark_opacity),
                                enabled = isPro,
                                wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                                accentColor = watermarkAccent,
                                modifier = Modifier.width(wheelWidth),
                            )
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            ReleaseCommitWheel(
                                options = textPositionChoices,
                                selected = textPositionChoices.firstOrNull {
                                    it.first == watermark.position
                                } ?: photoPositionChoices.last(),
                                optionLabel = { it.second },
                                onValueCommitted = {
                                    focusManager.clearFocus()
                                    commitWatermarkPosition(it.first)
                                },
                                onDetent = haptics::tick,
                                label = stringResource(R.string.photo_frame_watermark_position),
                                enabled = isPro,
                                wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                                accentColor = watermarkAccent,
                                modifier = Modifier.width(wheelWidth),
                            )
                            ReleaseCommitWheel(
                                options = colorChoices,
                                selected = colorChoices.first { it.first == watermark.color },
                                optionLabel = { it.second },
                                onValueCommitted = {
                                    focusManager.clearFocus()
                                    commitWatermarkChange(watermark.copy(color = it.first))
                                },
                                onDetent = haptics::tick,
                                label = stringResource(R.string.photo_frame_watermark_color),
                                enabled = isPro,
                                wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                                accentColor = watermarkAccent,
                                modifier = Modifier.width(wheelWidth),
                            )
                            ReleaseCommitWheel(
                                options = effectChoices,
                                selected = effectChoices.first { it.first == watermark.effect },
                                optionLabel = { it.second },
                                onValueCommitted = {
                                    focusManager.clearFocus()
                                    commitWatermarkChange(watermark.copy(effect = it.first))
                                },
                                onDetent = haptics::tick,
                                label = stringResource(R.string.photo_frame_watermark_effect),
                                enabled = isPro,
                                wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                                accentColor = watermarkAccent,
                                modifier = Modifier.width(wheelWidth),
                            )
                            }
                        } else {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                ReleaseCommitWheel(
                                    options = sizeChoices,
                                    selected = sizeChoices.first {
                                        it.first == watermark.sizePercent
                                    },
                                    optionLabel = { it.second },
                                    onValueCommitted = {
                                        commitWatermarkChange(
                                            watermark.copy(sizePercent = it.first)
                                        )
                                    },
                                    onDetent = haptics::tick,
                                    label = stringResource(R.string.photo_frame_watermark_size),
                                    enabled = isPro,
                                    wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                                    accentColor = watermarkAccent,
                                    modifier = Modifier.width(wheelWidth),
                                )
                                ReleaseCommitWheel(
                                    options = opacityChoices,
                                    selected = opacityChoices.first {
                                        it.first == watermark.opacityPercent
                                    },
                                    optionLabel = { it.second },
                                    onValueCommitted = {
                                        commitWatermarkChange(
                                            watermark.copy(opacityPercent = it.first)
                                        )
                                    },
                                    onDetent = haptics::tick,
                                    label = stringResource(R.string.photo_frame_watermark_opacity),
                                    enabled = isPro,
                                    wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                                    accentColor = watermarkAccent,
                                    modifier = Modifier.width(wheelWidth),
                                )
                                ReleaseCommitWheel(
                                    options = photoPositionChoices,
                                    selected = photoPositionChoices.first {
                                        it.first == watermark.position
                                    },
                                    optionLabel = { it.second },
                                    onValueCommitted = {
                                        commitWatermarkPosition(it.first)
                                    },
                                    onDetent = haptics::tick,
                                    label = stringResource(R.string.photo_frame_watermark_position),
                                    enabled = isPro,
                                    wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                                    accentColor = watermarkAccent,
                                    modifier = Modifier.width(wheelWidth),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * 只监听没有被输入框、按钮或滚动消费的轻点；因此点空白可收起键盘，点输入框本身不会
 * 被父层抢走焦点，拖动页面也不会误触发。
 */
internal fun Modifier.clearFocusOnBackgroundTap(
    enabled: Boolean,
    clearFocus: () -> Unit,
): Modifier = pointerInput(enabled) {
    if (!enabled) return@pointerInput
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = true)
        if (waitForUpOrCancellation() != null) clearFocus()
    }
}

@Composable
@OptIn(ExperimentalFoundationApi::class)
private fun WatermarkTextField(
    value: String,
    enabled: Boolean,
    onValueChange: (String) -> Unit,
    onEditingFinished: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = AppTheme.colors
    val focusManager = LocalFocusManager.current
    val contentAlpha = if (enabled) 1f else 0.52f
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    val bringIntoViewRequester = remember { BringIntoViewRequester() }
    var wasFocused by remember { mutableStateOf(false) }
    var fieldValue by remember {
        mutableStateOf(
            TextFieldValue(
                text = value,
                selection = TextRange(value.length),
            )
        )
    }
    LaunchedEffect(value) {
        if (value != fieldValue.text) {
            fieldValue = TextFieldValue(value, TextRange(value.length))
        }
    }
    LaunchedEffect(focused) {
        if (focused) {
            // 等 BasicTextField 处理完本次点按，再把首次进入编辑的光标放到末尾。
            withFrameNanos { }
            fieldValue = fieldValue.copy(selection = TextRange(fieldValue.text.length))
            delay(180)
            bringIntoViewRequester.bringIntoView()
        }
    }
    val textStyle = MaterialTheme.typography.bodyMedium.copy(
        color = colors.onBackground.copy(alpha = contentAlpha),
        textAlign = TextAlign.Center,
    )
    val shape = RoundedCornerShape(10.dp)
    Box(
        modifier = modifier.height(PHOTO_EFFECTS_CONTROL_HEIGHT),
        contentAlignment = Alignment.CenterStart,
    ) {
        BasicTextField(
            value = fieldValue,
            onValueChange = { updated ->
                val limited = limitPhotoFrameWatermarkText(updated.text)
                fieldValue = updated.copy(
                    text = limited,
                    selection = TextRange(
                        updated.selection.start.coerceIn(0, limited.length),
                        updated.selection.end.coerceIn(0, limited.length),
                    ),
                )
                onValueChange(limited)
            },
            enabled = enabled,
            singleLine = true,
            textStyle = textStyle,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
            interactionSource = interactionSource,
            decorationBox = { innerField -> innerField() },
            modifier = Modifier
                .bringIntoViewRequester(bringIntoViewRequester)
                .onFocusChanged { state ->
                    if (state.isFocused) {
                        wasFocused = true
                    } else if (wasFocused) {
                        wasFocused = false
                        val committed = fieldValue.text.ifBlank {
                            DEFAULT_PHOTO_FRAME_WATERMARK_TEXT
                        }
                        if (committed != fieldValue.text) {
                            fieldValue = TextFieldValue(
                                committed,
                                TextRange(committed.length),
                            )
                            onValueChange(committed)
                        }
                        onEditingFinished(committed)
                    }
                }
                .fillMaxWidth()
                .clip(shape)
                .background(colors.glassSurface.copy(alpha = colors.glassSurface.alpha * contentAlpha))
                .border(
                    width = if (focused) 1.5.dp else 1.dp,
                    color = if (focused) colors.accentBlue
                        else colors.glassPanelBorder.copy(alpha = contentAlpha),
                    shape = shape,
                )
                .padding(horizontal = 14.dp, vertical = 10.dp),
        )
    }
}

@Composable
private fun PhotoEffectsPreviewLoadingPlaceholder() {
    val colors = AppTheme.colors
    val pulse = rememberInfiniteTransition(label = "photoEffectsPreviewLoading")
    val highlightAlpha by pulse.animateFloat(
        initialValue = 0.28f,
        targetValue = 0.62f,
        animationSpec = infiniteRepeatable(
            animation = tween(900, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "photoEffectsPreviewLoadingAlpha",
    )
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(PHOTO_EFFECTS_PREVIEW_LANDSCAPE_ASPECT_RATIO)
            .clip(RoundedCornerShape(12.dp))
            .background(colors.glassSurface.copy(alpha = highlightAlpha)),
    ) {
        CircularProgressIndicator(
            color = colors.accentBlue.copy(alpha = 0.76f),
            strokeWidth = 2.dp,
            modifier = Modifier.size(22.dp),
        )
    }
}

@Composable
internal fun PhotoEffectsRenderedPreview(
    source: Bitmap,
    resetOnSourceChange: Boolean = false,
    metadata: PhotoFrameMetadata = PHOTO_EFFECTS_PREVIEW_METADATA,
    sourceRotationQuarterTurns: Int,
    requestedRotationQuarterTurns: Int,
    requestedPortrait: Boolean,
    onRotate: (() -> Unit)?,
    borderEnabled: Boolean,
    preset: PhotoFramePreset,
    watermark: PhotoFrameWatermark,
    filter: PhotoFilterSelection? = null,
    prefetchFilters: List<PhotoFilterSelection> = emptyList(),
    onOpen: ((Bitmap, Rect) -> Unit)?,
) {
    val colors = AppTheme.colors
    val context = LocalContext.current
    // 相机缩略图升级为 FHD 时保留旧效果帧；本地工作台换照片则按源重置，避免串图。
    // 两种入口在首张效果帧完成前都不直接绘制原图。
    val sourceRenderIdentity: Any = if (resetOnSourceChange) source else Unit
    val rendered = remember(sourceRenderIdentity) {
        mutableStateOf<RenderedPhotoEffectsPreview?>(null)
    }
    var previewFailed by remember(sourceRenderIdentity) { mutableStateOf(false) }
    var previewBounds by remember { mutableStateOf<Rect?>(null) }
    var showUnfiltered by remember(source) { mutableStateOf(false) }
    val requestedFrameLayout = remember(borderEnabled, preset) {
        PhotoEffectsPreviewFrameLayout(
            preset = preset.takeIf { borderEnabled },
        )
    }
    val currentFilterKey = PhotoEffectsPreviewCacheKey.from(filter)
    val previewCaches = remember(
        source,
        metadata,
        sourceRotationQuarterTurns,
        borderEnabled,
        preset,
        watermark,
    ) {
        BoundedAccessCache<PhotoEffectsPreviewCacheKey, PhotoEffectsPreviewCache>(
            maxEntries = PHOTO_EFFECTS_RECENT_PREVIEW_CACHE_SIZE,
            createValue = { _: PhotoEffectsPreviewCacheKey -> PhotoEffectsPreviewCache() },
            closeValue = PhotoEffectsPreviewCache::close,
        )
    }
    DisposableEffect(previewCaches) {
        onDispose { previewCaches.close() }
    }
    val currentPreviewCache = remember(previewCaches, currentFilterKey) {
        previewCaches.getOrCreate(currentFilterKey)
    }
    val previewDemand = remember(previewCaches) { PhotoEffectsPreviewDemand() }
    // 对比图不含滤镜，切换滤镜时仍然有效；与主成片分开缓存，避免重复合成相同底图。
    val comparisonCache = if (filter == null) {
        null
    } else remember(
        source,
        metadata,
        sourceRotationQuarterTurns,
        borderEnabled,
        preset,
        watermark,
    ) { PhotoEffectsPreviewCache() }
    DisposableEffect(comparisonCache) {
        onDispose { comparisonCache?.close() }
    }
    // 滤镜计算只与原图、方向和滤镜参数有关，不应随水印大小、位置或效果一起失效。
    val filteredSourceCache = if (filter == null) {
        null
    } else remember(source, sourceRotationQuarterTurns, currentFilterKey) {
        PhotoEffectsPreviewCache()
    }
    DisposableEffect(filteredSourceCache) {
        onDispose { filteredSourceCache?.close() }
    }
    suspend fun filteredSource(selection: PhotoFilterSelection?): Bitmap {
        if (selection == null) return source
        return checkNotNull(filteredSourceCache).getOrRender(
            serializeWithOtherPreviews = false,
        ) { isCancelled ->
            PhotoFilterRenderer.render(source, selection, isCancelled)
        }
    }
    suspend fun renderPreview(
        selection: PhotoFilterSelection?,
        useCurrentFilteredSource: Boolean,
    ): Bitmap {
        val selectionKey = PhotoEffectsPreviewCacheKey.from(selection)
        val outputCache = if (selection == null && filter != null) {
            checkNotNull(comparisonCache)
        } else {
            previewCaches.getOrCreate(selectionKey)
        }
        return outputCache.getOrRender(
            isObsolete = {
                selection != null && !previewDemand.isRequested(selectionKey)
            },
        ) { isCancelled ->
            // Keep filtering inside the completed-frame cache. A recent full-preview hit must not
            // rebuild an intermediate filtered bitmap before discovering that output already exists.
            val input = if (useCurrentFilteredSource) {
                filteredSource(selection)
            } else {
                selection?.let {
                    PhotoFilterRenderer.render(source, it, isCancelled)
                } ?: source
            }
            var output: Bitmap? = null
            try {
                output = PhotoFrameExporter.renderPreview(
                    context = context,
                    source = input,
                    metadata = metadata,
                    preset = preset,
                    watermark = watermark,
                    borderEnabled = borderEnabled,
                    longEdge = PHOTO_EFFECTS_PREVIEW_RENDER_LONG_EDGE,
                    filter = null,
                )
                checkNotNull(output)
            } finally {
                // Prefetch intermediates are never displayed or retained. The selected filter's
                // intermediate keeps its existing cache so border/watermark edits do not refilter.
                // With no frame/watermark the exporter may return input itself; ownership then
                // transfers to the completed-preview cache and it must remain alive.
                if (
                    shouldRecyclePrefetchInput(
                        useCurrentFilteredSource = useCurrentFilteredSource,
                        inputIsSource = input === source,
                        outputIsInput = output === input,
                    )
                ) {
                    input.recycle()
                }
            }
        }
    }

    LaunchedEffect(currentPreviewCache, filter, prefetchFilters) {
        previewDemand.replaceRequested(
            buildSet {
                add(currentFilterKey)
                prefetchFilters.forEach { add(PhotoEffectsPreviewCacheKey.from(it)) }
            },
        )
        try {
            previewFailed = false
            val output = renderPreview(filter, useCurrentFilteredSource = true)
            ensureActive()
            rendered.value = RenderedPhotoEffectsPreview(
                bitmap = output,
                rotationQuarterTurns = sourceRotationQuarterTurns,
                frameLayout = requestedFrameLayout,
            )

            // Current output always wins. Only after it is visible do we fill the next two wheel
            // positions in order; a jump elsewhere makes obsolete pixel loops stop promptly.
            // This child runs alongside the comparison delay so prefetch does not add its own
            // duration in front of the existing long-press comparison work.
            val prefetchJob = launch {
                try {
                    prefetchFilters.forEach { nextFilter ->
                        ensureActive()
                        renderPreview(nextFilter, useCurrentFilteredSource = false)
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (outOfMemory: OutOfMemoryError) {
                    recordPhotoFramePreviewFailure(context, outOfMemory)
                } catch (error: Exception) {
                    recordPhotoFramePreviewFailure(context, error)
                }
            }

            // 对比图只跳过滤镜，继续使用完全相同的边框、水印、尺寸和元数据。
            // 无滤镜基线同样进入缓存，所有滤镜共用，不再为每次长按重复渲染。
            if (filter != null) {
                try {
                    // 主预览优先显示；继续调参时该延时会被取消，旧对比图不会抢占下一次渲染。
                    delay(PHOTO_EFFECTS_COMPARISON_DELAY_MS)
                    val comparison = renderPreview(null, useCurrentFilteredSource = false)
                    ensureActive()
                    rendered.value = RenderedPhotoEffectsPreview(
                        bitmap = output,
                        unfilteredBitmap = comparison,
                        rotationQuarterTurns = sourceRotationQuarterTurns,
                        frameLayout = requestedFrameLayout,
                    )
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (outOfMemory: OutOfMemoryError) {
                    recordPhotoFramePreviewFailure(context, outOfMemory)
                } catch (error: Exception) {
                    recordPhotoFramePreviewFailure(context, error)
                }
            }
            prefetchJob.join()
            // 不主动 recycle 上一张已交给 Compose 的位图。部分设备的渲染线程可能仍在
            // 使用上一帧纹理；解除状态引用后交给运行时回收更安全。
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (outOfMemory: OutOfMemoryError) {
            previewFailed = true
            recordPhotoFramePreviewFailure(context, outOfMemory)
        } catch (error: Exception) {
            previewFailed = true
            recordPhotoFramePreviewFailure(context, error)
        }
    }
    val preview = rendered.value
    val sourceImage = remember(source) { source.asImageBitmap() }
    val targetViewportAspectRatio = if (requestedPortrait) {
        PHOTO_EFFECTS_PREVIEW_PORTRAIT_ASPECT_RATIO
    } else {
        PHOTO_EFFECTS_PREVIEW_LANDSCAPE_ASPECT_RATIO
    }
    val viewportAspectRatio by animateFloatAsState(
        targetValue = targetViewportAspectRatio,
        animationSpec = Motion.overlayExpand,
        label = "photoFramePreviewAspectRatio",
    )
    // 首张效果帧就绪前保持图片区为空；不绘制原图、遮罩或加载层。
    // 本地工作台按新照片重置，相机的高清源升级不重置。
    val replacementVisibility = remember(sourceRenderIdentity) { Animatable(1f) }
    var visibleFrame by remember(sourceRenderIdentity) {
        mutableStateOf<RenderedPhotoEffectsPreview?>(null)
    }
    var outgoingFrame by remember(sourceRenderIdentity) {
        mutableStateOf<RenderedPhotoEffectsPreview?>(null)
    }
    val frameTransition = remember(sourceRenderIdentity) { Animatable(1f) }
    val previewForGesture = preview
    val boundsForGesture = previewBounds
    val latestOnRotate by rememberUpdatedState(onRotate)
    val latestOnOpen by rememberUpdatedState(onOpen)
    LaunchedEffect(
        requestedRotationQuarterTurns,
        requestedFrameLayout,
        visibleFrame?.rotationQuarterTurns,
        visibleFrame?.frameLayout,
    ) {
        val current = visibleFrame ?: return@LaunchedEffect
        val awaitingReplacement =
            current.rotationQuarterTurns != requestedRotationQuarterTurns ||
                current.frameLayout != requestedFrameLayout
        if (awaitingReplacement) {
            replacementVisibility.animateTo(
                targetValue = 0f,
                animationSpec = tween(durationMillis = 110, easing = LinearEasing),
            )
        } else {
            // 新方向或新边框成片先进入组合树一帧，纹理就绪后再柔和出现。
            withFrameNanos { }
            replacementVisibility.animateTo(
                targetValue = 1f,
                animationSpec = tween(durationMillis = 190, easing = FastOutSlowInEasing),
            )
        }
    }
    LaunchedEffect(preview?.bitmap) {
        val next = preview ?: return@LaunchedEffect
        val current = visibleFrame
        if (current == null) {
            visibleFrame = next
            outgoingFrame = null
            frameTransition.snapTo(1f)
        } else if (current.bitmap === next.bitmap) {
            // 无滤镜对比图稍后补齐时只更新数据，不触发第二次画面过渡。
            visibleFrame = next
        } else {
            val renderedRotationDelta = Math.floorMod(
                next.rotationQuarterTurns - current.rotationQuarterTurns,
                4,
            )
            val replacesCanvas = renderedRotationDelta != 0 ||
                current.frameLayout != next.frameLayout
            if (replacesCanvas) {
                // 旋转和边框画布变化都先让旧成片完全淡出，再换入已经按新布局渲染的
                // 成片；避免无边框、铭牌等不同比例画布直接叠加造成僵硬跳变。
                replacementVisibility.animateTo(
                    targetValue = 0f,
                    animationSpec = tween(durationMillis = 110, easing = LinearEasing),
                )
                outgoingFrame = null
                visibleFrame = next
                frameTransition.snapTo(1f)
            } else {
                outgoingFrame = current
                visibleFrame = next
                frameTransition.snapTo(0f)
                // 先让新位图以透明层进入一帧，确保纹理准备好后再开始交叉过渡。
                withFrameNanos { }
                frameTransition.animateTo(
                    1f,
                    tween(durationMillis = 220, easing = FastOutSlowInEasing),
                )
                outgoingFrame = null
            }
        }
    }
    LaunchedEffect(preview?.bitmap, preview?.unfilteredBitmap) {
        val latest = preview ?: return@LaunchedEffect
        // 对比图完成只补充当前帧的数据，绝不取消仍在进行的滤镜渐入动画。
        if (visibleFrame?.bitmap === latest.bitmap) {
            visibleFrame = latest
        }
    }
    LaunchedEffect(previewFailed) {
        if (previewFailed) {
            // 新方向或新边框渲染失败时恢复旧成片，避免预览永久停在透明状态。
            replacementVisibility.animateTo(
                targetValue = 1f,
                animationSpec = tween(durationMillis = 190, easing = FastOutSlowInEasing),
            )
        }
    }
    Column {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .fillMaxWidth()
                // 不包设置卡片：省下描边和 12dp 内边距，把整块可用宽高留给真实成片预览。
                // 横图和竖图各用稳定视口；边框成片在内部 Fit，完整呈现对应方向的留白与铭牌。
                .aspectRatio(viewportAspectRatio)
                .onGloballyPositioned { previewBounds = it.boundsInRoot() }
                .pointerInput(previewForGesture, boundsForGesture) {
                    if (previewForGesture == null || boundsForGesture == null) return@pointerInput
                    detectTapGestures(
                        onPress = {
                            try {
                                tryAwaitRelease()
                            } finally {
                                showUnfiltered = false
                            }
                        },
                        onTap = {
                            latestOnOpen?.invoke(previewForGesture.bitmap, boundsForGesture)
                        },
                        onDoubleTap = { latestOnRotate?.invoke() },
                        onLongPress = {
                            if (previewForGesture.unfilteredBitmap != null) {
                                showUnfiltered = true
                            }
                        },
                    )
                },
        ) {
            if (preview != null) {
                outgoingFrame?.let { frame ->
                    PhotoEffectsPreviewLayer(
                        frame = frame,
                        showUnfiltered = showUnfiltered,
                        // 旧帧保持不透明作为底层，新帧只负责渐入；总画面始终不透底，
                        // 避免普通双向淡化在中点产生一次明显的亮度闪烁。
                        alpha = replacementVisibility.value,
                        description = null,
                    )
                }
                (visibleFrame ?: preview).let { frame ->
                    PhotoEffectsPreviewLayer(
                        frame = frame,
                        showUnfiltered = showUnfiltered,
                        alpha = replacementVisibility.value *
                            if (outgoingFrame == null) 1f else frameTransition.value,
                        description = stringResource(R.string.photo_frame_preview),
                    )
                }
            } else if (previewFailed) {
                Image(
                    bitmap = sourceImage,
                    contentDescription = stringResource(R.string.photo_frame_preview),
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
                Surface(
                    color = colors.glassSurfaceHeavy,
                    shape = RoundedCornerShape(10.dp),
                    modifier = Modifier.align(Alignment.BottomCenter),
                ) {
                    Text(
                        text = stringResource(R.string.photo_frame_preview_unavailable),
                        style = MaterialTheme.typography.labelSmall,
                        color = colors.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                    )
                }
            }
            if (previewFailed && preview != null) {
                Surface(
                    color = colors.glassSurfaceHeavy,
                    shape = RoundedCornerShape(10.dp),
                    modifier = Modifier.align(Alignment.BottomCenter),
                ) {
                    Text(
                        text = stringResource(R.string.photo_frame_preview_unavailable),
                        style = MaterialTheme.typography.labelSmall,
                        color = colors.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun PhotoEffectsPreviewLayer(
    frame: RenderedPhotoEffectsPreview,
    showUnfiltered: Boolean,
    alpha: Float,
    description: String?,
) {
    val displayedBitmap = if (showUnfiltered) {
        frame.unfilteredBitmap ?: frame.bitmap
    } else {
        frame.bitmap
    }
    val imageBitmap = remember(displayedBitmap) { displayedBitmap.asImageBitmap() }
    FittedRotatingBitmap(
        image = imageBitmap,
        rotationDegrees = 0f,
        description = description,
        modifier = Modifier
            .fillMaxSize()
            .graphicsLayer { this.alpha = alpha },
    )
}

private const val PHOTO_EFFECTS_PREVIEW_LANDSCAPE_ASPECT_RATIO = 4f / 3f
private const val PHOTO_EFFECTS_PREVIEW_PORTRAIT_ASPECT_RATIO = 3f / 4f
private val PHOTO_EFFECTS_CONTROL_HEIGHT = 48.dp
// 顶部两行共用 4:3 栅格：名称类波轮更舒展，数值/开关波轮更紧凑，收藏方钮保持对齐。
private const val PHOTO_EFFECTS_PRIMARY_WHEEL_WEIGHT = 4f
private const val PHOTO_EFFECTS_SECONDARY_WHEEL_WEIGHT = 3f
// 与相机 FHD 预览源保持一致，避免高密度屏幕或放大查看时出现二次缩放模糊。
private const val PHOTO_EFFECTS_PREVIEW_RENDER_LONG_EDGE = 1_920
private const val PHOTO_EFFECTS_RECENT_PREVIEW_CACHE_SIZE = 3
private const val PHOTO_EFFECTS_FORWARD_PREFETCH_COUNT = 2
private const val PHOTO_EFFECTS_COMPARISON_DELAY_MS = 500L
private const val PHOTO_EFFECTS_TEXT_PREVIEW_DELAY_MS = 140L
private const val PHOTO_EFFECTS_FALLBACK_GRACE_MS = 2_200L
// 边框合成无法在 Canvas 绘制途中取消；全局串行可防止旧 FHD 成片并发拖慢最新预览。
private val photoEffectsPreviewRenderMutex = Mutex()

private fun rotatePreviewBitmap(source: Bitmap, quarterTurns: Int): Bitmap {
    val normalized = Math.floorMod(quarterTurns, 4)
    if (normalized == 0) return source
    val matrix = Matrix().apply { setRotate(-90f * normalized) }
    return Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true)
}

private data class RenderedPhotoEffectsPreview(
    val bitmap: Bitmap,
    val unfilteredBitmap: Bitmap? = null,
    val rotationQuarterTurns: Int,
    val frameLayout: PhotoEffectsPreviewFrameLayout,
)

/** 只有真正改变输出画布的边框样式才走完整淡出淡入；无边框时忽略保留的预设草稿。 */
private data class PhotoEffectsPreviewFrameLayout(
    val preset: PhotoFramePreset?,
)

private data class PhotoEffectsPreviewCacheKey(
    val filterId: String?,
    val intensityPercent: Int,
) {
    companion object {
        fun from(selection: PhotoFilterSelection?): PhotoEffectsPreviewCacheKey =
            selection?.let {
                PhotoEffectsPreviewCacheKey(
                    filterId = it.preset.id,
                    intensityPercent = it.normalizedIntensityPercent,
                )
            } ?: PhotoEffectsPreviewCacheKey(null, 0)
    }
}

/** The selected filter and its two forward neighbors are the only valid filter pixel work. */
private class PhotoEffectsPreviewDemand {
    @Volatile
    private var requested: Set<PhotoEffectsPreviewCacheKey> = emptySet()

    fun replaceRequested(keys: Set<PhotoEffectsPreviewCacheKey>) {
        requested = keys
    }

    fun isRequested(key: PhotoEffectsPreviewCacheKey): Boolean = key in requested
}

internal fun shouldRecyclePrefetchInput(
    useCurrentFilteredSource: Boolean,
    inputIsSource: Boolean,
    outputIsInput: Boolean,
): Boolean = !useCurrentFilteredSource && !inputIsSource && !outputIsInput

/**
 * 单个明确渲染目标的一帧缓存。
 *
 * 同一目标的请求共享一个 [Deferred]；不同实例通过全局渲染锁串行，取消的等待任务不会
 * 继续抢 CPU。最近完成的三个完整预览由外层有界缓存持有；位图只解除引用而不主动
 * recycle，避免 Compose 仍在使用旧帧纹理。
 */
private class PhotoEffectsPreviewCache {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val mutex = Mutex()
    private var completed: Bitmap? = null
    private var running: Deferred<Bitmap>? = null

    suspend fun getOrRender(
        isObsolete: () -> Boolean = { false },
        serializeWithOtherPreviews: Boolean = true,
        render: suspend (isCancelled: () -> Boolean) -> Bitmap,
    ): Bitmap {
        while (true) {
            val task = mutex.withLock {
                completed?.let { return it }
                running?.takeUnless { it.isCancelled } ?: scope.async {
                    val renderNow: suspend () -> Bitmap = {
                        ensureActive()
                        render { !isActive || isObsolete() }
                    }
                    if (serializeWithOtherPreviews) {
                        photoEffectsPreviewRenderMutex.withLock { renderNow() }
                    } else {
                        renderNow()
                    }
                }.also { running = it }
            }
            val bitmap = try {
                task.await()
            } catch (error: Throwable) {
                // Awaiter cancellation does not cancel the cache-owned shared task. Keep it
                // published so a prefetched filter promoted to current can join the same work.
                if (task.isCancelled) {
                    mutex.withLock {
                        if (running === task) running = null
                    }
                    // A task can become obsolete, cancel, and then be requested as the new current
                    // filter. Retry transparently instead of exposing that harmless race as failure.
                    if (
                        error is CancellationException &&
                        currentCoroutineContext().isActive &&
                        !isObsolete()
                    ) {
                        continue
                    }
                }
                throw error
            }
            return mutex.withLock {
                completed ?: bitmap.also {
                    if (running === task) running = null
                    completed = it
                }
            }
        }
    }

    fun close() {
        scope.cancel()
    }
}

private data class RotatedPreviewSource(
    val bitmap: Bitmap,
    val quarterTurns: Int,
)

private val PHOTO_EFFECTS_PREVIEW_METADATA = PhotoFrameMetadata(
    make = "NIKON CORPORATION",
    model = "NIKON Z 8",
    aperture = "2.8",
    shutter = "1/250",
    iso = "ISO100",
    focalLength = "50mm",
    dateTime = "2026-08-04 10:30:00",
)

internal fun cameraEffectPreviewMetadata(
    manufacturer: String?,
    model: String?,
    exif: PhotoExif? = null,
): PhotoFrameMetadata = PHOTO_EFFECTS_PREVIEW_METADATA.copy(
    make = manufacturer?.trim()?.takeIf(String::isNotEmpty)
        ?: PHOTO_EFFECTS_PREVIEW_METADATA.make,
    model = model?.trim()?.takeIf(String::isNotEmpty)
        ?: PHOTO_EFFECTS_PREVIEW_METADATA.model,
    aperture = exif?.aperture?.trim()?.takeIf(String::isNotEmpty)
        ?: PHOTO_EFFECTS_PREVIEW_METADATA.aperture,
    shutter = exif?.shutterSpeed?.trim()?.takeIf(String::isNotEmpty)
        ?: PHOTO_EFFECTS_PREVIEW_METADATA.shutter,
    iso = exif?.iso?.trim()?.takeIf(String::isNotEmpty)
        ?: PHOTO_EFFECTS_PREVIEW_METADATA.iso,
    focalLength = exif?.focalLength?.trim()?.takeIf(String::isNotEmpty)
        ?: PHOTO_EFFECTS_PREVIEW_METADATA.focalLength,
    dateTime = normalizeCaptureDateTime(exif?.dateTime)
        ?: PHOTO_EFFECTS_PREVIEW_METADATA.dateTime,
)

private fun createPhotoFramePreviewSource(): Bitmap {
    val bitmap = Bitmap.createBitmap(
        PHOTO_EFFECTS_PREVIEW_RENDER_LONG_EDGE,
        PHOTO_EFFECTS_PREVIEW_RENDER_LONG_EDGE * 2 / 3,
        Bitmap.Config.ARGB_8888,
    )
    val canvas = Canvas(bitmap)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    paint.shader = LinearGradient(
        0f,
        0f,
        bitmap.width.toFloat(),
        bitmap.height.toFloat(),
        intArrayOf(
            android.graphics.Color.rgb(111, 169, 181),
            android.graphics.Color.rgb(214, 192, 151),
        ),
        null,
        Shader.TileMode.CLAMP,
    )
    canvas.drawRect(0f, 0f, bitmap.width.toFloat(), bitmap.height.toFloat(), paint)
    paint.shader = null
    paint.color = android.graphics.Color.rgb(47, 85, 94)
    canvas.rotate(-24f, bitmap.width * 0.5f, bitmap.height * 0.5f)
    canvas.drawRect(-80f, 215f, 820f, 330f, paint)
    canvas.rotate(24f, bitmap.width * 0.5f, bitmap.height * 0.5f)
    paint.color = android.graphics.Color.rgb(244, 193, 91)
    canvas.drawCircle(bitmap.width * 0.72f, bitmap.height * 0.24f, 42f, paint)
    return bitmap
}

/**
 * 设置页开关统一入口：开关值真正改变时才触发轻触反馈。
 *
 * 触感反馈开关本身始终允许播放这一次确认反馈，这样从关闭切到开启时，
 * 用户能够立即知道设置已经生效；其余开关严格受全局触感偏好控制。
 */
@Composable
private fun SettingsSwitch(
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    hapticsEnabled: Boolean,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    isHapticsPreference: Boolean = false,
) {
    val switchHaptics = rememberHaptics(hapticsEnabled || isHapticsPreference)
    Switch(
        checked = checked,
        onCheckedChange = { newValue ->
            if (newValue != checked) {
                switchHaptics.tick()
                onCheckedChange(newValue)
            }
        },
        modifier = modifier,
        enabled = enabled,
    )
}

/**
 * 设置分区卡片：面板内的一块玻璃子容器——极淡的内嵌底色 + 细描边圆角，
 * 把相关设置聚成一个视觉区域。[borderColor] 可覆盖描边（如目录未设时橙色强调）。
 */
@Composable
private fun SettingsCard(
    modifier: Modifier = Modifier,
    borderColor: Color = AppTheme.colors.glassPanelBorder,
    tintColor: Color? = null,
    pressAccentColor: Color? = null,
    attentionColor: Color? = null,
    attentionProgress: Float = 0f,
    enabled: Boolean = true,
    onClick: (() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit
) {
    val shape = RoundedCornerShape(14.dp)
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val enhancedPress = pressAccentColor != null
    val pressScale by animateFloatAsState(
        targetValue = if (pressed && enabled && onClick != null) {
            if (enhancedPress) 0.982f else 0.992f
        } else {
            1f
        },
        animationSpec = if (pressed) tween(80) else Motion.bouncy(),
        label = "settingsCardPress",
    )
    val pressProgress by animateFloatAsState(
        targetValue = if (pressed && enabled && onClick != null && enhancedPress) 1f else 0f,
        animationSpec = if (pressed) tween(90) else Motion.bouncy(),
        label = "settingsCardPressHighlight",
    )
    val normalizedAttention = attentionProgress.coerceIn(0f, 1f)
    val effectiveBorderColor = when {
        pressAccentColor != null && pressProgress > 0f -> pressAccentColor.copy(
            alpha = 0.52f + 0.30f * pressProgress,
        )
        attentionColor != null -> attentionColor.copy(
            alpha = 0.72f + 0.26f * normalizedAttention,
        )
        else -> borderColor
    }
    val effectiveBorderWidth = when {
        pressProgress > 0f -> 1f + 0.45f * pressProgress
        attentionColor != null -> 1.25f + 0.75f * normalizedAttention
        else -> 1f
    }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .graphicsLayer {
                scaleX = pressScale
                scaleY = pressScale
            }
            .clip(shape)
            .then(
                if (onClick != null) {
                    Modifier.clickable(
                        enabled = enabled,
                        interactionSource = interactionSource,
                        indication = null,
                        onClick = onClick,
                    )
                } else {
                    Modifier
                }
            )
            // onBackground 极低透明度：深色主题下是白色微提亮、浅色下是黑色微压暗，两套都成立。
            .background(AppTheme.colors.onBackground.copy(alpha = 0.04f))
            .then(
                tintColor?.let { accent ->
                    Modifier.background(accent.copy(alpha = 0.040f))
                } ?: Modifier
            )
            .then(
                attentionColor?.let { accent ->
                    Modifier.background(
                        accent.copy(alpha = 0.055f + 0.075f * normalizedAttention)
                    )
                } ?: Modifier
            )
            .then(
                pressAccentColor?.let { accent ->
                    Modifier.background(accent.copy(alpha = 0.10f * pressProgress))
                } ?: Modifier
            )
            .border(
                width = effectiveBorderWidth.dp,
                color = effectiveBorderColor,
                shape = shape,
            )
            .padding(12.dp),
        content = content
    )
}

/** 卡片内子项之间的细分隔线（上下留呼吸间距）。 */
@Composable
private fun CardDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp)
            .height(1.dp)
            .background(AppTheme.colors.glassPanelBorder)
    )
}

@Composable
private fun CompactVerticalDivider() {
    Box(
        modifier = Modifier
            .padding(horizontal = 12.dp)
            .width(1.dp)
            .height(30.dp)
            .background(AppTheme.colors.glassPanelBorder)
    )
}

/**
 * 页脚版本铭牌。点击区域仍完整承载原来的七连击调试入口，只改变视觉，不改变页脚布局。
 */
@Composable
private fun VersionPlaque(
    text: String,
    onClick: () -> Unit,
) {
    val colors = AppTheme.colors
    val shape = RoundedCornerShape(7.dp)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .clip(shape)
            .background(
                Brush.verticalGradient(
                    listOf(
                        colors.onBackground.copy(alpha = 0.10f),
                        colors.onBackground.copy(alpha = 0.035f),
                    )
                )
            )
            .border(1.dp, colors.glassPanelBorder, shape)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick,
            )
            .padding(horizontal = 8.dp, vertical = 5.dp),
    ) {
        Box(
            Modifier
                .size(3.dp)
                .background(colors.onSurfaceVariant.copy(alpha = 0.42f), RoundedCornerShape(50))
        )
        Text(
            text = text,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Medium,
            color = colors.onSurfaceVariant.copy(alpha = 0.82f),
            maxLines = 1,
        )
        Box(
            Modifier
                .size(3.dp)
                .background(colors.onSurfaceVariant.copy(alpha = 0.42f), RoundedCornerShape(50))
        )
    }
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
    big: Boolean = false,
    enabled: Boolean = true,
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
        enabled = enabled,
        shape = RoundedCornerShape(if (big) 16.dp else 14.dp),
        color = Color.Transparent,
        shadowElevation = 4.dp,
        modifier = modifier
            .then(if (big) Modifier.heightIn(min = 48.dp) else Modifier.height(28.dp))
            .clip(RoundedCornerShape(if (big) 16.dp else 14.dp))
            .graphicsLayer { alpha = if (enabled) 1f else 0.5f }
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
                            listOf(
                                Color.Transparent,
                                Color(0xFFFFE5A0).copy(alpha = 0.65f),
                                Color.Transparent,
                            )
                        )
                    )
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(if (big) 6.dp else 4.dp),
                modifier = Modifier
                    .then(if (big) Modifier else Modifier.fillMaxHeight())
                    .padding(horizontal = 12.dp, vertical = if (big) 10.dp else 0.dp)
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
                    color = Color(0xFF4A3216),
                    textAlign = TextAlign.Center,
                    maxLines = if (big) 2 else 1,
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
    textStyle: TextStyle = MaterialTheme.typography.labelLarge,
    compact: Boolean = false,
    height: Dp = if (compact) 34.dp else 40.dp,
    maxLines: Int = 1,
) {
    val colors = AppTheme.colors
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(8.dp),
        color = if (selected) colors.accentBlue else colors.surfaceVariant,
        modifier = modifier.height(height)
    ) {
        Box(contentAlignment = Alignment.Center) {
            Text(
                text = label,
                style = textStyle,
                fontWeight = FontWeight.Bold,
                maxLines = maxLines,
                textAlign = TextAlign.Center,
                color = if (selected) colors.onAccent else colors.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun SectionLabel(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = AppTheme.colors.onBackground,
) {
    Text(
        text,
        modifier = modifier,
        style = MaterialTheme.typography.titleSmall,
        fontWeight = FontWeight.SemiBold,
        color = color,
    )
}
