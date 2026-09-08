@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.*
import androidx.compose.ui.graphics.*
import androidx.compose.ui.layout.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.*
import com.ztransfer.ui.util.Haptics
import com.ztransfer.viewmodel.ActiveTransferProgress
import com.ztransfer.viewmodel.TransferTask
import kotlinx.coroutines.delay

data class QueuePillWidthKey(
    val mode: PillMode,
    val speedUnit: String?,
    val speedIntegerDigits: Int,
    val countDigits: Int,
)

fun queuePillWidthKey(
    mode: PillMode,
    speedText: String?,
    count: Int,
): QueuePillWidthKey {
    if (mode != PillMode.COUNTING && mode != PillMode.PAUSED) {
        return QueuePillWidthKey(mode, speedUnit = null, speedIntegerDigits = 0, countDigits = 0)
    }
    val numericPart = speedText?.substringBefore(' ')
    return QueuePillWidthKey(
        mode = mode,
        speedUnit = speedText?.substringAfter(' ', missingDelimiterValue = ""),
        speedIntegerDigits = numericPart?.substringBefore('.')?.length ?: 0,
        countDigits = count.coerceAtLeast(0).toString().length,
    )
}

@Composable
private fun AnimatedQueuePillCount(
    count: Int,
    color: Color,
    label: String,
    modifier: Modifier = Modifier,
) {
    AnimatedContent(
        modifier = modifier,
        targetState = count,
        transitionSpec = {
            val dir = if (targetState < initialState) 1 else -1
            (slideInVertically { it / 2 * dir } + fadeIn(tween(160)))
                .togetherWith(
                    slideOutVertically { -it / 2 * dir } + fadeOut(tween(120)),
                )
                .using(SizeTransform(clip = true, sizeAnimationSpec = { _, _ -> snap() }))
        },
        label = label,
    ) { value ->
        Text(
            text = "$value",
            style = MaterialTheme.typography.labelLarge.copy(fontFeatureSettings = "tnum"),
            color = color,
            fontWeight = FontWeight.Bold,
        )
    }
}

/** 队列入口收起为普通按钮时使用固定材质种子，保证木纹/金属微纹在重组后保持一致。 */
private const val QUEUE_ENTRY_BUTTON_TEXTURE_SEED = 0x2A71E001
@Composable
@kotlin.native.HiddenFromObjC
fun SharedQueuePill(
    tasks: List<TransferTask>,
    isTransferring: Boolean,
    liveProgressSource: @Composable () -> ActiveTransferProgress?,
    haptics: Haptics,
    onClick: () -> Unit,
    // 显示层押扣:飞行中的"整组包裹"承载的文件数,落袋前不计入读数
    //（数字在包裹到达时才跳上去);实际队列不受影响,仅影响本胶囊显示。
    heldCount: Int = 0,
    formatSpeed: (Long) -> String,
    transferDescription: String,
    generatingLabel: String,
) {
    val colors = AppTheme.colors
    val liveProgress = liveProgressSource()
    val taskSummary = remember(tasks) {
        summarizeQueuePillTasks(tasks)
    }
    val downloadRemaining = taskSummary.downloadRemaining
    val generationRemaining = taskSummary.generationRemaining
    val remaining = if (downloadRemaining > 0) {
        queuePillDisplayRemaining(downloadRemaining, heldCount)
    } else {
        generationRemaining
    }
    // Flight bookkeeping can intentionally display zero until the first card lands. Completion
    // still follows the real task state: that temporary zero uses the icon, never the Done state.
    val allDone = downloadRemaining == 0 && generationRemaining == 0
    val transferring = isTransferring
    val activeProgress = liveProgress?.takeIf {
        it.taskId == taskSummary.activeDownloadTaskId
    }
    // Keep the last valid batch speed across the short preparation gap between two files.
    val activeSpeed = liveProgress?.retainedBytesPerSecond ?: 0L
    val activeSpeedText = activeSpeed
        .takeIf { transferring && it > 0L }
        ?.let(formatSpeed)
    val paused = !transferring && downloadRemaining > 0
    val mode = queuePillMode(downloadRemaining, generationRemaining, paused = paused)
    val widthKey = queuePillWidthKey(mode, activeSpeedText, remaining)
    val hasActive = taskSummary.hasActive
    // 数字延迟显现：刚入队的任务可能马上被"已存在"跳过（remaining 1→0 一闪而过），
    // 那种情况只播 done→图标转场、不闪数字。真正开始下载(TRANSFERING)立即显示数字；
    // 纯等待超过宽限期（说明确实在排队，如目录扫描慢）也显示。
    var countingVisible by remember { mutableStateOf(false) }
    LaunchedEffect(remaining > 0, hasActive, paused) {
        countingVisible = when {
            paused -> true
            hasActive -> true
            remaining > 0 -> { delay(350); true }
            else -> false
        }
    }
    // "done → 图标" 的转场只由"传输中 → 全部完成"触发。prevAllDone 初值取当前 allDone：
    // 若进入本页时已是完成态（例如从队列页返回），不再闪 done，直接显示图标（无转场动画）。
    var showDoneLabel by remember { mutableStateOf(false) }
    var prevAllDone by remember { mutableStateOf(allDone) }
    // 本轮队列是否真的下载过（用于完成震动：纯"已存在跳过"的瞬时完成不震）。
    var sawTransfer by remember { mutableStateOf(false) }
    var finishProgressVisible by remember { mutableStateOf(false) }
    LaunchedEffect(hasActive) {
        if (hasActive) sawTransfer = true
    }
    // 取消导致的"归零"不是完成：不闪 done、不震成功震（否则取消后出现庆祝反馈，误导）。
    // sawTransfer 在每次归零时都复位，取消那轮的记录不能污染下一轮的完成判定。
    val hasCancelled = taskSummary.hasCancelled
    LaunchedEffect(allDone) {
        if (allDone && !prevAllDone) {
            val celebrate = !hasCancelled && sawTransfer
            sawTransfer = false
            finishProgressVisible = celebrate
            if (!hasCancelled) {
                if (celebrate) haptics.success()
                showDoneLabel = true
                delay(1800)
                showDoneLabel = false
            }
            finishProgressVisible = false
        }
        prevAllDone = allDone
    }
    // 尚无飞行卡片落袋时显示默认图标而不是数字 0；这条优先于 PAUSED，确保“选完再传”
    // 模式也遵循相同叙事。其余情况保持原有规则：完成或尚未准许显示数字时收为图标。
    val allRemainingTasksAreInFlight = queuePillAllRemainingTasksAreInFlight(
        actualRemaining = downloadRemaining,
        heldCount = heldCount,
    )
    val collapsedToIcon = allRemainingTasksAreInFlight ||
        (mode != PillMode.PAUSED && (
            (allDone && !showDoneLabel) || (!allDone && !countingVisible)
        ))

    // 进度条 = 当前单文件进度（复用传输页语义）。保留最近的进度归属，让最后一张
    // 完成后仍能从当前位置顺滑补满，而不是因“当前任务”瞬间消失而重建动画。
    var retainedProgressTaskId by remember { mutableStateOf<Long?>(null) }
    LaunchedEffect(taskSummary.activeProgressTaskId) {
        taskSummary.activeProgressTaskId?.let { retainedProgressTaskId = it }
    }
    val barFraction = when {
        allDone && finishProgressVisible -> 1f
        allDone -> 0f // 静止图标态不预热动画，避免下一轮等待阶段错误继承满格。
        activeProgress != null -> activeProgress.fraction
        generationRemaining > 0 -> 1f
        else -> 0f
    }
    val animatedBar = rememberSmoothTransferProgress(
        targetProgress = barFraction,
        resetKey = taskSummary.activeProgressTaskId ?: retainedProgressTaskId,
    )

    // 普通按钮与胶囊共用同一条宽度弹簧。切换材质实现时右缘仍固定，只向左平滑伸缩，
    // 不会因为图标态改用 GlassButton 而丢掉原先的胶囊变形手感。
    val density = LocalDensity.current
    var contentWidthPx by remember { mutableStateOf(0) }
    var activeQueueMaxWidthPx by remember { mutableStateOf(0) }
    var measuredWidthKey by remember { mutableStateOf<QueuePillWidthKey?>(null) }
    val collapsedWidthPx = with(density) { 40.dp.toPx() } // 22dp 图标 + 左右各 9dp
    val widthAnim = remember { Animatable(0f) }
    var firstMeasure by remember { mutableStateOf(true) }
    val stableContentWidthPx = if (
        mode == PillMode.COUNTING && measuredWidthKey == widthKey
    ) {
        maxOf(contentWidthPx, activeQueueMaxWidthPx)
    } else {
        contentWidthPx
    }
    val targetWidthPx = if (collapsedToIcon) collapsedWidthPx else stableContentWidthPx.toFloat()
    LaunchedEffect(targetWidthPx) {
        if (targetWidthPx > 0f) {
            if (firstMeasure) {
                widthAnim.snapTo(targetWidthPx)
                firstMeasure = false
            } else {
                widthAnim.animateTo(targetWidthPx, Motion.bouncy())
            }
        }
    }

    // 图标态已经是普通入口按钮，不再沿用下方固定毛玻璃胶囊的手写 Surface。
    // 直接复用全局按钮组件后，毛玻璃、钛合金（含钢印）与随机稳定木纹都会自动生效；
    // 一旦出现 Done、速度或数量，仍回到原胶囊实现，不受按钮主题影响。
    if (collapsedToIcon) {
        GlassButton(
            onClick = onClick,
            shape = RoundedCornerShape(22.dp),
            contentPadding = PaddingValues(horizontal = 9.dp, vertical = 7.dp),
            enforceMinimumTouchTarget = false,
            textureSeed = QUEUE_ENTRY_BUTTON_TEXTURE_SEED,
            modifier = Modifier
                .height(36.dp)
                .then(
                    if (widthAnim.value > 0f) {
                        Modifier.width(with(density) { widthAnim.value.toDp() })
                    } else {
                        Modifier
                    }
                )
        ) {
            Icon(
                imageVector = Icons.Default.Checklist,
                contentDescription = transferDescription,
                tint = colors.statusConnected,
                modifier = Modifier.size(22.dp)
            )
        }
        return
    }

    // 按压微缩放：本胶囊是顶栏唯一手写 Surface（不经 GlassButton），手感与全局按钮对齐。
    val pillInteraction = remember { MutableInteractionSource() }
    val pillPressed by pillInteraction.collectIsPressedAsState()
    val pillPressScale by animateFloatAsState(
        targetValue = if (pillPressed) 0.95f else 1f,
        animationSpec = if (pillPressed) tween(80) else Motion.bouncy(),
        label = "pillPress"
    )
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(22.dp),
        color = colors.glassSurface,   // 毛玻璃半透明底（与 "Z传" 一致）
        shadowElevation = 4.dp,
        interactionSource = pillInteraction,
        modifier = Modifier
            .height(36.dp)
            .graphicsLayer {
                scaleX = pillPressScale
                scaleY = pillPressScale
            }
            // 用动画宽度；首帧未测量时先按内容自适应，测到后即锁定为动画宽度。
            .then(if (contentWidthPx > 0) Modifier.width(with(density) { widthAnim.value.toDp() }) else Modifier)
    ) {
        Box(contentAlignment = Alignment.CenterEnd) {
            // 1) 单文件进度填充（填满当前动画宽度；收起为图标后不显示）。
            if (!allDone || finishProgressVisible) {
                LiquidProgressFill(
                    progress = { animatedBar.value },
                    waveEligible = taskSummary.activeDownloadTaskId != null ||
                        finishProgressVisible,
                    seedKey = taskSummary.activeProgressTaskId ?: retainedProgressTaskId,
                    color = colors.accentBlue.copy(alpha = 0.35f),
                    modifier = Modifier.matchParentSize(),
                )
            }
            // 2) 毛玻璃高光 + 描边叠层（与 "Z传" 同款，略有区别）。
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .background(
                        brush = Brush.verticalGradient(
                            listOf(colors.glassHighlightTop, colors.glassHighlightBottom)
                        )
                    )
                    .border(
                        width = 1.dp,
                        brush = Brush.verticalGradient(
                            listOf(colors.glassBorderTop, colors.glassBorderBottom)
                        ),
                        shape = RoundedCornerShape(22.dp)
                    )
            )

            // 3) 内容：以自然宽度测量(unbounded)、靠右对齐；宽度动画滞后时左侧溢出被圆角裁掉。
            Box(modifier = Modifier.wrapContentWidth(Alignment.End, unbounded = true)) {
                Box(modifier = Modifier.onGloballyPositioned {
                    contentWidthPx = it.size.width
                    if (measuredWidthKey != widthKey) {
                        measuredWidthKey = widthKey
                        activeQueueMaxWidthPx = it.size.width
                    } else if (
                        mode == PillMode.COUNTING && it.size.width > activeQueueMaxWidthPx
                    ) {
                        activeQueueMaxWidthPx = it.size.width
                    }
                }) {
                    // 胶囊内部的 Done / 计数切换用交叉淡化 + 轻微缩放过渡，不硬切。
                    // 尺寸动画交给外层的弹性宽度弹簧（snap 禁用 AnimatedContent 自带的尺寸
                    // 动画，避免两套叠加）；计数态内部的数字/速度更新不触发转场，原地刷新。
                    AnimatedContent(
                        targetState = mode,
                        // 胶囊右缘钉死、向左伸缩：新旧内容必须都锚定右缘（CenterEnd），
                        // 否则容器 snap 到新宽度时，退场内容会从右对齐跳成左对齐（文字漂移）。
                        contentAlignment = Alignment.CenterEnd,
                        transitionSpec = {
                            (fadeIn(tween(200, delayMillis = 60)) +
                                    scaleIn(
                                        initialScale = 0.85f,
                                        animationSpec = tween(200, delayMillis = 60),
                                        // 缩放原点同样锚在右缘中点，与布局语义一致
                                        transformOrigin = TransformOrigin(1f, 0.5f)
                                    ))
                                .togetherWith(fadeOut(tween(120)))
                                .using(SizeTransform(clip = false, sizeAnimationSpec = { _, _ -> snap() }))
                        },
                        label = "pillContent"
                    ) { m ->
                        when (m) {
                            PillMode.DONE ->
                                Text(
                                    // 刻意不走字符串资源:所有语言统一显示 "Done"(短暂闪现的
                                    // 状态徽记,当装饰性标识处理,不参与本地化)。
                                    text = "Done",
                                    style = MaterialTheme.typography.labelLarge.copy(fontFeatureSettings = "tnum"),
                                    color = colors.statusConnected,
                                    fontWeight = FontWeight.Bold,
                                    modifier = Modifier.padding(horizontal = 16.dp)
                                )
                            PillMode.PAUSED ->
                                AnimatedQueuePillCount(
                                    count = remaining,
                                    color = colors.onBackground,
                                    label = "pausedCount",
                                    modifier = Modifier.padding(horizontal = 16.dp),
                                )
                            PillMode.GENERATING ->
                                Row(
                                    modifier = Modifier.padding(horizontal = 16.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                ) {
                                    Text(
                                        text = generatingLabel,
                                        style = MaterialTheme.typography.labelLarge,
                                        color = colors.accentBlue,
                                        fontWeight = FontWeight.Bold,
                                    )
                                    AnimatedQueuePillCount(
                                        count = generationRemaining,
                                        color = colors.onBackground,
                                        label = "generationCount",
                                    )
                                }
                            PillMode.COUNTING ->
                                Row(
                                    modifier = Modifier.padding(horizontal = 16.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    // 速度在前（仅传输且有速度时显示）。tnum：等宽数字，位数相同则宽度恒定。
                                    if (activeSpeedText != null) {
                                        Text(
                                            text = activeSpeedText,
                                            style = MaterialTheme.typography.labelMedium.copy(fontFeatureSettings = "tnum"),
                                            color = colors.accentBlue,
                                            fontWeight = FontWeight.Bold
                                        )
                                    }
                                    // 数字滚动：减少（传输推进）时旧数上滑、新数自下滑入；增加（新入队）反向。
                                    // 尺寸仍 snap 交给外层宽度弹簧；clip 让滑动的数字在行内裁切，像里程表。
                                    AnimatedQueuePillCount(
                                        count = remaining,
                                        color = colors.onBackground,
                                        label = "downloadCount",
                                    )
                                }
                        }
                    }
                }
            }
        }
    }
}

@kotlin.native.HiddenFromObjC
data class PackSoul(val bounds: Rect, val thumb: ImageBitmap?)

/**
 * 一次"入队吸入"动画的参数([id] 供 key 复用隔离),整组与单张共用:
 * [from] = 起飞点根坐标 bounds(整组 = + 按钮,兼灵魂汇聚点;单张 = 该格子);
 * [packs] = 打包幕的各"灵魂"(整组时为该组可见缩略图;单张恒空 = 跳过打包幕);
 * [count] = 承载的文件数——飞行期间从胶囊计数里"押扣"这么多,落袋才释放,
 * 数字在包裹到达那一刻才跳上去(实际传输在点击瞬间已开始,押扣只是显示层);
 * count==1 时摞退化为不倾斜的单卡;
 * [topThumb] = 顶卡缩略图(整组取本次传输顺序第一张;内存缓存引用,null 回退纯色+图标)。
 */
@kotlin.native.HiddenFromObjC
data class QueueFlight(
    val id: Long,
    val from: Rect,
    val packs: List<PackSoul>,
    val count: Int,
    val topThumb: ImageBitmap?,
    val holdsQueueCount: Boolean = true,
)

// 打包幕最多放飞的缩略图残影数(超出按均匀间隔抽样,视觉密度足够又不糊成一团)。
const val MAX_PACK_GHOSTS = 8

// 连拍角标专属色(青绿):蓝/紫/橙被类型标签占用、绿是传输状态色,须与两族都区分;
// 实色 0.85 底上配白色内容,深浅主题通用(与金徽标同为"单值双主题"的少数例外)。
// internal:预览大图的左上角连拍角标(PhotoPreview)与此同色。

// 保护角标底色(琥珀黄):机内选片/保护标记,黄底配深色钥匙如一枚金钥匙,
// 与彩色分类角贴分层。单值双主题(深浅通用)。

// "吸入"节奏:前段缓(残影凝聚成形、离巢慢),后段陡(加速俯冲进胶囊)——
// 到达时带着冲量,与胶囊的"接住"弹跳在动量上衔接。
/**
 * "打包 → 吸入"两幕连播:
 * 第一幕(~420ms,吸取灵魂):每张可见照片的半透明本体(原位原尺寸、真实缩略图)
 * 先浮起"出窍",再被 + 按钮平方加速吸走、骤缩、吸入即灭,按传输顺序错峰鱼贯;
 * 组收起时没有可见格子,自动跳过本幕。
 * 第二幕(~560ms):三张错位叠放的卡片摞在 + 按钮处凝聚成形(恰接第一幕收尾),
 * 沿二次贝塞尔弧线加速飞向 [target] 右缘的队列胶囊落点,途中收拢缩小、临近终点
 * 淡出;播完 [onDone] 移除自身并触发胶囊"接住"弹跳。
 * 弧线对任意起点自适应:弧高随行程缩放并钳制峰值不飞出屏幕顶(组头可滚到贴着状态栏);
 * 组头 + 按钮与胶囊几乎同在屏幕右缘竖线上,水平行程越小控制点越向左偏,
 * 把近乎竖直的路径弯成一道向内的弧,避免直上直下的呆板。
 * [target] 是胶囊的承载容器(右缘与胶囊右缘钉死重合,不随胶囊宽度动画抖动),
 * 落点取其右缘内侧即胶囊身上。逐帧只写 graphicsLayer,零重组/重布局。
 */
@Composable
@kotlin.native.HiddenFromObjC
fun QueueFlightGhost(flight: QueueFlight, target: Rect?, onDone: () -> Unit) {
    val colors = AppTheme.colors
    val pack = remember { Animatable(0f) }
    val progress = remember { Animatable(0f) }
    val currentOnDone by rememberUpdatedState(onDone)
    LaunchedEffect(Unit) {
        // 兜底:落点未知(理论上只在首帧布局前存在)就不播——立即收尾释放押扣,
        // 不让残影按退化坐标乱飞。
        if (target == null) {
            currentOnDone()
            return@LaunchedEffect
        }
        // 打包幕总时间线用线性——各灵魂的错峰窗口均匀推进,吸走的加速感
        // 由窗口内的平方曲线提供(见下),不叠加两层缓动。
        if (flight.packs.isNotEmpty()) {
            pack.animateTo(1f, tween(420, easing = LinearEasing))
        }
        progress.animateTo(1f, tween(560, easing = QueueFlightEasing))
        currentOnDone()
    }

    // ---------- 第一幕:吸取灵魂。每张可见照片的半透明本体(原位原尺寸、真实缩略图)
    // 先从格子里浮起(上移 + 微放大 + 淡入 = 出窍),再被 + 按钮平方加速吸走,
    // 途中骤缩,吸入瞬间消失。按传输顺序错峰,鱼贯归巢。----------
    val n = flight.packs.size
    val density = LocalDensity.current
    flight.packs.forEachIndexed { i, soul ->
        Box(
            modifier = Modifier
                .size(with(density) { soul.bounds.width.toDp() })
                .graphicsLayer {
                    // 错峰窗口:第 i 张在总进度 [i·step, i·step+span] 内走完自己的行程,
                    // 首尾两张恰好铺满 0..1;只有一个灵魂时窗口铺满全程,
                    // 避免"吸完等半拍才起摞"的空档。
                    // 错峰预算 28%:间隔短、重叠多——一波带着次序的同吸,而非逐张排队。
                    val step = if (n <= 1) 0f else 0.28f / (n - 1)
                    val span = if (n <= 1) 1f else 0.72f
                    val t = ((pack.value - i * step) / span).coerceIn(0f, 1f)
                    if (t <= 0f || t >= 1f) {
                        alpha = 0f
                        return@graphicsLayer
                    }
                    // 出窍(前 30% 窗口):原位上浮 10dp、放大到 1.06、淡入到 0.75;
                    // 吸走(后 70%):suck 取平方 = 起步慢、越来越快的吸力。
                    val rise = (t / 0.3f).coerceAtMost(1f)
                    val suckLinear = ((t - 0.3f) / 0.7f).coerceIn(0f, 1f)
                    val suck = suckLinear * suckLinear
                    val sx = soul.bounds.center.x
                    val sy = soul.bounds.center.y - 10.dp.toPx() * rise
                    val ex = flight.from.center.x
                    val ey = flight.from.center.y
                    translationX = sx + (ex - sx) * suck - size.width / 2f
                    translationY = sy + (ey - sy) * suck - size.height / 2f
                    val s = (1f + 0.06f * rise) * (1f - 0.85f * suck)
                    scaleX = s
                    scaleY = s
                    // 半透明的"魂体":出窍时淡入,被吸走途中再轻微变淡,吸入即灭(t=1 归零)。
                    alpha = 0.75f * rise * (1f - 0.3f * suck)
                }
                .clip(RoundedCornerShape(8.dp))
                .background(colors.accentBlue.copy(alpha = 0.4f))
        ) {
            soul.thumb?.let {
                Image(
                    bitmap = it,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize()
                )
            }
        }
    }

    // ---------- 第二幕:卡片摞吸入(打包完成后成形起飞)。----------
    Box(
        modifier = Modifier
            .size(44.dp)
            .graphicsLayer {
                val t = progress.value
                val sx = flight.from.center.x
                val sy = flight.from.center.y
                // 落点：胶囊容器右缘向内 28dp、垂直居中（即常驻胶囊身上）。
                val ex = (target?.right ?: sx) - 28.dp.toPx()
                val ey = target?.center?.y ?: sy
                // 弧高随行程自适应；短横程额外向左弯，且峰值不会飞出状态栏。
                val point = queueFlightBezierPoint(
                    progress = t,
                    start = Offset(sx, sy),
                    end = Offset(ex, ey),
                    liftBasePx = 36.dp.toPx(),
                    maxLiftPx = 90.dp.toPx(),
                    minApexYPx = 12.dp.toPx(),
                    maxBowPx = 52.dp.toPx(),
                    bowFadeDistancePx = 160.dp.toPx(),
                )
                translationX = point.x - size.width / 2f
                translationY = point.y - size.height / 2f
                // 出场"凝聚"微弹(0.7→1,占前 12% 行程,配合缓起的 easing 约有 200ms 成形感),
                // 随后一路收拢缩小。淡出窗口必须极窄(最后 6% 行程):它按路径参数走,
                // 长路径(从屏幕下方点单张)上稍宽的窗口就意味着残影在离胶囊几百像素的
                // 半空消失,看起来像"飞去了错误的位置";6% 配合加速曲线只有最后 ~25ms,
                // 肉眼可见地贴到胶囊上才灭,消失时机恰接胶囊弹跳。
                val appear = (t / 0.12f).coerceAtMost(1f)
                val s = (0.7f + 0.3f * appear) * (1f - 0.62f * t)
                scaleX = s
                scaleY = s
                alpha = appear * (if (t > 0.94f) (1f - t) / 0.06f else 1f)
            }
    ) {
        // 整组(count>1)= 三张错位叠影读作"一摞照片";单张(count==1)只有顶卡一张,
        // 正着飞、不倾斜——"这张照片"本人飞过去。顶卡放缩略图(整组取本次传输顺序
        // 第一张;白描边像相纸),未缓存时回退实色+图标。
        val layers = if (flight.count > 1) 3 else 1
        repeat(layers) { i ->
            val top = i == layers - 1
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .graphicsLayer {
                        if (layers > 1) {
                            rotationZ = (i - 1) * 9f
                            translationX = (i - 1) * 3.dp.toPx()
                            translationY = (1 - i) * 2.dp.toPx()
                        }
                    }
                    .clip(RoundedCornerShape(9.dp))
                    .background(
                        if (top && flight.topThumb == null) colors.accentBlue
                        else colors.accentBlue.copy(alpha = 0.35f)
                    )
                    .then(
                        if (top && flight.topThumb != null) {
                            Modifier.border(
                                1.dp, Color.White.copy(alpha = 0.8f), RoundedCornerShape(9.dp)
                            )
                        } else Modifier
                    )
            ) {
                if (top && flight.topThumb != null) {
                    Image(
                        bitmap = flight.topThumb,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize()
                    )
                }
            }
        }
        if (flight.topThumb == null) {
            Icon(
                Icons.Default.Photo,
                contentDescription = null,
                tint = colors.onAccent,
                modifier = Modifier
                    .size(20.dp)
                    .align(Alignment.Center)
            )
        }
    }
}
