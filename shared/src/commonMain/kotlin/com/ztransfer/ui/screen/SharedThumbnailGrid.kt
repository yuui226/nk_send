@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.*
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.*
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.*
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.theme.*
import com.ztransfer.viewmodel.ActiveTransferProgress
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

data class FileGroup(
    val date: String,
    val files: List<CameraFileInfo>
)

fun burstCollectionGridKey(id: String): String = "burst_collection_$id"

/** 一段真实连拍。它只描述检测结果；是否折成虚拟卡位由列表设置决定。 */
data class BurstPhotoGroup(
    val id: String,
    val files: List<CameraFileInfo>
)

/** LazyGrid 的展示层条目；合集卡不是相机文件，使用独立类型避免混入照片语义。 */
sealed interface ThumbnailGridItem {
    val key: Any

    data class Photo(
        val file: CameraFileInfo,
        val burstId: String? = null
    ) : ThumbnailGridItem {
        override val key: Any = file.handle
    }

    data class BurstCollection(
        val id: String,
        val files: List<CameraFileInfo>
    ) : ThumbnailGridItem {
        override val key: Any = burstCollectionGridKey(id)
    }
}

val ThumbnailGridItem.reuseContentType: String
    get() = when (this) {
        is ThumbnailGridItem.Photo -> "photo"
        is ThumbnailGridItem.BurstCollection -> "burst_collection"
    }

fun buildThumbnailGridItems(
    files: List<CameraFileInfo>,
    burstIdByHandle: Map<Int, String>,
    collapseBurstPhotos: Boolean,
    expandedBurstIds: Set<String>
): List<ThumbnailGridItem> {
    if (!collapseBurstPhotos || burstIdByHandle.isEmpty()) {
        return files.map { file ->
            ThumbnailGridItem.Photo(file, burstId = burstIdByHandle[file.handle])
        }
    }

    // 先按当前筛选后的日期组收集成员。筛选可能令原本 ≥3 张的连拍只剩 1 张；
    // 单张不再画“合集”，避免用户为看一张照片还要多点一次。
    val visibleBursts = files
        .mapNotNull { file -> burstIdByHandle[file.handle]?.let { it to file } }
        .groupBy({ it.first }, { it.second })
    val collected = HashSet<String>()
    val result = ArrayList<ThumbnailGridItem>(files.size)

    files.forEach { file ->
        val burstId = burstIdByHandle[file.handle]
        val members = burstId?.let(visibleBursts::get)
        if (burstId == null || members == null || members.size < 2) {
            result += ThumbnailGridItem.Photo(file, burstId = burstId)
        } else if (collected.add(burstId)) {
            result += ThumbnailGridItem.BurstCollection(burstId, members)
            if (burstId in expandedBurstIds) {
                members.forEach { member ->
                    result += ThumbnailGridItem.Photo(
                        file = member,
                        burstId = burstId
                    )
                }
            }
        }
    }
    return result
}

/** Keeps an expanded burst expanded when camera-side deletion changes its derived collection id. */
fun reconciledExpandedBurstIds(
    previousGroups: List<BurstPhotoGroup>,
    currentGroups: List<BurstPhotoGroup>,
    expandedIds: Set<String>,
): Set<String> {
    if (expandedIds.isEmpty() || currentGroups.isEmpty()) return emptySet()
    val currentIds = currentGroups.mapTo(HashSet(currentGroups.size)) { it.id }
    val reconciled = expandedIds
        .filterTo(LinkedHashSet()) { it in currentIds }
    if (previousGroups == currentGroups) return reconciled
    val previouslyExpandedGroups = previousGroups.filter { it.id in expandedIds }
    if (previouslyExpandedGroups.isEmpty()) return reconciled

    val successorIdsByFile = HashMap<PublishedCameraFileIdentity, MutableSet<String>>()
    currentGroups.forEach { group ->
        group.files.forEach { file ->
            successorIdsByFile
                .getOrPut(file.publishedIdentity()) { LinkedHashSet(1) }
                .add(group.id)
        }
    }
    previouslyExpandedGroups.asSequence()
        .flatMap { it.files.asSequence() }
        .mapNotNull { successorIdsByFile[it.publishedIdentity()] }
        .forEach(reconciled::addAll)
    return reconciled
}

/** 缩略图只借用材质色相，不复制按钮纹理、投影或高光。 */
fun thumbnailThemeBorderColor(skin: SkinPreset, dark: Boolean): Color = when (skin) {
    SkinPreset.FROSTED_GLASS -> if (dark) {
        Color.White.copy(alpha = 0.12f)
    } else {
        Color.Black.copy(alpha = 0.09f)
    }

    SkinPreset.TITANIUM -> if (dark) {
        Color(0xFFD7E2E7).copy(alpha = 0.20f)
    } else {
        Color(0xFF46545B).copy(alpha = 0.17f)
    }

    SkinPreset.WOOD -> if (dark) {
        Color(0xFFE4B979).copy(alpha = 0.20f)
    } else {
        Color(0xFF623519).copy(alpha = 0.17f)
    }

    SkinPreset.CAMERA_CONTROLS -> if (dark) {
        Color(0xFFCDD3D6).copy(alpha = 0.16f)
    } else {
        Color(0xFF23272A).copy(alpha = 0.18f)
    }
}

fun stackedThumbnailThemeBorderColor(skin: SkinPreset, dark: Boolean): Color {
    val base = thumbnailThemeBorderColor(skin, dark)
    return base.copy(alpha = (base.alpha * 1.55f).coerceAtMost(0.36f))
}

/** 已完成任务与目录扫描结果统一使用已传输徽标，其余状态仍属于队列过程。 */
fun showsQueueStatusOverlay(status: TransferStatus): Boolean =
    when (status) {
        TransferStatus.COMPLETED -> false
        TransferStatus.WAITING,
        TransferStatus.TRANSFERING,
        TransferStatus.FAILED,
        TransferStatus.CANCELLED -> true
    }

@Composable
fun TransferredIndicator() {
    val colors = AppTheme.colors
    // 已传输是状态徽标而不是可点击按钮：复用全局玻璃材质，但不挂点击、投影或按压反馈。
    // heavy 实底保证叠在任何明暗照片上都清楚，绿色细边与对号共同表达“已完成”。
    GlassSurface(
        modifier = Modifier.size(24.dp),
        shape = CircleShape,
        active = true,
        activeColor = colors.statusConnected,
        tint = colors.glassSurfaceHeavy,
        borderColor = colors.statusConnected.copy(alpha = 0.72f)
    ) {
        Icon(
            Icons.Default.Check,
            contentDescription = null,
            tint = colors.statusConnected,
            modifier = Modifier
                .align(Alignment.Center)
                .size(15.dp)
        )
    }
}

/**
 * 连拍标志：叠帧图标 + 三条渐短速度线（缩略图右上角标与筛选面板连拍胶囊共用，一处定义两处一致）。
 * [tint] 决定图标与速度线颜色（角标用白、胶囊用内容色）。
 */
@Composable
fun BurstGlyph(
    tint: Color,
    modifier: Modifier = Modifier,
    iconSize: Dp = 11.dp
) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(iconSize * 0.18f)
    ) {
        Icon(
            Icons.Default.BurstMode,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(iconSize)
        )
        // 三条渐短的速度线（拖尾越短越靠下）：细、压低到与图标齐高。
        Column(
            verticalArrangement = Arrangement.spacedBy(iconSize * 0.11f),
            horizontalAlignment = Alignment.Start
        ) {
            listOf(0.64f, 0.45f, 0.27f).forEach { ratio ->
                Box(
                    modifier = Modifier
                        .width(iconSize * ratio)
                        .height(iconSize * 0.09f)
                        .clip(CircleShape)
                        .background(tint)
                )
            }
        }
    }
}

val BurstBadgeColor = Color(0xFF26A69A)

val ProtectBadgeColor = Color(0xFFFFC107)

private val THUMBNAIL_THEME_BORDER_WIDTH = 0.75.dp

private val TYPE_BADGE_COLORED_EXTS = setOf(".jpg", ".nef", ".mov", ".mp4")

private data class CollapsingGroup(val date: String, val keep: Int)

private const val BURST_REFLOW_DURATION_MS = 300

private const val BURST_MEMBER_ENTER_DURATION_MS = 180

private const val BURST_MEMBER_EXIT_DURATION_MS = 150

const val CAMERA_REMOVAL_REFLOW_DURATION_MS = 280

private const val CAMERA_REMOVAL_ENTER_DURATION_MS = 180

private const val CAMERA_REMOVAL_EXIT_DURATION_MS = 160

@Composable
private fun GroupHeader(
    group: FileGroup,
    text: ThumbnailGridText,
    collapsed: Boolean,
    onToggleCollapse: () -> Unit,
    onTransferGroup: (List<CameraFileInfo>, Rect?) -> Unit
) {
    val colors = AppTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // 日期 + 展开箭头 + 张数合并为一颗毛玻璃"日期胶囊"，整颗可点切换收起/展开：
        // 触点比原来的小图标大得多，规格与右侧"传输"按钮同语言（28dp 高、8dp 圆角）。
        // 箭头用旋转动画（收起朝下、展开转 180°），比图标切换更顺滑。
        val chevron by animateFloatAsState(
            targetValue = if (collapsed) 0f else 180f,
            label = "chevron"
        )
        GlassButton(
            onClick = onToggleCollapse,
            shape = RoundedCornerShape(14.dp),   // 半高全圆，胶囊观感
            contentPadding = PaddingValues(horizontal = 12.dp),
            modifier = Modifier.height(28.dp)
        ) {
            Text(
                text = text.date(group.date),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Bold,
                color = colors.onBackground
            )
            Icon(
                Icons.Default.ExpandMore,
                contentDescription = text.expand(collapsed),
                tint = colors.accentBlue,
                modifier = Modifier
                    .size(18.dp)
                    .rotate(chevron)
            )
            // 仅数字（去掉"张"），tnum 等宽，界面更简约
            AnimatedContent(
                targetState = group.files.size,
                transitionSpec = {
                    (slideInVertically { it / 2 } + fadeIn(tween(140)))
                        .togetherWith(slideOutVertically { -it / 2 } + fadeOut(tween(100)))
                        .using(SizeTransform(clip = true, sizeAnimationSpec = { _, _ -> snap() }))
                },
                label = "dateGroupCount",
            ) { count ->
                Text(
                    text = "$count",
                    style = MaterialTheme.typography.bodySmall.copy(
                        fontFeatureSettings = "tnum",
                    ),
                    color = colors.onSurfaceVariant,
                )
            }
        }
        Spacer(modifier = Modifier.weight(1f))
        // 整组传输始终允许再次加入；任务执行时分别检查原片和边框是否已经存在。
        // 按钮在根坐标系的 bounds 供"整组吸入"动画定位起飞点。
        var plusBounds by remember { mutableStateOf<Rect?>(null) }
        GlassButton(
            onClick = { onTransferGroup(group.files, plusBounds) },
            enabled = group.files.isNotEmpty(),
            shape = RoundedCornerShape(14.dp),
            modifier = Modifier
                .width(40.dp)
                .height(28.dp)
                .onGloballyPositioned {
                    // 只收有效样本，避免分离/复用瞬间的零矩形污染动画起点。
                    if (it.isAttached) {
                        val b = it.boundsInRoot()
                        if (b.width > 0f && b.height > 0f) plusBounds = b
                    }
                },
            contentPadding = PaddingValues(horizontal = 10.dp),
            enforceMinimumTouchTarget = false,
        ) {
            Icon(
                Icons.Default.Add,
                contentDescription = text.transferGroup(),
                tint = colors.accentBlue,
                modifier = Modifier.size(18.dp)
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@kotlin.native.HiddenFromObjC
@Composable
fun SharedThumbnailGrid(
    groups: List<FileGroup>,
    tasks: List<TransferTask>,
    queuedIndexByHandle: Map<Int, Int>,
    activeProgress: @Composable () -> ActiveTransferProgress?,
    columns: Int,
    isLoading: Boolean,
    transfersBusy: Boolean,
    allowRemoteThumbnails: Boolean,
    collapsedDates: MutableMap<String, Boolean>,
    thumbnails: ThumbnailGridImageSource,
    text: ThumbnailGridText,
    isTransferred: @Composable (CameraFileInfo) -> Boolean,
    onTransferGroup: (List<CameraFileInfo>, Rect?) -> Unit,
    onTapFile: (CameraFileInfo) -> Unit,
    onPreview: (CameraFileInfo, Rect) -> Unit,
    onPreviewBurst: (String, List<CameraFileInfo>, Rect) -> Unit,
    tapToPreview: Boolean,
    cellBoundsRegistry: MutableMap<Int, Rect>,
    burstBoundsRegistry: MutableMap<String, Rect>,
    burstHandles: Set<Int>,
    burstIdByHandle: Map<Int, String>,
    collapseBurstPhotos: Boolean,
    expandedBursts: MutableMap<String, Boolean>,
    contentPadding: PaddingValues,
    gridState: LazyGridState,
    modifier: Modifier = Modifier,
    // 筛选入场：确定筛选的瞬间 tick 递增、window 开启 600ms（都在事件回调里同步置起，
    // 晚一帧格子就先以终态闪现穿帮）。窗口内组成的格子重播级联入场——复用分组展开的
    // "瞬时重排 + 级联入场"方案；条目位移动画不可用的原因见下方手风琴注释。
    filterRevealTick: Int = 0,
    filterRevealWindow: Boolean = false,
    exitingExportHandles: Set<Int> = emptySet(),
    exportReflowActive: Boolean = false,
    cameraRemovalReflowActive: Boolean = false,
    cameraRemovalAffectedDates: Set<String> = emptySet(),
    returnFocusHandle: Int? = null,
    returnFocusNonce: Int = 0,
    onExportExitFinished: (Int) -> Unit = {}
) {
    val colors = AppTheme.colors
    val thumbnailSkin = LocalButtonTexturePalette.current?.skin ?: SkinPreset.FROSTED_GLASS
    val thumbnailDark = colors.background.luminance() < 0.5f
    val thumbnailBorderColor = remember(thumbnailSkin, thumbnailDark) {
        thumbnailThemeBorderColor(thumbnailSkin, thumbnailDark)
    }

    // 日期展开/收起动画（手风琴方案；不用条目位移动画——它对"被推出屏幕的条目"有框架级
    // 边缘悬停，对"从屏外移入"的条目又根本不生效，大日期组收起时什么动画都看不到）：
    // - 收起：真实的高度收合。收起瞬间只保留该组当前可见的前 keep 个格子参与动画
    //  （其余在屏外，立即移除、无感知）；这些格子按 collapseProgress 收合高度并淡出，
    //   下方内容随布局逐帧连续上移——是布局本身在变化，不经过位移动画器，无任何钳制。
    //   行间距烘焙在格子内部（底部 6dp），随高度一起收合，动画结束零跳变。
    // - 展开：瞬时重排 + 被展开组格子的级联入场（淡入+放大）。不做反向增高动画：
    //   格子从 0 高度长起时视口会一次性容纳数百行，组合成本爆炸。
    var collapsing by remember { mutableStateOf<CollapsingGroup?>(null) }
    val collapseProgress = remember { Animatable(1f) }
    val toggleScope = rememberCoroutineScope()
    var recentlyExpanded by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(recentlyExpanded) {
        if (recentlyExpanded != null) {
            delay(600)   // 入场窗口：展开瞬间组成的格子播入场，之后滚动进入的不播
            recentlyExpanded = null
        }
    }

    // 连拍展开/收起只做一次原子模型更新。成员的出现/消失与所有存量条目的重排均交给
    // Foundation 1.7 的 LazyGrid animateItem：不裁剪屏外成员、不分批、不逐排改模型。
    val expandedBurstIds = expandedBursts.keys.toSet()
    var burstReflowActive by remember { mutableStateOf(false) }
    var activeBurstReflowId by remember { mutableStateOf<String?>(null) }
    var burstAnimationBusy by remember { mutableStateOf(false) }
    val burstScope = rememberCoroutineScope()
    var burstAnimationJob by remember { mutableStateOf<Job?>(null) }

    // 设置切换会直接替换网格展示模型；取消尚未完成的展开/收起任务，避免旧协程
    // 在新模型生效后晚一帧写回展开状态或留下半程 placement 动画。
    LaunchedEffect(collapseBurstPhotos) {
        burstAnimationJob?.cancel()
        burstAnimationJob = null
        burstAnimationBusy = false
        burstReflowActive = false
        activeBurstReflowId = null
    }

    val itemsByDate = remember(
        groups,
        burstIdByHandle,
        collapseBurstPhotos,
        expandedBurstIds
    ) {
        groups.associate { group ->
            group.date to buildThumbnailGridItems(
                files = group.files,
                burstIdByHandle = burstIdByHandle,
                collapseBurstPhotos = collapseBurstPhotos,
                expandedBurstIds = expandedBurstIds
            )
        }
    }

    // “未传输”筛选的单格退场原本由 ThumbnailCell 回调完成。折叠合集里的成员不会
    // compose，必须在这里直接结算，否则它会永远滞留在过滤快照中。
    val hiddenBurstHandles = remember(itemsByDate, expandedBurstIds) {
        itemsByDate.values.asSequence()
            .flatten()
            .filterIsInstance<ThumbnailGridItem.BurstCollection>()
            .filter { it.id !in expandedBurstIds }
            .flatMap { it.files.asSequence() }
            .mapTo(HashSet()) { it.handle }
    }
    val hiddenExitingHandles = exitingExportHandles.intersect(hiddenBurstHandles)
    LaunchedEffect(hiddenExitingHandles) {
        hiddenExitingHandles.forEach(onExportExitFinished)
    }

    val toggleBurstCollection: (String) -> Unit = { burstId ->
        if (!burstAnimationBusy && collapsing == null && !cameraRemovalReflowActive) {
            burstAnimationBusy = true
            burstAnimationJob = burstScope.launch {
                try {
                    val exists = itemsByDate.values.asSequence()
                        .flatten()
                        .filterIsInstance<ThumbnailGridItem.BurstCollection>()
                        .any { it.id == burstId }
                    if (!exists) return@launch

                    // 先让所有条目的 animateItem 节点进入同一个重排窗口，再在下一帧只提交
                    // 一次最终列表。无论连拍有几张，所有既有照片、合集和标题共享同一起点。
                    activeBurstReflowId = burstId
                    burstReflowActive = true
                    withFrameNanos { }
                    if (expandedBursts[burstId] == true) {
                        expandedBursts.remove(burstId)
                    } else {
                        expandedBursts[burstId] = true
                    }
                    delay((BURST_REFLOW_DURATION_MS + 48).toLong())
                } finally {
                    burstReflowActive = false
                    activeBurstReflowId = null
                    burstAnimationBusy = false
                }
            }
        }
    }

    // 后台缩略图填充已移入 CameraViewModel.startThumbnailFill（与连接同生共死、
    // 与页面无关——停在队列页也照常推进）；本页只负责可见格子的即时加载。

    LazyVerticalGrid(
        state = gridState,
        columns = GridCells.Fixed(columns.coerceIn(1, 4)),
        modifier = modifier,
        contentPadding = contentPadding,
        // 竖向行距烘焙在每个格子底部（6dp），随收合动画一起缩放；这里只留横向间距。
        horizontalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        groups.forEach { group ->
            val collapsed = collapsedDates[group.date] == true
            val collapsingThis = collapsing?.date == group.date
            val groupItems = itemsByDate[group.date].orEmpty()
            // Camera-side deletion only animates the date group that actually changed. Other date
            // groups must not acquire per-cell placement work merely because an earlier group shrank.
            val cameraRemovalAffectsGroup = cameraRemovalReflowActive &&
                group.date in cameraRemovalAffectedDates
            // 所有既有格位——照片、合集、日期标题——严格共享同一个 placementSpec。
            // 空闲时传 null，但 animateItem 节点始终存在，不会因临时挂载 modifier 错帧。
            val placementSpec = when {
                collapsingThis -> null
                burstReflowActive -> tween<IntOffset>(
                    durationMillis = BURST_REFLOW_DURATION_MS,
                    easing = FastOutSlowInEasing
                )
                cameraRemovalAffectsGroup -> tween<IntOffset>(
                    durationMillis = CAMERA_REMOVAL_REFLOW_DURATION_MS,
                    easing = FastOutSlowInEasing,
                )
                exportReflowActive -> tween<IntOffset>(
                    durationMillis = 280,
                    easing = FastOutSlowInEasing
                )
                else -> null
            }
            // 分组头整行跨列，保持与列表模式一致的分组语义
            item(
                span = { GridItemSpan(maxLineSpan) },
                key = "header_${group.date}",
                contentType = "header"
            ) {
                Column(
                    modifier = Modifier.animateItem(
                        fadeInSpec = if (cameraRemovalAffectsGroup) {
                            tween(CAMERA_REMOVAL_ENTER_DURATION_MS, easing = FastOutSlowInEasing)
                        } else {
                            null
                        },
                        placementSpec = placementSpec,
                        fadeOutSpec = if (cameraRemovalAffectsGroup) {
                            tween(CAMERA_REMOVAL_EXIT_DURATION_MS, easing = FastOutSlowInEasing)
                        } else {
                            null
                        },
                    )
                ) {
                    Spacer(modifier = Modifier.height(4.dp))
                    GroupHeader(
                        text = text,
                        group = group,
                        // 收合动画进行中箭头即刻转向，不等动画结束。
                        collapsed = collapsed || collapsingThis,
                        onToggleCollapse = {
                            // 日期与连拍都在改变同一网格布局，任一收合进行中都忽略再次点击，
                            // 防止两套高度动画同帧竞争。
                            if (collapsing == null && !burstAnimationBusy &&
                                !cameraRemovalReflowActive
                            ) {
                                if (collapsed) {
                                    // 展开：瞬时重排 + 该组格子级联入场。
                                    recentlyExpanded = group.date
                                    collapsedDates[group.date] = false
                                } else {
                                    recentlyExpanded = null
                                    toggleScope.launch {
                                        // 只保留当前可见的格子（+一行缓冲）参与收合动画。
                                        val visibleKeys = gridState.layoutInfo.visibleItemsInfo
                                            .mapTo(HashSet()) { it.key }
                                        val lastVisible = groupItems.indexOfLast { it.key in visibleKeys }
                                        if (lastVisible < 0) {
                                            collapsedDates[group.date] = true
                                        } else {
                                            collapsing = CollapsingGroup(group.date, lastVisible + 1 + columns)
                                            collapseProgress.snapTo(1f)
                                            collapseProgress.animateTo(0f, tween(300, easing = FastOutSlowInEasing))
                                            collapsedDates[group.date] = true
                                            collapsing = null
                                        }
                                    }
                                }
                            }
                        },
                        onTransferGroup = onTransferGroup
                    )
                    // 头到首行的间距（行距已烘焙进格子底部，这里补足到与原 spacedBy 一致）。
                    Spacer(modifier = Modifier.height(10.dp))
                }
            }
            // 收起的分组不 emit cell：ThumbnailCell 不 compose → 不触发 GetThumb，
            // 从而"锁起来"的缩略图不加载；展开后 cell 重新 emit 才恢复加载。
            // 收合动画期间保留可见的前 keep 个格子，随 collapseProgress 收合。
            if (!collapsed || collapsingThis) {
                val displayedItems = if (collapsingThis) {
                    groupItems.take(collapsing?.keep ?: 0)
                } else groupItems
                itemsIndexed(
                    displayedItems,
                    key = { _, item -> item.key },
                    contentType = { _, item -> item.reuseContentType }
                ) { index, item ->
                    // 照片与合集必须由完全相同的外层节点拥有尺寸和 placement 动画。
                    // 只有本次操作合集的成员允许淡入/淡出。其他已展开合集即使被重排，
                    // 也只使用与普通照片相同的 placement，不能重新触发透明度动画。
                    val animateBurstMemberAppearance =
                        burstReflowActive &&
                            item is ThumbnailGridItem.Photo &&
                            item.burstId == activeBurstReflowId
                    Box(
                        modifier = Modifier
                            .animateItem(
                                fadeInSpec = if (animateBurstMemberAppearance) {
                                    tween(
                                        BURST_MEMBER_ENTER_DURATION_MS,
                                        easing = FastOutSlowInEasing
                                    )
                                } else if (cameraRemovalAffectsGroup) {
                                    tween(
                                        CAMERA_REMOVAL_ENTER_DURATION_MS,
                                        easing = FastOutSlowInEasing,
                                    )
                                } else {
                                    null
                                },
                                placementSpec = placementSpec,
                                fadeOutSpec = if (animateBurstMemberAppearance) {
                                    tween(
                                        BURST_MEMBER_EXIT_DURATION_MS,
                                        easing = FastOutSlowInEasing
                                    )
                                } else if (cameraRemovalAffectsGroup) {
                                    tween(
                                        CAMERA_REMOVAL_EXIT_DURATION_MS,
                                        easing = FastOutSlowInEasing,
                                    )
                                } else {
                                    null
                                }
                            )
                            .then(
                                if (collapsingThis) {
                                    Modifier.collapseHeight { collapseProgress.value }
                                } else {
                                    Modifier
                                }
                            )
                            .padding(bottom = 6.dp)
                            .aspectRatio(1f)
                    ) {
                        when (item) {
                            is ThumbnailGridItem.BurstCollection -> {
                                val expanded = expandedBursts[item.id] == true
                                BurstCollectionCell(
                                    collectionId = item.id,
                                    files = item.files,
                                    expanded = expanded,
                                    transfersBusy = transfersBusy,
                                    allowRemoteThumbnails = allowRemoteThumbnails,
                                    thumbnails = thumbnails,
                                    text = text,
                                    onTransferGroup = onTransferGroup,
                                    onToggle = { toggleBurstCollection(item.id) },
                                    onPreviewFirst = { rect ->
                                        onPreviewBurst(item.id, item.files, rect)
                                    },
                                    onBoundsChanged = { bounds ->
                                        if (bounds == null) burstBoundsRegistry.remove(item.id)
                                        else burstBoundsRegistry[item.id] = bounds
                                    },
                                    modifier = Modifier.fillMaxSize()
                                )
                            }
                            is ThumbnailGridItem.Photo -> {
                                val file = item.file
                                val transferred = isTransferred(file)
                                ThumbnailCell(
                                    file = file,
                                    task = queuedIndexByHandle[file.handle]
                                        ?.let(tasks::getOrNull)
                                        ?.takeIf { it.file.handle == file.handle },
                                    transferred = transferred,
                                    activeProgress = activeProgress,
                                    themeBorderColor = thumbnailBorderColor,
                                    transfersBusy = transfersBusy,
                                    allowRemoteThumbnail = allowRemoteThumbnails,
                                    thumbnails = thumbnails,
                                    text = text,
                                    onTapFile = onTapFile,
                                    onPreview = onPreview,
                                    tapToPreview = tapToPreview,
                                    cellBoundsRegistry = cellBoundsRegistry,
                                    inBurst = file.handle in burstHandles,
                                    animateBurstBadgeRemoval = cameraRemovalAffectsGroup,
                                    inExpandedBurstCollection =
                                        collapseBurstPhotos &&
                                            item.burstId != null &&
                                            item.burstId in expandedBurstIds,
                                    // 连拍展开不参与缩放；这里只保留原有日期与筛选入场。
                                    reveal =
                                        group.date == recentlyExpanded || filterRevealWindow,
                                    revealDelayMs = (index.coerceAtMost(18) * 15).toLong(),
                                    revealKey = filterRevealTick,
                                    exiting = file.handle in exitingExportHandles,
                                    returnFocusNonce = returnFocusNonce.takeIf {
                                        returnFocusHandle == file.handle
                                    },
                                    onExitFinished = onExportExitFinished,
                                    modifier = Modifier.fillMaxSize()
                                )
                            }
                        }
                    }
                }
            }
        }

        if (isLoading) {
            item(span = { GridItemSpan(maxLineSpan) }) { LoadingMoreRow(text) }
        }
    }
}

@Composable
private fun BurstCollectionCell(
    collectionId: String,
    files: List<CameraFileInfo>,
    expanded: Boolean,
    transfersBusy: Boolean,
    allowRemoteThumbnails: Boolean,
    thumbnails: ThumbnailGridImageSource,
    text: ThumbnailGridText,
    onTransferGroup: (List<CameraFileInfo>, Rect?) -> Unit,
    onToggle: () -> Unit,
    onPreviewFirst: (Rect) -> Unit,
    onBoundsChanged: (Rect?) -> Unit,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    val a11y = text.burstAccessibility(files.size)
    // 两个坐标都只在点击/长按瞬间读取，使用普通容器避免列表滚动时的全局坐标变化
    // 触发合集卡重组。合集 registry 同样是普通 Map，更新本身不使网格重组。
    val plusBoundsRef = remember { arrayOfNulls<Rect>(1) }
    val collectionBoundsRef = remember { arrayOfNulls<Rect>(1) }
    val latestOnPreviewFirst by rememberUpdatedState(onPreviewFirst)
    val latestOnBoundsChanged by rememberUpdatedState(onBoundsChanged)
    DisposableEffect(collectionId) {
        // LazyGrid 可复用同 contentType 的组合槽；以真实 id 为 key，复用到下一合集前
        // 先精确清掉旧 id 的坐标，避免普通 HashMap 留下不可见的历史项。
        onDispose { onBoundsChanged(null) }
    }
    val chevronRotation by animateFloatAsState(
        targetValue = if (expanded) 180f else 0f,
        animationSpec = tween(240, easing = FastOutSlowInEasing),
        label = "burstCollectionChevron"
    )

    BoxWithConstraints(
        modifier = modifier
            .onGloballyPositioned {
                if (it.isAttached) {
                    val bounds = it.boundsInRoot()
                    if (bounds.width > 0f && bounds.height > 0f) {
                        collectionBoundsRef[0] = bounds
                        latestOnBoundsChanged(bounds)
                    }
                }
            }
            .semantics { contentDescription = a11y }
    ) {
        val cellWidth = maxWidth
        // 在保持清晰触点的同时收紧视觉尺寸；极窄格子继续按比例缩小，避免两钮相碰。
        val actionSize = when {
            cellWidth < 78.dp -> 30.dp
            cellWidth < 96.dp -> 34.dp
            cellWidth < 132.dp -> 36.dp
            else -> 40.dp
        }
        val actionInset = if (cellWidth < 96.dp) 3.dp else 7.dp
        // 深色主题下照片透过玻璃底过多时按钮轮廓会发虚；只给合集两钮补一层很淡的
        // 圆形暗底，保留玻璃高光与描边。浅色主题完全不变。
        val actionBacking = if (colors.background == DarkAppColors.background) {
            Color.Black.copy(alpha = 0.18f)
        } else {
            Color.Transparent
        }
        AnimatedContent(
            targetState = files,
            // Only these three members are rendered in the stack. A deletion outside them should
            // update the count without recomposing an identical old/new photo stack.
            contentKey = { current -> current.take(3).map { it.publishedIdentity() } },
            transitionSpec = {
                fadeIn(tween(CAMERA_REMOVAL_ENTER_DURATION_MS)) togetherWith
                    fadeOut(tween(CAMERA_REMOVAL_EXIT_DURATION_MS))
            },
            contentAlignment = Alignment.Center,
            label = "burstCollectionFiles",
            modifier = Modifier.fillMaxSize(),
        ) { animatedFiles ->
            Box(modifier = Modifier.fillMaxSize()) {
                val stackFiles = animatedFiles.take(3).reversed()
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
                        index % 2 == 0 -> (-4).dp
                        else -> 4.dp
                    }
                    val y = if (index == last) 1.dp else 2.dp
                    SharedBurstStackPhoto(
                        file = file,
                        thumbnails = thumbnails,
                        transfersBusy = transfersBusy,
                        allowRemoteThumbnail = allowRemoteThumbnails,
                        showPlaceholderIcon = index == last,
                        modifier = Modifier
                            .fillMaxSize(0.86f)
                            .align(Alignment.Center)
                            .offset(x = x, y = y)
                            .graphicsLayer { rotationZ = rotation }
                    )
                }
            }
        }

        // 顶层轻暗角保证角标和底部按钮压在任何照片上都清晰，同时不把照片整体压灰。
        Box(
            modifier = Modifier
                .fillMaxSize(0.86f)
                .align(Alignment.Center)
                .offset(y = 1.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(
                    Brush.verticalGradient(
                        0f to Color.Transparent,
                        0.55f to Color.Transparent,
                        1f to Color.Black.copy(alpha = 0.42f)
                    )
                )
        )

        // 图片区域仅响应长按；普通轻触仍不做任何事。按钮后绘制在更高层，
        // 因而左下入队和右下展开不会被这层手势抢占。
        Box(
            modifier = Modifier
                .fillMaxSize(0.86f)
                .align(Alignment.Center)
                .pointerInput(files.firstOrNull()?.handle) {
                    detectTapGestures(
                        onLongPress = {
                            // 长按只建立“合集 + 成员”的预览快照并直达第一张；底层列表不在
                            // 预览出现前重排，从而不会短暂闪出展开成员或箭头旋转。
                            collectionBoundsRef[0]?.let(latestOnPreviewFirst)
                        }
                    )
                }
        )

        SharedBurstCollectionBadge(
            text = text,
            count = files.size,
            iconSize = 13.dp,
            modifier = Modifier
                .align(Alignment.TopStart)
                .offset(x = 9.dp, y = 9.dp)
        )

        // 用户指定的位置：左下整组入队，右下展开/收起。按钮直接复用全局 GlassButton；
        // 只有在 4 列极窄格子下按比例缩小，避免两颗触点互相覆盖。
        GlassButton(
            onClick = { onTransferGroup(files, plusBoundsRef[0]) },
            enabled = files.isNotEmpty(),
            shape = CircleShape,
            contentPadding = PaddingValues(0.dp),
            showSheen = false,
            modifier = Modifier
                .align(Alignment.BottomStart)
                .offset(x = actionInset, y = -actionInset)
                .size(actionSize)
                .drawBehind { drawCircle(actionBacking) }
                .onGloballyPositioned {
                    if (it.isAttached) {
                        val bounds = it.boundsInRoot()
                        if (bounds.width > 0f && bounds.height > 0f) {
                            plusBoundsRef[0] = bounds
                        }
                    }
                }
        ) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = Icons.Default.Add,
                    contentDescription = text.transferGroup(),
                    tint = colors.accentBlue,
                    modifier = Modifier.size(actionSize * 0.54f)
                )
            }
        }

        GlassButton(
            onClick = onToggle,
            shape = CircleShape,
            contentPadding = PaddingValues(0.dp),
            showSheen = false,
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .offset(x = -actionInset, y = -actionInset)
                .size(actionSize)
                .drawBehind { drawCircle(actionBacking) }
        ) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Icon(
                    Icons.Default.ChevronRight,
                    contentDescription = text.expand(!expanded),
                    tint = colors.accentBlue,
                    modifier = Modifier
                        .size(actionSize * 0.58f)
                        .rotate(chevronRotation)
                )
            }
        }
    }
}

@kotlin.native.HiddenFromObjC
@Composable
fun SharedBurstStackPhoto(
    file: CameraFileInfo,
    thumbnails: ThumbnailGridImageSource,
    transfersBusy: Boolean,
    loadEnabled: Boolean = true,
    allowRemoteThumbnail: Boolean = true,
    showPlaceholderIcon: Boolean,
    modifier: Modifier = Modifier
) {
    val colors = AppTheme.colors
    val skin = LocalButtonTexturePalette.current?.skin ?: SkinPreset.FROSTED_GLASS
    val dark = colors.background.luminance() < 0.5f
    val borderColor = remember(skin, dark) {
        stackedThumbnailThemeBorderColor(skin, dark)
    }
    val thumbnail = thumbnails.stack(file, transfersBusy, loadEnabled, allowRemoteThumbnail)
    val shape = RoundedCornerShape(10.dp)

    Box(
        modifier = modifier
            .clip(shape)
            .background(colors.thumbPlaceholder)
            .border(THUMBNAIL_THEME_BORDER_WIDTH, borderColor, shape)
    ) {
        thumbnail?.let { image ->
            Image(
                bitmap = image,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
        } ?: if (showPlaceholderIcon) {
            Icon(
                imageVector = if (file.extension == ".mov" || file.extension == ".mp4") {
                    Icons.Default.Movie
                } else {
                    Icons.Default.Image
                },
                contentDescription = null,
                tint = colors.onSurfaceVariant.copy(alpha = 0.38f),
                modifier = Modifier
                    .size(28.dp)
                    .align(Alignment.Center)
            )
        } else {
            Unit
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ThumbnailCell(
    file: CameraFileInfo,
    task: TransferTask?,
    transferred: Boolean,
    activeProgress: @Composable () -> ActiveTransferProgress?,
    themeBorderColor: Color,
    transfersBusy: Boolean,
    allowRemoteThumbnail: Boolean,
    thumbnails: ThumbnailGridImageSource,
    text: ThumbnailGridText,
    onTapFile: (CameraFileInfo) -> Unit,
    onPreview: (CameraFileInfo, Rect) -> Unit,
    tapToPreview: Boolean,
    cellBoundsRegistry: MutableMap<Int, Rect>,
    modifier: Modifier = Modifier,
    inBurst: Boolean = false,
    animateBurstBadgeRemoval: Boolean = false,
    inExpandedBurstCollection: Boolean = false,
    reveal: Boolean = false,
    revealDelayMs: Long = 0L,
    // 变化即重播入场动画（筛选确定时存量格子也要重播）；平时保持不变。
    revealKey: Any? = null,
    exiting: Boolean = false,
    returnFocusNonce: Int? = null,
    onExitFinished: (Int) -> Unit = {}
) {
    val colors = AppTheme.colors
    // 展开/筛选入场：本组刚被展开或筛选刚确定时淡入+轻微放大、按 revealDelayMs 级联错峰；
    // 平时（滚动进入）revealProgress 初始即 1，直接全显、零开销。
    val revealProgress = remember(revealKey) { Animatable(if (reveal) 0f else 1f) }
    LaunchedEffect(revealKey) {
        if (revealProgress.value < 1f) {
            delay(revealDelayMs)
            revealProgress.animateTo(1f, tween(220))
        }
    }
    // 仅当前完成传输的格子缩小淡出。动画结束后父层才把它加入过滤集合，
    // 因而 LazyGrid 有完整的旧、 新位置可用于其余条目的补位动画。
    val exitProgress = remember(file.handle) { Animatable(1f) }
    val returnFocusPulse = remember(file.handle) { Animatable(0f) }
    val latestOnExitFinished by rememberUpdatedState(onExitFinished)
    LaunchedEffect(exiting) {
        if (exiting) {
            exitProgress.snapTo(1f)
            exitProgress.animateTo(0f, tween(200, easing = FastOutSlowInEasing))
            latestOnExitFinished(file.handle)
        } else if (exitProgress.value != 1f) {
            exitProgress.snapTo(1f)
        }
    }
    val thumbnail = thumbnails.photo(file, transfersBusy, allowRemoteThumbnail)
    DisposableEffect(file.handle, cellBoundsRegistry) {
        onDispose {
            cellBoundsRegistry.remove(file.handle)
        }
    }
    LaunchedEffect(returnFocusNonce) {
        if (returnFocusNonce != null) {
            returnFocusPulse.snapTo(0f)
            repeat(2) {
                returnFocusPulse.animateTo(1f, tween(110, easing = FastOutSlowInEasing))
                returnFocusPulse.animateTo(0f, tween(155, easing = FastOutSlowInEasing))
                delay(35)
            }
        }
    }

    val thumbnailShape = RoundedCornerShape(8.dp)
    val thumbnailBorderWidth = if (inExpandedBurstCollection) 1.dp else THUMBNAIL_THEME_BORDER_WIDTH
    val thumbnailBorderColor = if (inExpandedBurstCollection) {
        colors.accentOrange.copy(alpha = 0.92f)
    } else {
        themeBorderColor
    }
    Box(
        modifier = modifier
            .graphicsLayer {
                val revealP = revealProgress.value
                val exitP = exitProgress.value
                alpha = (if (reveal) revealP else 1f) * exitP
                // 只有明确处于日期/筛选 reveal 窗口的格子才允许缩放；普通网格重排
                // 永远保持 1x，避免连拍展开让无关照片整体“缩一下再弹回”。
                val revealScale = if (reveal) 0.94f + 0.06f * revealP else 1f
                val exitScale = 0.82f + 0.18f * exitP
                val s = revealScale * exitScale
                val returnScale = 1f + 0.055f * returnFocusPulse.value
                scaleX = s * returnScale
                scaleY = s * returnScale
            }
            .clip(thumbnailShape)
            .background(colors.thumbPlaceholder)
            .border(
                width = thumbnailBorderWidth,
                color = thumbnailBorderColor,
                shape = thumbnailShape,
            )
            .onGloballyPositioned {
                // 同一份 bounds 双用:长按预览的放大起点 + 打包动画的灵魂起点。
                // 只收有效样本：分离/复用瞬间的零矩形会让动画从屏幕外冒出。
                if (it.isAttached) {
                    val b = it.boundsInRoot()
                    if (b.width > 0f && b.height > 0f) {
                        cellBoundsRegistry[file.handle] = b
                    }
                }
            }
            // 只在这里交换两个既有动作的手势入口；传输校验、入队和预览逻辑保持单一来源。
            .combinedClickable(
                enabled = !exiting,
                onClick = {
                    if (tapToPreview) {
                        cellBoundsRegistry[file.handle]?.let { onPreview(file, it) }
                    } else onTapFile(file)
                },
                onLongClick = {
                    if (tapToPreview) onTapFile(file)
                    else cellBoundsRegistry[file.handle]?.let { onPreview(file, it) }
                }
            )
    ) {
        val image = thumbnail
        if (image != null) {
            Image(
                bitmap = image,
                contentDescription = file.fileName,
                // 黑边已在解码时按实际黑条精确裁除（CameraViewModel.cropLetterbox），
                // Crop 填满格子即为刚好，无需再放大遮边。
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
        } else {
            // 占位：类型角标底色
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = when (file.extension) {
                        ".mov", ".mp4" -> Icons.Default.Movie
                        else -> Icons.Default.Image
                    },
                    contentDescription = null,
                    tint = colors.onSurfaceVariant.copy(alpha = 0.4f),
                    modifier = Modifier.size(28.dp)
                )
            }
        }

        // 左上角类型角标
        Surface(
            shape = RoundedCornerShape(bottomEnd = 6.dp),
            color = when (file.extension) {
                ".jpg" -> colors.accentBlue.copy(alpha = 0.85f)
                ".nef" -> colors.accentPurple.copy(alpha = 0.85f)
                // 视频统一橙色（MOV/MP4 同族）；MP4 原本落到灰底、灰字太不起眼。
                ".mov", ".mp4" -> colors.accentOrange.copy(alpha = 0.85f)
                else -> colors.surfaceVariant.copy(alpha = 0.85f)
            },
            modifier = Modifier.align(Alignment.TopStart)
        ) {
            Text(
                text = file.extension.uppercase().removePrefix("."),
                modifier = Modifier.padding(horizontal = 4.dp, vertical = 1.dp),
                style = MaterialTheme.typography.labelSmall.copy(fontSize = 9.sp, lineHeight = 10.sp),
                fontWeight = FontWeight.Medium,
                color = if (file.extension in TYPE_BADGE_COLORED_EXTS) colors.onAccent else colors.onSurfaceVariant
            )
        }

        // 右上角连拍角标：与左上角类型标签同族的角贴(实色底 + 白色内容),
        // 青绿是连拍的专属色(蓝/紫/橙已被类型占用,绿是传输状态色)。
        // 叠帧图标 + 三条渐短的速度线("嗖"地扫过的拖尾),不用文字也一眼读出
        // "这一串是按住快门快速扫出来的"。算法见 computeBurstGroups。
        // 普通照片不常驻一套 AnimatedVisibility；只有连拍成员和本次受影响组保留，
        // 既能让展开后的幸存照片平滑退掉连拍角标，也不给全列表增加空动画节点。
        if (inBurst || animateBurstBadgeRemoval) {
            AnimatedVisibility(
                visible = inBurst,
                enter = fadeIn(tween(CAMERA_REMOVAL_ENTER_DURATION_MS)) + scaleIn(
                    animationSpec = tween(CAMERA_REMOVAL_ENTER_DURATION_MS),
                    initialScale = 0.82f,
                ),
                exit = fadeOut(tween(CAMERA_REMOVAL_EXIT_DURATION_MS)) + scaleOut(
                    animationSpec = tween(CAMERA_REMOVAL_EXIT_DURATION_MS),
                    targetScale = 0.82f,
                ),
                modifier = Modifier.align(Alignment.TopEnd),
            ) {
                Surface(
                    shape = RoundedCornerShape(bottomStart = 6.dp),
                    color = BurstBadgeColor.copy(alpha = 0.85f),
                ) {
                    // 叠帧图标 + 三条渐短速度线；与筛选面板的连拍胶囊共用 BurstGlyph，保证一致。
                    BurstGlyph(
                        tint = colors.onAccent,
                        modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp)
                    )
                }
            }
        }

        // 左下角保护角标（机内 🔑 选片标记）：黄底深色钥匙,像一枚金钥匙,标注
        // "这张被机内选中/保护"。四角分工:左上类型、右上连拍、左下保护、右下传输状态。
        if (file.isProtected) {
            Surface(
                shape = RoundedCornerShape(topEnd = 6.dp),
                color = ProtectBadgeColor.copy(alpha = 0.9f),
                modifier = Modifier.align(Alignment.BottomStart)
            ) {
                Icon(
                    Icons.Default.Key,
                    contentDescription = text.protectedPhoto(),
                    tint = Color.Black.copy(alpha = 0.75f),
                    modifier = Modifier
                        .padding(3.dp)
                        .size(11.dp)
                )
            }
        }

        // 只有尚在队列流程中的任务显示遮罩和状态角标；COMPLETED 已经是“目录中存在”，
        // 与历史扫描结果统一交给下方玻璃绿勾，不再保留另一套半透明完成样式。
        val overlayTask = task?.takeIf { showsQueueStatusOverlay(it.status) }
        // lastTask 保留最后一次的任务，退场动画期间角标仍有内容可渲染。
        var lastTask by remember(file.handle) { mutableStateOf(overlayTask) }
        LaunchedEffect(overlayTask) { if (overlayTask != null) lastTask = overlayTask }
        AnimatedVisibility(
            visible = overlayTask != null,
            enter = fadeIn(tween(150)),
            exit = fadeOut(tween(150)),
            modifier = Modifier.matchParentSize()
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(colors.background.copy(alpha = 0.35f))
            ) {
                (overlayTask ?: lastTask)?.let { t ->
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .padding(4.dp)
                    ) {
                        SharedTransferStatusIndicator(
                            task = t,
                            activeProgress = activeProgress,
                        )
                    }
                }
            }
        }
        AnimatedVisibility(
            visible = transferred && overlayTask == null,
            enter = fadeIn(tween(150)),
            exit = fadeOut(tween(120)),
            modifier = Modifier.align(Alignment.BottomEnd).padding(4.dp),
        ) {
            TransferredIndicator()
        }
        if (returnFocusNonce != null) {
            // 只给目标格子挂一层短命亮度脉冲；alpha 在图层阶段读取，不逐帧重组网格。
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .graphicsLayer { alpha = returnFocusPulse.value * 0.11f }
                    .background(Color.White)
            )
        }
    }
}

@Composable
private fun LoadingMoreRow(text: ThumbnailGridText) {
    val colors = AppTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically
    ) {
        CircularProgressIndicator(
            modifier = Modifier.size(20.dp),
            color = colors.accentBlue,
            strokeWidth = 2.dp
        )
        Spacer(modifier = Modifier.width(8.dp))
        Text(text.loading(), style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
    }
}

/** 合集数量角标：列表与预览严格共用，仅通过 [iconSize] 等比缩放。 */
@kotlin.native.HiddenFromObjC
@Composable
fun SharedBurstCollectionBadge(
    text: ThumbnailGridText,
    count: Int,
    modifier: Modifier = Modifier,
    iconSize: Dp = 13.dp
) {
    val colors = AppTheme.colors
    Surface(
        shape = RoundedCornerShape(iconSize * 0.69f),
        color = BurstBadgeColor.copy(alpha = 0.9f),
        modifier = modifier
    ) {
        Row(
            modifier = Modifier.padding(
                horizontal = iconSize * 0.46f,
                vertical = iconSize * 0.23f
            ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(iconSize * 0.31f)
        ) {
            BurstGlyph(tint = colors.onAccent, iconSize = iconSize)
            AnimatedContent(
                targetState = count,
                transitionSpec = {
                    (slideInVertically { it / 2 } + fadeIn(tween(140)))
                        .togetherWith(slideOutVertically { -it / 2 } + fadeOut(tween(100)))
                        .using(SizeTransform(clip = true, sizeAnimationSpec = { _, _ -> snap() }))
                },
                label = "burstCollectionCount",
            ) { animatedCount ->
                Text(
                    text = text.burstCount(animatedCount),
                    style = MaterialTheme.typography.labelSmall.copy(
                        fontSize = (iconSize.value * 0.69f).sp,
                        fontFeatureSettings = "tnum"
                    ),
                    fontWeight = FontWeight.SemiBold,
                    color = colors.onAccent
                )
            }
        }
    }
}

/**
 * 缩略图右下角传输状态角标:统一的暗色圆片承载各状态图形——圆片给图形提供
 * 恒定的对比度,不再让裸图标的可读性赌照片内容的深浅(旧版即是如此,观感过时)。
 * 等待=时钟、传输中=【确定型】进度环(与队列卡片同一进度语义,不再放空转圈)、
 * 完成=绿钩、失败=红色感叹、取消=灰叉;状态切换交叉淡化不硬切。
 * 与左下保护角标同底色,四角的"状态类"标识(左下/右下)共享一种安静的暗片语言,
 * 与"分类类"的彩色角贴(左上类型/右上连拍)分层。
 */
@kotlin.native.HiddenFromObjC
@Composable
fun SharedTransferStatusIndicator(
    task: TransferTask,
    activeProgress: @Composable () -> ActiveTransferProgress?,
) {
    val colors = AppTheme.colors
    Box(
        modifier = Modifier
            .size(22.dp)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.45f)),
        contentAlignment = Alignment.Center
    ) {
        // Only a transferring task needs the high-frequency flow. Completed/failed/waiting
        // states use their immutable task snapshot, so every thumbnail does not subscribe to
        // the active-transfer ticker.
        val liveProgress = if (task.status == TransferStatus.TRANSFERING) {
            activeProgress()
                ?.takeIf { it.taskId == task.taskId }
                ?.fraction
                ?: task.progress
        } else {
            task.progress
        }
        val animatedProgress = rememberSmoothTransferProgress(
            targetProgress = transferCardProgressTarget(task.status, liveProgress),
            resetKey = task.taskId,
        )
        // Completion first finishes the same ring, then changes visual state. This prevents
        // the unfinished arc from being replaced abruptly while the task status is committed.
        val visualStatus = if (task.status == TransferStatus.COMPLETED &&
            animatedProgress.value < 0.999f
        ) TransferStatus.TRANSFERING else task.status
        Crossfade(targetState = visualStatus, animationSpec = tween(200), label = "cellStatus") { st ->
            Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxSize()) {
                if (st == TransferStatus.TRANSFERING) {
                    // 传输中在列表用确定型进度环（卡片那侧改用下载字形，见 statusGlyph 说明）。
                    // 平滑追值：进度环随进度缓缓扫过，而非一段段硬跳。
                    CircularProgressIndicator(
                        progress = animatedProgress.value,
                        modifier = Modifier.size(15.dp),
                        color = colors.accentBlue,
                        trackColor = Color.White.copy(alpha = 0.25f),
                        strokeWidth = 2.dp,
                        strokeCap = StrokeCap.Round
                    )
                } else {
                    // 其余状态：字形 + 语义色取自共用的 statusGlyph（与传输页卡片统一）。
                    // 黑圆片提供恒定对比，裸符号直接落在片上、语义色照旧读得清。
                    val (icon, tint) = statusGlyph(st)
                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        tint = tint,
                        modifier = Modifier.size(14.dp)
                    )
                }
            }
        }
    }
}
