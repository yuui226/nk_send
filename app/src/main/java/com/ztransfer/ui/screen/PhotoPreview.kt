package com.ztransfer.ui.screen

import androidx.activity.compose.BackHandler
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.BurstMode
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.FilterCenterFocus
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.sp
import kotlin.math.abs
import kotlin.math.max
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.ui.theme.*
import com.ztransfer.ui.util.rememberHaptics
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.PhotoExif

// 视频扩展名：无高清封面，预览走"压暗缩略图 + 视频占位"分支。
// 注意与 CameraViewModel.VIDEO_EXTENSIONS（封面黑边兜底）保持同步。
private val VIDEO_EXTENSIONS = setOf(".mov", ".mp4")

/**
 * 全屏照片预览层：显示缓存缩略图的**未裁切**（Fit）完整画面，可左右翻页浏览整份列表。
 * 整体从被长按格子 [anchorRect] 的位置缩放展开，关闭时反向缩回（从哪来回哪去）。
 * 不下载原图（缩略图低清但瞬开、不抢传输通道）。
 * 本层在深浅两种主题下都保持黑底沉浸式（照片查看器惯例，黑底最衬照片），
 * 因此内部直接用深色常量而非主题 token——这是有意的，不参与深浅切换。
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PhotoPreviewOverlay(
    files: List<NikonCamera.FileInfo>,
    initialIndex: Int,
    anchorRect: Rect?,
    cameraViewModel: CameraViewModel,
    hapticsEnabled: Boolean,
    // 连拍成员 handle 集(列表页的检测结果):预览左上角展示连拍角标用;空集即不展示。
    burstHandles: Set<Int> = emptySet(),
    // 已在传输队列中的 handle（任意状态）：当前页据此切换"加入 / 已入队"按钮。
    queuedHandles: Set<Int> = emptySet(),
    // 把当前预览文件加入传输队列（父层负责目录校验、连接状态、入队与吸入动画）。
    onTransfer: (NikonCamera.FileInfo) -> Unit = {},
    onDismiss: () -> Unit
) {
    val pagerState = rememberPagerState(initialPage = initialIndex) { files.size }
    var overlayBounds by remember { mutableStateOf<Rect?>(null) }
    val progress = remember { Animatable(0f) }
    var closing by remember { mutableStateOf(false) }

    LaunchedEffect(overlayBounds, closing) {
        if (!closing && overlayBounds != null && progress.value < 1f) {
            progress.animateTo(1f, Motion.overlayExpand)
        }
    }
    LaunchedEffect(closing) {
        if (closing) {
            progress.animateTo(0f, Motion.overlayCollapse)
            onDismiss()
        }
    }
    val startClose: () -> Unit = { closing = true }
    BackHandler(enabled = !closing) { startClose() }

    // ---- FHD 预览：优先级加载 + 即时淘汰 + RGB_565 解码 ----
    // 三个状态图按 handle 存储；handle 仅在本 overlay 存活期有效（关闭随 Composable 释放），
    // 无跨会话复用问题。fhdFailed=已试且失败（不再重试，直到被淘汰后重新进入才重试）。
    val fhdBitmaps = remember { mutableStateMapOf<Int, ImageBitmap>() }
    val fhdLoading = remember { mutableStateMapOf<Int, Boolean>() }
    val fhdFailed = remember { mutableStateMapOf<Int, Boolean>() }
    val exifData = remember { mutableStateMapOf<Int, PhotoExif?>() }
    val exifLoading = remember { mutableStateMapOf<Int, Boolean>() }
    // 对焦点显示开关：按住对焦按钮时置 true，松手恢复 false。
    var showAfPoint by remember { mutableStateOf(false) }
    // 按住 AF 按钮期间翻页：按钮实例连同手势协程一起被移除，onPress 的松手复位不再执行，
    // showAfPoint 会卡在 true（下一张的红框常亮）。翻页时强制复位兜底。
    LaunchedEffect(pagerState.currentPage) { showAfPoint = false }

    val haptics = rememberHaptics(hapticsEnabled)

    // 预览期间暂停后台缩略图填充，把 ioMutex 让给 FHD/EXIF 取图。
    DisposableEffect(Unit) {
        cameraViewModel.setFhdActive(true)
        onDispose { cameraViewModel.setFhdActive(false) }
    }

    // 加载单页 FHD；返回 true 表示"本次确实取到并解码成功"（用于当前页到位的触感反馈）。
    suspend fun loadFhdPage(page: Int): Boolean {
        val file = files.getOrNull(page) ?: return false
        // 视频没有高清封面（FHD 操作码只对照片有效），不发注定失败的请求、也不显示加载条。
        if (file.extension in VIDEO_EXTENSIONS) return false
        val h = file.handle
        if (h in fhdBitmaps || fhdLoading.containsKey(h) || fhdFailed.containsKey(h)) return false
        fhdLoading[h] = true
        try {
            val res = cameraViewModel.loadFhdPreview(file) ?: run { fhdFailed[h] = true; return false }
            fhdBitmaps[h] = res
            return true
        } finally {
            fhdLoading.remove(h)
        }
    }

    // 加载单页 EXIF（仅当前页，不预加载邻居——EXIF 只在当前页底栏显示，预加载纯浪费通道）。
    suspend fun loadExifPage(page: Int) {
        val file = files.getOrNull(page) ?: return
        val h = file.handle
        if (h in exifData || exifLoading.containsKey(h)) return
        exifLoading[h] = true
        try {
            exifData[h] = cameraViewModel.loadExif(file)
        } finally {
            exifLoading.remove(h)
        }
    }

    // 即时淘汰（独立 effect，翻页瞬间就跑，不排在 1–3s 的慢加载后面）：保留窗口 ±2。
    // 与加载解耦是关键——否则快速翻页时淘汰永远排在慢加载之后、来不及执行，内存会一路涨。
    LaunchedEffect(pagerState.currentPage) {
        val cp = pagerState.currentPage
        val keep = (cp - 2).coerceAtLeast(0)..(cp + 2).coerceAtMost(files.lastIndex)
        val keepH = keep.mapNotNull { files.getOrNull(it)?.handle }.toSet()
        fhdBitmaps.keys.filter { it !in keepH }.forEach { fhdBitmaps.remove(it) }
        fhdFailed.keys.filter { it !in keepH }.forEach { fhdFailed.remove(it) }
        exifData.keys.filter { it !in keepH }.forEach { exifData.remove(it) }
    }

    // 优先级加载：当前页 FHD（到位轻震一下）→ 当前页 EXIF → ±1 邻居 FHD 预取。
    // 换页即取消本协程，未完成的慢加载自动中止（getFhdPicture 会抛 Cancellation 释放锁），
    // 通道立刻让给新的当前页。首次打开也走这里（currentPage 初值即 initialIndex）。
    // key 额外依赖 fhdBitmaps[currentPage]：淘汰 effect 移除缓存后即使 currentPage 不变
    // 也能重新触发加载，避免用户翻回来时 FHD 不显示。
    LaunchedEffect(pagerState.currentPage, fhdBitmaps[files.getOrNull(pagerState.currentPage)?.handle]) {
        val cp = pagerState.currentPage
        if (loadFhdPage(cp)) haptics.tick()   // 仅"当前页真正取到高清"这一刻反馈
        loadExifPage(cp)
        if (cp > 0) loadFhdPage(cp - 1)
        if (cp < files.lastIndex) loadFhdPage(cp + 1)
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .onGloballyPositioned { overlayBounds = it.boundsInRoot() }
            // 消费未被翻页器处理的拖动（如竖向滑动），防止滚动穿透到底下的照片网格；
            // 横向翻页由更深层的 Pager 先消费，不受影响。
            .pointerInput(Unit) { detectDragGestures { change, _ -> change.consume() } }
    ) {
        // 黑色背景：随进度淡入。
        Box(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer { alpha = progress.value }
                .background(Color.Black.copy(alpha = 0.85f))
        )

        // 当前页是否已放大——放大时禁用翻页，横向平移才不会误翻到下一张。
        var currentZoomed by remember { mutableStateOf(false) }

        // 图片翻页器：整体从被长按格子的位置缩放展开。相邻页预载一页，快速翻页不用等图。
        HorizontalPager(
            state = pagerState,
            beyondBoundsPageCount = 1,
            userScrollEnabled = !currentZoomed,
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    val ob = overlayBounds
                    val ar = anchorRect
                    // 已翻页离开初始张时，关闭不再缩回原格子（位置早对不上，会"飞回"错误
                    // 的格子造成视觉断裂），改为原地线性淡出。
                    val shrinkToAnchor = pagerState.currentPage == initialIndex
                    if (shrinkToAnchor && ob != null && ar != null && ob.width > 0f && ob.height > 0f) {
                        transformOrigin = TransformOrigin(
                            (ar.center.x - ob.left) / ob.width,
                            (ar.center.y - ob.top) / ob.height
                        )
                        val startScale = (ar.width / ob.width).coerceIn(0.05f, 1f)
                        val s = startScale + (1f - startScale) * progress.value
                        scaleX = s
                        scaleY = s
                        alpha = (progress.value * 1.6f).coerceAtMost(1f)
                    } else {
                        scaleX = 1f
                        scaleY = 1f
                        alpha = progress.value
                    }
                }
        ) { page ->
            val file = files[page]
            PreviewPage(
                file = file,
                cameraViewModel = cameraViewModel,
                fhdBitmap = fhdBitmaps[file.handle],
                isLoadingFhd = fhdLoading.containsKey(file.handle),
                exif = exifData[file.handle],
                showAfPoint = showAfPoint,
                isCurrent = page == pagerState.currentPage,
                onZoomedChange = { currentZoomed = it },
                onTap = startClose
            )
        }

        // 顶部：序号 + 文件名（随进度淡入，不参与缩放）。
        val current = files.getOrNull(pagerState.currentPage)
        if (current != null) {
            Text(
                text = "${pagerState.currentPage + 1}/${files.size}  ·  ${current.fileName}",
                style = MaterialTheme.typography.labelMedium,
                color = Color.White.copy(alpha = 0.85f * progress.value),
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(top = 12.dp, start = 16.dp, end = 16.dp)
            )
        }

        // 左上角：连拍/保护角标——与列表页缩略图的角标同语义,预览中集中到左上,
        // 圆角胶囊形态适配大图舞台;位于标题行下方一行,随展开进度淡入,不参与缩放。
        if (current != null && (current.handle in burstHandles || current.isProtected)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .statusBarsPadding()
                    .padding(top = 36.dp, start = 12.dp)
                    .graphicsLayer { alpha = progress.value }
            ) {
                if (current.handle in burstHandles) {
                    Surface(
                        shape = RoundedCornerShape(7.dp),
                        color = BurstBadgeColor.copy(alpha = 0.85f)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(3.dp),
                            modifier = Modifier.padding(horizontal = 7.dp, vertical = 3.dp)
                        ) {
                            Icon(
                                Icons.Default.BurstMode,
                                contentDescription = null,
                                tint = Color.White,
                                modifier = Modifier.size(12.dp)
                            )
                            Text(
                                text = stringResource(R.string.burst_label),
                                style = MaterialTheme.typography.labelSmall.copy(fontSize = 10.sp, lineHeight = 11.sp),
                                fontWeight = FontWeight.Medium,
                                color = Color.White
                            )
                        }
                    }
                }
                if (current.isProtected) {
                    // 黑底胶囊在黑幕/暗部照片上需要细描边定界(列表页衬在照片上无此问题)。
                    // 钥匙 + "保护"文字，与旁边的连拍角标（图标+字）一致。
                    Surface(
                        shape = RoundedCornerShape(7.dp),
                        color = Color.Black.copy(alpha = 0.45f),
                        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.22f))
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(3.dp),
                            modifier = Modifier.padding(horizontal = 7.dp, vertical = 3.dp)
                        ) {
                            Icon(
                                Icons.Default.Key,
                                contentDescription = null,
                                tint = Color.White.copy(alpha = 0.9f),
                                modifier = Modifier.size(12.dp)
                            )
                            Text(
                                text = stringResource(R.string.filter_protected),
                                style = MaterialTheme.typography.labelSmall.copy(fontSize = 10.sp, lineHeight = 11.sp),
                                fontWeight = FontWeight.Medium,
                                color = Color.White
                            )
                        }
                    }
                }
            }
        }

        // 顶部极细进度条：当前页正在取 FHD 高清版时显示（"正在加载高清"的低调提示，
        // 取代旧的突兀底部小转圈）。随展开动画淡入，取到即消失。
        val curLoadingFhd = current?.let { fhdLoading.containsKey(it.handle) } == true
        if (curLoadingFhd) {
            LinearProgressIndicator(
                color = AccentBlue.copy(alpha = 0.9f),
                trackColor = Color.Transparent,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .height(2.dp)
                    .graphicsLayer { alpha = progress.value }
            )
        }

        // ---- 底部栏：EXIF 参数 + 对焦点按钮，同一水平线 ----
        // 跟手淡入淡出：alpha 由翻页滚动进度实时驱动——离开当前页时随手指滑动淡出、
        // 新页吸附到位时淡入，不等翻完。内容在滑过半（currentPage 翻转、此刻 alpha≈0
        // 看不见）时切换，因此看不到硬切；Crossfade 再兜住"落定页 EXIF 异步到达"的淡入。
        // alpha 计算写在 graphicsLayer 内读滚动值：每帧只重绘图层，不触发子树重组。
        // lastExif：翻页时保留上一页的 EXIF 直到新页 EXIF 加载完成，避免 Crossfade
        // 经历 旧→null→新 三次状态导致闪烁。
        var lastExif by remember { mutableStateOf<PhotoExif?>(null) }
        val curExif = current?.let { exifData[it.handle] }
        if (curExif != null) lastExif = curExif
        Crossfade(
            targetState = lastExif,
            animationSpec = tween(220),
            label = "exifBar",
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .graphicsLayer {
                    val swipe = (1f - abs(pagerState.currentPageOffsetFraction) * 2f).coerceIn(0f, 1f)
                    alpha = progress.value * swipe
                }
        ) { exif ->
            val hasExif = exif != null && (exif.aperture != null || exif.shutterSpeed != null
                || exif.iso != null || exif.focalLength != null)
            if (hasExif) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .navigationBarsPadding()
                        .padding(horizontal = 16.dp)
                        .heightIn(min = 44.dp)
                        .padding(vertical = 24.dp),
                    verticalAlignment = Alignment.Bottom
                ) {
                    ExifMetadataBar(
                        exif = exif!!,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                }
            }
        }

        // 右下角：对焦点按钮（有 AF 数据时显示）+ 传输队列按钮，纵向排列。
        if (current != null) {
            val curHasAf = lastExif?.afX != null
            val curQueued = current.handle in queuedHandles
            Column(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .navigationBarsPadding()
                    .padding(end = 20.dp, bottom = 80.dp)
                    .graphicsLayer { alpha = progress.value },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                TransferQueueButton(
                    queued = curQueued,
                    onClick = { onTransfer(current) }
                )
                if (curHasAf) {
                    FocusPointButton(
                        pressed = showAfPoint,
                        onPressChange = { showAfPoint = it }
                    )
                }
            }
        }
    }
}

/**
 * 底部毛玻璃参数条：光圈 / 快门 / ISO / 焦距。
 * 淡入淡出由外层（overlay 展开进度 × 翻页跟手 × Crossfade）统一驱动，本身不管透明度。
 */
@Composable
private fun ExifMetadataBar(
    exif: PhotoExif,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    val parts = listOfNotNull(exif.aperture, exif.shutterSpeed, exif.iso, exif.focalLength)
    if (parts.isEmpty()) return
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = colors.glassSurfaceHeavy,
        shadowElevation = 4.dp,
        border = BorderStroke(1.dp, colors.glassPanelBorder),
        modifier = modifier
    ) {
        Text(
            text = parts.joinToString("  ·  "),
            style = MaterialTheme.typography.labelLarge,
            color = colors.onBackground,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp)
        )
    }
}

/**
 * 对焦点查看按钮：玻璃圆形，按住期间 [pressed]=true（视觉高亮 + 对焦点红框叠加）。
 * 手势处理与 RemoteScreen 参数加减按钮一致：detectTapGestures(onPress = ...) + tryAwaitRelease。
 */
@Composable
private fun FocusPointButton(
    pressed: Boolean,
    onPressChange: (Boolean) -> Unit
) {
    val colors = AppTheme.colors
    Box(
        modifier = Modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(if (pressed) colors.accentBlue.copy(alpha = 0.35f) else colors.glassSurface)
            .pointerInput(Unit) {
                detectTapGestures(onPress = {
                    onPressChange(true)
                    tryAwaitRelease()
                    onPressChange(false)
                })
            },
        contentAlignment = Alignment.Center
    ) {
        // 毛玻璃高光 + 描边
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Brush.verticalGradient(listOf(colors.glassHighlightTop, colors.glassHighlightBottom)))
                .border(1.dp, Brush.verticalGradient(listOf(colors.glassBorderTop, colors.glassBorderBottom)), CircleShape),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = Icons.Default.FilterCenterFocus,
                contentDescription = stringResource(R.string.cd_focus_point),
                tint = if (pressed) colors.accentBlue else colors.onSurfaceVariant,
                modifier = Modifier.size(20.dp)
            )
        }
    }
}

/**
 * 预览页"加入传输队列"按钮：与 [FocusPointButton] 同款玻璃圆钮。
 * 未入队显示 +（蓝），点击把当前页加入队列；已入队显示 ✓（绿）且不可再点——
 * 与列表页格子"已入队不可重复点"语义一致。
 */
@Composable
private fun TransferQueueButton(
    queued: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    Box(
        modifier = modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(colors.glassSurface)
            // 已入队也要消费点击，否则事件穿透到下层 PreviewPage 的 onTap 会关掉预览。
            .pointerInput(queued) {
                detectTapGestures(onTap = { if (!queued) onClick() })
            },
        contentAlignment = Alignment.Center
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Brush.verticalGradient(listOf(colors.glassHighlightTop, colors.glassHighlightBottom)))
                .border(1.dp, Brush.verticalGradient(listOf(colors.glassBorderTop, colors.glassBorderBottom)), CircleShape),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = if (queued) Icons.Default.Check else Icons.Default.Add,
                contentDescription = stringResource(
                    if (queued) R.string.cd_queued else R.string.cd_transfer
                ),
                tint = if (queued) colors.statusConnected else colors.accentBlue,
                modifier = Modifier.size(22.dp)
            )
        }
    }
}

// 手势缩放参数（参考主流相册）：捏合上限 4x，双击在 1x 与 2.5x 间切换。
private const val MAX_ZOOM = 4f
private const val DOUBLE_TAP_ZOOM = 2.5f

@Composable
private fun PreviewPage(
    file: NikonCamera.FileInfo,
    cameraViewModel: CameraViewModel,
    fhdBitmap: ImageBitmap?,
    isLoadingFhd: Boolean,
    exif: PhotoExif?,
    showAfPoint: Boolean,
    isCurrent: Boolean,
    onZoomedChange: (Boolean) -> Unit,
    onTap: () -> Unit
) {
    var thumbnail by remember(file.handle) { mutableStateOf<ImageBitmap?>(null) }
    // 取过仍为 null → 该文件确实没有缩略图（如部分视频）。
    var noThumb by remember(file.handle) { mutableStateOf(false) }
    LaunchedEffect(file.handle) {
        if (thumbnail == null && !noThumb) {
            val t = cameraViewModel.loadThumbnail(file)
            if (t != null) thumbnail = t else noThumb = true
        }
    }

    // FHD 到位后从缩略图平滑过渡（300ms 淡入），视觉上"画面变清晰"（blur-up）。
    val fhdAlpha = remember { Animatable(0f) }
    LaunchedEffect(fhdBitmap) {
        if (fhdBitmap != null) {
            if (thumbnail != null) fhdAlpha.animateTo(1f, tween(300))
            else fhdAlpha.snapTo(1f)
        } else {
            fhdAlpha.snapTo(0f)
        }
    }

    // ---- 缩放/平移状态（按 handle 记忆；离开本页复位，与主流相册一致）----
    var scale by remember(file.handle) { mutableStateOf(1f) }
    var offset by remember(file.handle) { mutableStateOf(Offset.Zero) }
    val scope = rememberCoroutineScope()
    // 双击缩放动画的 Job：新手势/新双击/离页复位前先取消它，避免多方同时写 scale/offset 打架。
    var zoomAnimJob by remember(file.handle) { mutableStateOf<Job?>(null) }
    val zoomed = scale > 1.01f
    LaunchedEffect(isCurrent) { if (!isCurrent) { zoomAnimJob?.cancel(); scale = 1f; offset = Offset.Zero } }
    // 报告当前页是否已放大——预览层据此在放大时禁用翻页（否则横向平移会误翻页）。
    LaunchedEffect(isCurrent, zoomed) { if (isCurrent) onZoomedChange(zoomed) }

    val displayBitmap = fhdBitmap ?: thumbnail
    val imgAspect = displayBitmap?.let { it.width.toFloat() / it.height.toFloat() }
    val isVideo = file.extension in VIDEO_EXTENSIONS

    // 把 offset 钳制在"图片边缘不越过容器边缘"的范围内（防止拖出黑边）。
    fun clampOffset(s: Float, o: Offset, dispW: Float, dispH: Float, cw: Float, ch: Float): Offset {
        val maxX = max(0f, (dispW * s - cw) / 2f)
        val maxY = max(0f, (dispH * s - ch) / 2f)
        return Offset(o.x.coerceIn(-maxX, maxX), o.y.coerceIn(-maxY, maxY))
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            // 捏合缩放 + 放大后单指平移。关键：单指且未放大时【不消费】事件，
            // 把手势让给 HorizontalPager 翻页 / 单击关闭；双指或已放大才接管并消费。
            .pointerInput(imgAspect) {
                // 视频占位页没有可缩放的内容：捏合/平移手势直接不启动，不再空转消费事件。
                if (isVideo || imgAspect == null) return@pointerInput
                val cw = size.width.toFloat(); val ch = size.height.toFloat()
                val containerAspect = cw / ch
                val dispW = if (imgAspect > containerAspect) cw else ch * imgAspect
                val dispH = if (imgAspect > containerAspect) cw / imgAspect else ch
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    zoomAnimJob?.cancel()   // 用户开始触摸即让双击动画让位，交互立即接管
                    do {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.count { it.pressed }
                        if (pressed >= 2 || scale > 1.01f) {
                            val zoomChange = event.calculateZoom()
                            val panChange = event.calculatePan()
                            if (zoomChange != 1f || panChange != Offset.Zero) {
                                val newScale = (scale * zoomChange).coerceIn(1f, MAX_ZOOM)
                                val centroid = event.calculateCentroid(useCurrent = true)
                                // 以捏合中心为不动点：中心到容器心的向量按 (旧-新) 缩放补偿，再叠加平移。
                                val c = Offset(centroid.x - cw / 2f, centroid.y - ch / 2f)
                                offset = clampOffset(newScale, offset + c * (scale - newScale) + panChange, dispW, dispH, cw, ch)
                                scale = newScale
                                event.changes.forEach { if (it.pressed) it.consume() }
                            }
                        }
                    } while (event.changes.any { it.pressed })
                }
            }
            // 单击：未放大时关闭（放大时不关，避免查看时误触）；双击：1x ↔ 2.5x 在点击处切换（带动画）。
            .pointerInput(imgAspect) {
                val cw = size.width.toFloat(); val ch = size.height.toFloat()
                detectTapGestures(
                    onTap = { if (scale <= 1.01f) onTap() },
                    onDoubleTap = { tap ->
                        // 视频占位页不缩放（单击关闭保留在 onTap）。
                        if (isVideo) return@detectTapGestures
                        val a = imgAspect ?: return@detectTapGestures
                        val containerAspect = cw / ch
                        val dispW = if (a > containerAspect) cw else ch * a
                        val dispH = if (a > containerAspect) cw / a else ch
                        val target = if (scale > 1.01f) 1f else DOUBLE_TAP_ZOOM
                        val startS = scale
                        val startO = offset
                        val targetO = if (target == 1f) Offset.Zero
                        else clampOffset(target, Offset(tap.x - cw / 2f, tap.y - ch / 2f) * (1f - target), dispW, dispH, cw, ch)
                        zoomAnimJob?.cancel()   // 二次双击前取消上一个动画，避免两个 tween 同帧抢写
                        zoomAnimJob = scope.launch {
                            Animatable(0f).animateTo(1f, tween(240)) {
                                scale = startS + (target - startS) * value
                                offset = androidx.compose.ui.geometry.lerp(startO, targetO, value)
                            }
                        }
                    }
                )
            },
        contentAlignment = Alignment.Center
    ) {
        val thumb = thumbnail  // 本地变量，delegate 属性无法被编译器 smart cast
        val anyLoading = isLoadingFhd || (!noThumb && thumbnail == null)
        when {
            isVideo -> {
                // 视频无高清封面：缩略图压暗当背景 + 居中毛玻璃占位，明确"这是视频、暂不支持预览"，
                // 而非把糊掉的小缩略图硬撑满屏当"预览"。
                if (thumb != null) {
                    Image(
                        bitmap = thumb,
                        contentDescription = null,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.fillMaxSize()
                    )
                }
                Box(modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.5f)))
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Surface(
                        shape = CircleShape,
                        color = Color.Black.copy(alpha = 0.45f),
                        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.22f))
                    ) {
                        Icon(
                            Icons.Default.Movie,
                            contentDescription = null,
                            tint = Color.White.copy(alpha = 0.9f),
                            modifier = Modifier
                                .padding(18.dp)
                                .size(34.dp)
                        )
                    }
                    Spacer(Modifier.height(14.dp))
                    Surface(
                        shape = RoundedCornerShape(18.dp),
                        color = Color.Black.copy(alpha = 0.45f),
                        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.22f))
                    ) {
                        Text(
                            stringResource(R.string.video_no_preview),
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.Medium,
                            color = Color.White,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                        )
                    }
                }
            }
            displayBitmap != null -> {
                // 图像栈（缩略图淡出 + FHD 淡入）统一套用缩放/平移变换。
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .graphicsLayer {
                            scaleX = scale; scaleY = scale
                            translationX = offset.x; translationY = offset.y
                        }
                ) {
                    if (fhdBitmap != null && thumb != null && fhdAlpha.value < 1f) {
                        Image(
                            bitmap = thumb,
                            contentDescription = null,
                            contentScale = ContentScale.Fit,
                            modifier = Modifier.fillMaxSize(),
                            alpha = 1f - fhdAlpha.value
                        )
                    }
                    Image(
                        bitmap = displayBitmap,
                        contentDescription = file.fileName,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.fillMaxSize(),
                        alpha = if (fhdBitmap != null) fhdAlpha.value else 1f
                    )

                    // 对焦点红框叠加（按住 AF 按钮时绘制）。放在同一变换层内,随缩放/平移跟着图走。
                    // afX/afY 是 AF 区【中心】（Nikon AFInfo2 语义,解析端即按中心归一化）,矩形以其为中心;
                    // 线宽除以 scale,放大后红框变大但线保持 1dp 视觉粗细（draw 块读 scale,变焦时自动重绘）。
                    val exifNonNull = exif
                    if (showAfPoint && exifNonNull != null && exifNonNull.afX != null) {
                        Canvas(modifier = Modifier.fillMaxSize()) {
                            // Fit 矩形必须按【实际渲染位图】的宽高比算,与 Image 的 ContentScale.Fit
                            // 严格一致;EXIF 原图尺寸与预览位图比例可能有出入(缩略图黑边裁切后
                            // 已非精确 3:2、FHD 直出比例也未必等于原图),按 EXIF 算红框会贴不住画面。
                            val imgAsp = displayBitmap.width.toFloat() / displayBitmap.height.toFloat()
                            val containerAspect = size.width / size.height
                            val (dispW, dispH) = if (imgAsp > containerAspect) {
                                size.width to (size.width / imgAsp)
                            } else {
                                (size.height * imgAsp) to size.height
                            }
                            val afCx = (size.width - dispW) / 2f + exifNonNull.afX * dispW
                            val afCy = (size.height - dispH) / 2f + exifNonNull.afY!! * dispH
                            val afW = (exifNonNull.afWidth ?: 0.05f) * dispW
                            val afH = (exifNonNull.afHeight ?: 0.05f) * dispH
                            drawRect(
                                color = Color.Red,
                                topLeft = Offset(afCx - afW / 2f, afCy - afH / 2f),
                                size = Size(afW, afH),
                                style = Stroke(width = 1.dp.toPx() / scale)
                            )
                        }
                    }
                }
            }
            anyLoading -> CircularProgressIndicator(color = AccentBlue, modifier = Modifier.size(32.dp))
            noThumb -> Text(stringResource(R.string.no_preview), color = DarkOnSurfaceVariant)
            else -> CircularProgressIndicator(color = AccentBlue, modifier = Modifier.size(32.dp))
        }
    }
}
