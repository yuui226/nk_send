package com.ztransfer.ui.screen

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
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
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.RotateLeft
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.IntSize
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
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

/** 预览分页模型与列表展示模型同构：合集是独立页面，不伪装成其中某张照片。 */
internal sealed interface PhotoPreviewItem {
    val key: Any

    data class Photo(
        val file: NikonCamera.FileInfo,
        val burstId: String? = null
    ) : PhotoPreviewItem {
        override val key: Any = file.handle
    }

    data class BurstCollection(
        val id: String,
        val files: List<NikonCamera.FileInfo>
    ) : PhotoPreviewItem {
        override val key: Any = "preview_burst_$id"
    }
}

internal fun isPreviewBurstExpanded(
    items: List<PhotoPreviewItem>,
    collectionPage: Int,
    burstId: String
): Boolean =
    (items.getOrNull(collectionPage + 1) as? PhotoPreviewItem.Photo)?.burstId == burstId

internal fun expandPreviewBurst(
    items: List<PhotoPreviewItem>,
    collectionPage: Int,
    collection: PhotoPreviewItem.BurstCollection
): List<PhotoPreviewItem> {
    if (isPreviewBurstExpanded(items, collectionPage, collection.id)) return items
    val members = collection.files.map { file ->
        PhotoPreviewItem.Photo(file = file, burstId = collection.id)
    }
    return buildList(items.size + members.size) {
        addAll(items.take(collectionPage + 1))
        addAll(members)
        addAll(items.drop(collectionPage + 1))
    }
}

internal fun collapsePreviewBurst(
    items: List<PhotoPreviewItem>,
    burstId: String
): List<PhotoPreviewItem> =
    items.filterNot { it is PhotoPreviewItem.Photo && it.burstId == burstId }

/**
 * 全屏预览层：普通页显示缓存缩略图的**未裁切**（Fit）完整画面；折叠连拍在分页中
 * 保持为一个合集页，只有用户主动展开才把成员插入其后。
 * 整体从被长按格子 [anchorRect] 的位置缩放展开，关闭时反向缩回（从哪来回哪去）。
 * 不下载原图（缩略图低清但瞬开、不抢传输通道）。
 * 本层在深浅两种主题下都保持黑底沉浸式（照片查看器惯例，黑底最衬照片），
 * 因此内部直接用深色常量而非主题 token——这是有意的，不参与深浅切换。
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun PhotoPreviewOverlay(
    items: List<PhotoPreviewItem>,
    initialIndex: Int,
    anchorRect: Rect?,
    cameraViewModel: CameraViewModel,
    hapticsEnabled: Boolean,
    // 全局持久化方向：0..3 个逆时针 90°。只用作本次 overlay 初始值；
    // overlay 内部保留不取模的连续角度，保证 270°→0° 时仍是向左短转 90°。
    initialRotationQuarterTurns: Int = 0,
    // 连拍成员 handle 集(列表页的检测结果):预览左上角展示连拍角标用;空集即不展示。
    burstHandles: Set<Int> = emptySet(),
    // 把当前预览文件加入传输队列（父层负责目录校验、连接状态、入队与吸入动画）。
    onTransfer: (NikonCamera.FileInfo) -> Unit = {},
    // 合集页整组入队；预览没有列表格子锚点，因此只执行入队，不播放错误起点的飞行动画。
    onTransferBurst: (List<NikonCamera.FileInfo>) -> Unit = {},
    // 预览内主动展开/收起合集时同步底层列表，关闭预览后两处状态一致。
    onBurstExpandedChange: (String, Boolean) -> Unit = { _, _ -> },
    // 每次旋转后回传归一化方向，父层写入全局偏好。
    onRotationChanged: (Int) -> Unit = {},
    onDismiss: () -> Unit
) {
    // 会话内固定持有自己的分页快照；后台增量加载/筛选不会让正在看的页突然换内容。
    // 只有用户在合集页主动展开/收起时，才在当前页后插入/移除该组成员。
    var previewItems by remember { mutableStateOf(items) }
    val pagerState = rememberPagerState(initialPage = initialIndex) { previewItems.size }
    val previewScope = rememberCoroutineScope()
    val cameraState by cameraViewModel.state.collectAsState()
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
    // 状态图按 handle 存储；handle 仅在本 overlay 存活期有效（关闭随 Composable 释放）。
    val fhdBitmaps = remember { mutableStateMapOf<Int, ImageBitmap>() }
    val fhdLoading = remember { mutableStateMapOf<Int, Boolean>() }
    val exifData = remember { mutableStateMapOf<Int, PhotoExif?>() }
    val exifLoading = remember { mutableStateMapOf<Int, Boolean>() }
    // 初始方向来自全局偏好；本 overlay 内不取模，每次继续减 90°，
    // 动画始终沿逆时针最短方向旋转。翻页不重置，所有照片共用。
    var rotationDegrees by remember {
        mutableFloatStateOf(-90f * Math.floorMod(initialRotationQuarterTurns, 4))
    }
    val currentItem = previewItems.getOrNull(pagerState.currentPage)
    val currentFile = (currentItem as? PhotoPreviewItem.Photo)?.file
    val currentHandle = currentFile?.handle

    val haptics = rememberHaptics(hapticsEnabled)

    fun collectionExpandedAt(page: Int, id: String): Boolean =
        isPreviewBurstExpanded(previewItems, page, id)

    val togglePreviewBurst: (PhotoPreviewItem.BurstCollection) -> Unit = { collection ->
        val page = pagerState.currentPage
        val expanded = collectionExpandedAt(page, collection.id)
        haptics.tick()
        if (expanded) {
            // 只可能从合集页触发收起；当前页不变，安全移除其后的成员。
            previewItems = collapsePreviewBurst(previewItems, collection.id)
            onBurstExpandedChange(collection.id, false)
        } else {
            previewItems = expandPreviewBurst(previewItems, page, collection)
            onBurstExpandedChange(collection.id, true)
            // 插入完成后一帧平滑进入第一张；合集页仍保留在左侧，用户可滑回并收起。
            previewScope.launch {
                withFrameNanos { }
                pagerState.animateScrollToPage(page + 1)
            }
        }
    }

    // 预览期间暂停后台缩略图填充，把 ioMutex 让给 FHD/EXIF 取图。
    DisposableEffect(Unit) {
        cameraViewModel.setFhdActive(true)
        onDispose { cameraViewModel.setFhdActive(false) }
    }

    // 加载单页 FHD；返回 true 表示"本次确实取到并解码成功"（用于当前页到位的触感反馈）。
    suspend fun loadFhdPage(page: Int, awaitExisting: Boolean = false): Boolean {
        val file = (previewItems.getOrNull(page) as? PhotoPreviewItem.Photo)?.file
            ?: return false
        // 视频没有高清封面（FHD 操作码只对照片有效），不发注定失败的请求、也不显示加载条。
        if (file.extension in VIDEO_EXTENSIONS) return false
        val h = file.handle
        if (h in fhdBitmaps) return false
        if (fhdLoading.containsKey(h)) {
            if (!awaitExisting) return false
            // 当前页可能正由上一页的预取任务加载。等待它完成；若它因翻页被取消，
            // loading 会在 finally 中释放，随后由当前页重新发起，绝不漏载。
            while (fhdLoading.containsKey(h) && h !in fhdBitmaps) delay(16)
            if (h in fhdBitmaps) return false
        }
        fhdLoading[h] = true
        try {
            val res = cameraViewModel.loadFhdPreview(file) ?: return false
            fhdBitmaps[h] = res
            return true
        } finally {
            fhdLoading.remove(h)
        }
    }

    // 加载单页 EXIF（仅当前页，不预加载邻居——EXIF 只在当前页底栏显示，预加载纯浪费通道）。
    suspend fun loadExifPage(page: Int) {
        val file = (previewItems.getOrNull(page) as? PhotoPreviewItem.Photo)?.file
            ?: return
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
    LaunchedEffect(previewItems, pagerState.currentPage, currentHandle) {
        val cp = pagerState.currentPage
        val keep = (cp - 2).coerceAtLeast(0)..(cp + 2).coerceAtMost(previewItems.lastIndex)
        val keepH = keep.mapNotNull { page ->
            (previewItems.getOrNull(page) as? PhotoPreviewItem.Photo)?.file?.handle
        }.toSet()
        fhdBitmaps.keys.filter { it !in keepH }.forEach { fhdBitmaps.remove(it) }
        exifData.keys.filter { it !in keepH }.forEach { exifData.remove(it) }
    }

    // 当前页拥有最高优先级。连接状态纳入 key：停留在预览页断线后原地重连，
    // 即使页码没变也会重新请求 FHD，而不是一直停留在缩略图。
    // 当前页与邻页由同一协程严格串行，避免首次失败时两个 effect 重复请求并触发熔断。
    LaunchedEffect(
        previewItems,
        pagerState.currentPage,
        currentHandle,
        cameraState.isConnectedToCamera
    ) {
        if (!cameraState.isConnectedToCamera) return@LaunchedEffect
        val cp = pagerState.currentPage
        if (loadFhdPage(cp, awaitExisting = true)) haptics.tick()
        loadExifPage(cp)
        if (cp > 0) loadFhdPage(cp - 1)
        if (cp < previewItems.lastIndex) loadFhdPage(cp + 1)
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
                .background(Color.Black.copy(alpha = 0.74f))
        )

        // 当前页是否已放大——放大时禁用翻页，横向平移才不会误翻到下一张。
        var currentZoomed by remember { mutableStateOf(false) }

        // 图片翻页器：整体从被长按格子的位置缩放展开。相邻页预载一页，快速翻页不用等图。
        HorizontalPager(
            state = pagerState,
            beyondViewportPageCount = 1,
            key = { page -> previewItems[page].key },
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
                        // 打开首帧就绘制已缓存的源缩略图，避免 overlay 已挂载但动画尚未
                        // 前进时整块图片透明、短暂透出照片列表。关闭时仍随缩回过程淡出，
                        // 与底层原格子自然交接。
                        alpha = if (closing) {
                            (progress.value * 1.6f).coerceAtMost(1f)
                        } else {
                            1f
                        }
                    } else {
                        scaleX = 1f
                        scaleY = 1f
                        alpha = progress.value
                    }
                }
        ) { page ->
            when (val item = previewItems[page]) {
                is PhotoPreviewItem.Photo -> {
                    val file = item.file
                    PreviewPage(
                        file = file,
                        cameraViewModel = cameraViewModel,
                        fhdBitmap = fhdBitmaps[file.handle],
                        isLoadingFhd = fhdLoading.containsKey(file.handle),
                        rotationDegrees = rotationDegrees,
                        isCurrent = page == pagerState.currentPage,
                        onZoomedChange = { currentZoomed = it },
                        onTap = startClose
                    )
                }
                is PhotoPreviewItem.BurstCollection -> {
                    BurstCollectionPreviewPage(
                        collection = item,
                        cameraViewModel = cameraViewModel,
                        isCurrent = page == pagerState.currentPage,
                        onZoomedChange = { currentZoomed = it },
                        onTap = startClose
                    )
                }
            }
        }

        // 顶部：普通照片显示序号 + 文件名；合集只保留序号，视觉信息由共用角标承担。
        if (currentItem != null) {
            val pageNumber = "${pagerState.currentPage + 1}/${previewItems.size}"
            val title = (currentItem as? PhotoPreviewItem.Photo)?.file?.fileName
            Text(
                text = title?.let { "$pageNumber  ·  $it" } ?: pageNumber,
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
        if (currentFile != null &&
            (currentFile.handle in burstHandles || currentFile.isProtected)
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .statusBarsPadding()
                    .padding(top = 36.dp, start = 12.dp)
                    .graphicsLayer { alpha = progress.value }
            ) {
                if (currentFile.handle in burstHandles) {
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
                if (currentFile.isProtected) {
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
        val curLoadingFhd = currentFile?.let { fhdLoading.containsKey(it.handle) } == true
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

        // ---- 底部栏：当前真实照片的 EXIF 参数 ----
        // 跟手淡入淡出：alpha 由翻页滚动进度实时驱动——离开当前页时随手指滑动淡出、
        // 新页吸附到位时淡入，不等翻完。内容在滑过半（currentPage 翻转、此刻 alpha≈0
        // 看不见）时直接切换，因此不会保留上一页参数的退场副本。
        // alpha 计算写在 graphicsLayer 内读滚动值：每帧只重绘图层，不触发子树重组。
        // 新页 EXIF 异步到达后再独立淡入；合集页直接移除整棵参数子树。
        currentFile?.let { file ->
            val curExif = exifData[file.handle]
            val displayExif = curExif?.takeIf {
                it.aperture != null || it.shutterSpeed != null ||
                    it.iso != null || it.focalLength != null
            }
            val loadedAlpha by animateFloatAsState(
                targetValue = if (displayExif != null) 1f else 0f,
                animationSpec = tween(180, easing = FastOutSlowInEasing),
                label = "exifLoaded"
            )
            if (displayExif != null) {
                Row(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .navigationBarsPadding()
                        .padding(horizontal = 16.dp)
                        .heightIn(min = 44.dp)
                        .padding(vertical = 24.dp)
                        .graphicsLayer {
                            val swipe =
                                (1f - abs(pagerState.currentPageOffsetFraction) * 2f)
                                    .coerceIn(0f, 1f)
                            alpha = progress.value * swipe * loadedAlpha
                        },
                    verticalAlignment = Alignment.Bottom
                ) {
                    ExifMetadataBar(
                        exif = displayExif,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                }
            }
        }

        // 普通照片沿用右下旋转/入队；合集页改为底部左右双按钮，与列表卡的
        // “左下 + / 右下 >”完全同语义。合集展开后自动进入第一张成员。
        when (val item = currentItem) {
            is PhotoPreviewItem.Photo -> {
                val current = item.file
                Column(
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .navigationBarsPadding()
                        .padding(end = 20.dp, bottom = 80.dp)
                        .graphicsLayer { alpha = progress.value },
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    if (current.extension !in VIDEO_EXTENSIONS) {
                        RotationButton(onClick = {
                            val nextDegrees = rotationDegrees - 90f
                            rotationDegrees = nextDegrees
                            // 从连续角度换算持久化方向；快速连点也不依赖父层重组时机。
                            val nextTurns = Math.floorMod((-nextDegrees / 90f).toInt(), 4)
                            onRotationChanged(nextTurns)
                        })
                    }
                    TransferQueueButton(
                        onClick = { onTransfer(current) }
                    )
                }
            }
            is PhotoPreviewItem.BurstCollection -> {
                val expanded = collectionExpandedAt(pagerState.currentPage, item.id)
                Row(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .navigationBarsPadding()
                        .padding(bottom = 112.dp)
                        .graphicsLayer { alpha = progress.value },
                    horizontalArrangement = Arrangement.spacedBy(22.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    TransferQueueButton(
                        onClick = { onTransferBurst(item.files) },
                        buttonSize = 48.dp
                    )
                    BurstPreviewToggleButton(
                        expanded = expanded,
                        onClick = { togglePreviewBurst(item) }
                    )
                }
            }
            null -> Unit
        }
    }
}

@Composable
private fun BurstCollectionPreviewPage(
    collection: PhotoPreviewItem.BurstCollection,
    cameraViewModel: CameraViewModel,
    isCurrent: Boolean,
    onZoomedChange: (Boolean) -> Unit,
    onTap: () -> Unit
) {
    val a11y = stringResource(R.string.burst_collection_a11y, collection.files.size)
    LaunchedEffect(isCurrent) {
        if (isCurrent) onZoomedChange(false)
    }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .semantics { contentDescription = a11y }
            .pointerInput(collection.id) {
                detectTapGestures(onTap = { onTap() })
            },
        contentAlignment = Alignment.Center
    ) {
        val stackSize = minOf(maxWidth * 0.72f, maxHeight * 0.46f, 360.dp)
        Box(modifier = Modifier.size(stackSize)) {
            val stackFiles = collection.files.take(3).reversed()
            val stackInset = stackSize * 0.07f + 6.dp
            stackFiles.forEachIndexed { index, file ->
                val last = stackFiles.lastIndex
                val rotation = when (stackFiles.size) {
                    1 -> 0f
                    2 -> if (index == 0) -5f else 3f
                    else -> when (index) {
                        0 -> -6f
                        1 -> 5f
                        else -> 0f
                    }
                }
                val x = when {
                    index == last -> 0.dp
                    index % 2 == 0 -> (-12).dp
                    else -> 12.dp
                }
                BurstStackPhoto(
                    file = file,
                    cameraViewModel = cameraViewModel,
                    transfersBusy = false,
                    showPlaceholderIcon = index == last,
                    modifier = Modifier
                        .fillMaxSize(0.86f)
                        .align(Alignment.Center)
                        .offset(x = x, y = if (index == last) 2.dp else 5.dp)
                        .graphicsLayer { rotationZ = rotation }
                )
            }

            BurstCollectionBadge(
                count = collection.files.size,
                iconSize = 16.dp,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .offset(x = stackInset, y = stackInset)
            )
        }
    }
}

@Composable
private fun RotationButton(onClick: () -> Unit) {
    val colors = AppTheme.colors
    GlassButton(
        onClick = onClick,
        modifier = Modifier.size(44.dp),
        shape = CircleShape,
        contentPadding = PaddingValues(11.dp)
    ) {
        Icon(Icons.Default.RotateLeft, stringResource(R.string.cd_rotate_photo),
            tint = colors.accentBlue, modifier = Modifier.size(22.dp))
    }
}

@Composable
private fun BurstPreviewToggleButton(
    expanded: Boolean,
    onClick: () -> Unit
) {
    val colors = AppTheme.colors
    val rotation by animateFloatAsState(
        targetValue = if (expanded) 180f else 0f,
        animationSpec = tween(240, easing = FastOutSlowInEasing),
        label = "previewBurstChevron"
    )
    GlassButton(
        onClick = onClick,
        modifier = Modifier.size(48.dp),
        shape = CircleShape,
        contentPadding = PaddingValues(0.dp)
    ) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Icon(
                Icons.Default.ChevronRight,
                contentDescription = stringResource(
                    if (expanded) R.string.cd_collapse else R.string.cd_expand
                ),
                tint = colors.accentBlue,
                modifier = Modifier
                    .size(25.dp)
                    .graphicsLayer { rotationZ = rotation }
            )
        }
    }
}

/**
 * 底部毛玻璃参数条：光圈 / 快门 / ISO / 焦距。
 * 淡入淡出由外层（overlay 展开进度 × 翻页跟手 × 加载完成度）统一驱动，本身不管透明度。
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
 * 预览页"加入传输队列"按钮：使用全局统一的玻璃圆钮。
 * 始终允许再次加入；任务执行时检查原片与当前任务对应的边框文件是否存在。
 */
@Composable
private fun TransferQueueButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    buttonSize: Dp = 44.dp
) {
    val colors = AppTheme.colors
    GlassButton(
        onClick = onClick,
        modifier = modifier.size(buttonSize),
        shape = CircleShape,
        contentPadding = PaddingValues(0.dp)
    ) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = Icons.Default.Add,
                contentDescription = stringResource(R.string.cd_transfer),
                tint = colors.accentBlue,
                modifier = Modifier.size(buttonSize * 0.5f)
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
    rotationDegrees: Float,
    isCurrent: Boolean,
    onZoomedChange: (Boolean) -> Unit,
    onTap: () -> Unit
) {
    val animatedRotation by animateFloatAsState(
        targetValue = rotationDegrees,
        animationSpec = tween(220),
        label = "previewRotation"
    )
    // 预览通常由一个已经显示缩略图的可见格子打开。同步复用同一份内存缓存，确保
    // overlay 第一帧就有画面；缓存未命中时才异步走磁盘/相机兜底。
    var thumbnail by remember(file.handle) {
        mutableStateOf(cameraViewModel.cachedThumbnail(file.handle))
    }
    // 取过仍为 null → 该文件确实没有缩略图（如部分视频）。
    var noThumb by remember(file.handle) { mutableStateOf(false) }
    LaunchedEffect(file.handle) {
        if (thumbnail == null && !noThumb) {
            val t = cameraViewModel.loadThumbnail(file)
            if (t != null) thumbnail = t else noThumb = true
        }
    }

    // FHD 到位后覆盖在缩略图上淡入。缩略图在过渡完成前始终保持不透明，避免两张图
    // 的有效画面边界略有差异时交叉淡出露出背景，视觉上只发生一次连续的“变清晰”。
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
    val quarterTurn = ((rotationDegrees / 90f).roundToInt() % 2) != 0
    val rawAspect = displayBitmap?.let { it.width.toFloat() / it.height.toFloat() }
    val imgAspect = displayBitmap?.let {
        if (quarterTurn) 1f / rawAspect!! else rawAspect!!
    }
    // Image(Fit) 先按未旋转方向排版；动画期间根据每一帧角度的外接矩形动态缩放，
    // 避免角度与缩放各自线性插值造成中途裁切、忽大忽小。
    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    val viewportW = viewportSize.width.toFloat()
    val viewportH = viewportSize.height.toFloat()
    val baseImageW: Float
    val baseImageH: Float
    if (rawAspect != null && viewportW > 0f && viewportH > 0f) {
        val viewportAspect = viewportW / viewportH
        baseImageW = if (rawAspect > viewportAspect) viewportW else viewportH * rawAspect
        baseImageH = if (rawAspect > viewportAspect) viewportW / rawAspect else viewportH
    } else {
        baseImageW = 0f
        baseImageH = 0f
    }
    val isVideo = file.extension in VIDEO_EXTENSIONS

    // 旋转会改变基础 Fit 尺寸；清掉此前的用户缩放/偏移，避免旧坐标把旋转后的图推离屏幕。
    LaunchedEffect(rotationDegrees) {
        zoomAnimJob?.cancel()
        scale = 1f
        offset = Offset.Zero
    }

    // 把 offset 钳制在"图片边缘不越过容器边缘"的范围内（防止拖出黑边）。
    fun clampOffset(s: Float, o: Offset, dispW: Float, dispH: Float, cw: Float, ch: Float): Offset {
        val maxX = max(0f, (dispW * s - cw) / 2f)
        val maxY = max(0f, (dispH * s - ch) / 2f)
        return Offset(o.x.coerceIn(-maxX, maxX), o.y.coerceIn(-maxY, maxY))
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .onSizeChanged { viewportSize = it }
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
        // 若 FHD 比缩略图先到，直接显示 FHD；不能等待 LaunchedEffect 下一帧再 snap，
        // 否则仍会产生一帧全透明图片区。
        val effectiveFhdAlpha = if (thumb == null) 1f else fhdAlpha.value
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
                            val angle = Math.toRadians(animatedRotation.toDouble())
                            val absCos = abs(cos(angle)).toFloat()
                            val absSin = abs(sin(angle)).toFloat()
                            val boundsW = baseImageW * absCos + baseImageH * absSin
                            val boundsH = baseImageW * absSin + baseImageH * absCos
                            val rotationFit = if (boundsW > 0f && boundsH > 0f) {
                                min(viewportW / boundsW, viewportH / boundsH)
                            } else 1f
                            // 常见横图旋成竖向时保留约 4%/侧的呼吸空间；随角度连续变化，
                            // 回到横向时自然恢复满幅，不在 90° 端点突然缩一下。
                            val portraitBreathingRoom = if ((rawAspect ?: 0f) > 1f) {
                                1f - 0.08f * absSin
                            } else 1f
                            scaleX = scale * rotationFit * portraitBreathingRoom
                            scaleY = scale * rotationFit * portraitBreathingRoom
                            translationX = offset.x; translationY = offset.y
                            rotationZ = animatedRotation
                        }
                ) {
                    if (thumb != null && (fhdBitmap == null || effectiveFhdAlpha < 1f)) {
                        Image(
                            bitmap = thumb,
                            contentDescription = file.fileName.takeIf { fhdBitmap == null },
                            contentScale = ContentScale.Fit,
                            modifier = Modifier.fillMaxSize()
                        )
                    }
                    if (fhdBitmap != null) {
                        Image(
                            bitmap = fhdBitmap,
                            contentDescription = file.fileName,
                            contentScale = ContentScale.Fit,
                            modifier = Modifier.fillMaxSize(),
                            alpha = effectiveFhdAlpha
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
