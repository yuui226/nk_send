package com.ztransfer.ui.screen

import androidx.activity.compose.BackHandler
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
import androidx.compose.material.icons.filled.BurstMode
import androidx.compose.material.icons.filled.FilterCenterFocus
import androidx.compose.material.icons.filled.Key
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
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.sp
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

    val haptics = rememberHaptics(hapticsEnabled)

    // 预览期间暂停后台缩略图填充，把 ioMutex 让给 FHD/EXIF 取图。
    DisposableEffect(Unit) {
        cameraViewModel.setFhdActive(true)
        onDispose { cameraViewModel.setFhdActive(false) }
    }

    // 加载单页 FHD；返回 true 表示"本次确实取到并解码成功"（用于当前页到位的触感反馈）。
    suspend fun loadFhdPage(page: Int): Boolean {
        val file = files.getOrNull(page) ?: return false
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
    LaunchedEffect(pagerState.currentPage) {
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
                .background(Color.Black.copy(alpha = 0.94f))
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
                    Surface(
                        shape = RoundedCornerShape(7.dp),
                        color = Color.Black.copy(alpha = 0.45f),
                        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.22f))
                    ) {
                        Icon(
                            Icons.Default.Key,
                            contentDescription = stringResource(R.string.filter_protected),
                            tint = Color.White.copy(alpha = 0.9f),
                            modifier = Modifier
                                .padding(4.dp)
                                .size(12.dp)
                        )
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
        val curExif = files.getOrNull(pagerState.currentPage)?.let { exifData[it.handle] }
        val hasExif = curExif != null && (curExif.aperture != null || curExif.shutterSpeed != null
            || curExif.iso != null || curExif.focalLength != null)
        val hasAf = curExif?.afX != null
        if (hasExif || hasAf) {
            Row(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(horizontal = 16.dp, vertical = 24.dp)
                    .graphicsLayer { alpha = progress.value },
                verticalAlignment = Alignment.CenterVertically
            ) {
                if (hasExif) {
                    ExifMetadataBar(
                        exif = curExif!!,
                        alpha = 1f,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                }
                if (hasAf) {
                    Spacer(modifier = Modifier.width(12.dp))
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
 * 底部毛玻璃参数条：光圈 / 快门 / ISO / 焦距，间距 18dp。
 * [alpha] 跟随 overlay 展开动画的 [progress] 值。
 */
@Composable
private fun ExifMetadataBar(
    exif: PhotoExif,
    alpha: Float,
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

    // 容器 pixel 尺寸，用于 AF 点叠加的 Fit 坐标映射。
    var containerSize by remember { mutableStateOf<IntSize?>(null) }

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

    // 把 offset 钳制在"图片边缘不越过容器边缘"的范围内（防止拖出黑边）。
    fun clampOffset(s: Float, o: Offset, dispW: Float, dispH: Float, cw: Float, ch: Float): Offset {
        val maxX = max(0f, (dispW * s - cw) / 2f)
        val maxY = max(0f, (dispH * s - ch) / 2f)
        return Offset(o.x.coerceIn(-maxX, maxX), o.y.coerceIn(-maxY, maxY))
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .onGloballyPositioned { containerSize = it.size }
            // 捏合缩放 + 放大后单指平移。关键：单指且未放大时【不消费】事件，
            // 把手势让给 HorizontalPager 翻页 / 单击关闭；双指或已放大才接管并消费。
            .pointerInput(imgAspect) {
                if (imgAspect == null) return@pointerInput
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
                }

                // 对焦点红框叠加（按住 AF 按钮时绘制；不随缩放变换，与放大同用是罕见组合）。
                val exifNonNull = exif
                if (showAfPoint && exifNonNull != null && exifNonNull.afX != null && containerSize != null) {
                    val density = LocalDensity.current
                    val cw = containerSize!!.width.toFloat()
                    val ch = containerSize!!.height.toFloat()
                    val imgW = exifNonNull.imageWidth?.toFloat() ?: displayBitmap.width.toFloat()
                    val imgH = exifNonNull.imageHeight?.toFloat() ?: displayBitmap.height.toFloat()
                    val imgAsp = imgW / imgH
                    val containerAspect = cw / ch
                    val (dispW, dispH) = if (imgAsp > containerAspect) {
                        cw to (cw / imgAsp)
                    } else {
                        (ch * imgAsp) to ch
                    }
                    val offX = (cw - dispW) / 2f
                    val offY = (ch - dispH) / 2f
                    val strokePx = with(density) { 2.dp.toPx() }

                    Canvas(modifier = Modifier.fillMaxSize()) {
                        val afLeft = offX + exifNonNull.afX * dispW
                        val afTop = offY + exifNonNull.afY!! * dispH
                        val afW = (exifNonNull.afWidth ?: 0.05f) * dispW
                        val afH = (exifNonNull.afHeight ?: 0.05f) * dispH
                        drawRect(
                            color = Color.Red,
                            topLeft = Offset(afLeft, afTop),
                            size = Size(afW, afH),
                            style = Stroke(width = strokePx)
                        )
                    }
                }
            }
            anyLoading -> CircularProgressIndicator(color = AccentBlue, modifier = Modifier.size(32.dp))
            noThumb -> Text(stringResource(R.string.no_preview), color = DarkOnSurfaceVariant)
            else -> CircularProgressIndicator(color = AccentBlue, modifier = Modifier.size(32.dp))
        }
    }
}
