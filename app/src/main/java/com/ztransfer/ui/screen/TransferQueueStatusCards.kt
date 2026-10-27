package com.ztransfer.ui.screen

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.snap
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Icon
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Downloading
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.theme.Motion
import com.ztransfer.ui.util.formatDuration
import com.ztransfer.ui.util.formatSpeed
import com.ztransfer.viewmodel.TransferTask
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.delay

/** Two permanent cards; task activity never changes their bounds or history's scroll position. */
@Composable
internal fun TransferQueueStatusGroup(
    presentation: TransferQueuePresentation,
    tasks: List<TransferTask>,
    transferViewModel: TransferViewModel,
    cardSheen: Brush,
    compact: Boolean,
    modifier: Modifier = Modifier,
) {
    BoxWithConstraints(modifier) {
        val density = LocalDensity.current
        val padding = if (maxWidth < 340.dp || compact) 8.dp else 10.dp
        val gap = 8.dp
        val downloadWeight = 0.55f
        val generationWeight = 1f - downloadWeight
        val generationWidth = (maxWidth - gap) * generationWeight - padding * 2
        // A filename and timer share a row when readable. Small windows/large fonts put the
        // timer underneath instead of shrinking text or cutting away the file number.
        // Budget for a three-digit badge, rather than changing row height whenever the
        // live count gains a digit. Wider counts can elide a name without moving the rows.
        val taskWidth = generationWidth - 38.dp * density.fontScale - 4.dp
        val stackedGenerationTime = taskWidth < 76.dp * density.fontScale
        val titleHeight = with(density) { MaterialTheme.typography.labelMedium.lineHeight.toDp() }
        val badgeHeight = with(density) { MaterialTheme.typography.labelLarge.lineHeight.toDp() + 4.dp }
        val detailHeight = with(density) {
            MaterialTheme.typography.labelSmall.lineHeight.toDp().coerceAtLeast(16.dp) + 4.dp
        }
        // Both cards share the same row centers. No thumbnail-sized header or separate
        // title font pushes one card's contents away from the other card's rhythm.
        val headerHeight = badgeHeight.coerceAtLeast(titleHeight).coerceAtLeast(detailHeight)
        val generationRowHeight = if (stackedGenerationTime) headerHeight + 2.dp + detailHeight
            else headerHeight
        val bodyHeight = generationRowHeight * 2 + 6.dp
        val cardHeight = padding * 2 + bodyHeight
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(gap)) {
            DownloadStatusCard(presentation, tasks, transferViewModel, cardSheen,
                padding, headerHeight, modifier = Modifier.weight(downloadWeight).height(cardHeight))
            GenerationStatusCard(presentation, tasks, cardSheen, padding, headerHeight, bodyHeight,
                generationRowHeight, stackedGenerationTime, modifier = Modifier.weight(generationWeight).height(cardHeight))
        }
    }
}

@Composable
private fun DownloadStatusCard(
    presentation: TransferQueuePresentation,
    tasks: List<TransferTask>,
    transferViewModel: TransferViewModel,
    cardSheen: Brush,
    padding: Dp,
    headerHeight: Dp,
    modifier: Modifier,
) {
    val colors = AppTheme.colors
    val liveProgress by transferViewModel.activeTransferProgress.collectAsState()
    val display = rememberQueueDownloadDisplay(tasks, presentation.downloadTask, liveProgress)
    val task = display.task
    // The briefly retained completion always uses its own final statistics, including the
    // first terminal frame before the display helper has entered its completion animation.
    val completed = if (display.completing) task else queueDownloadCompletedTask(
        task?.taskId, presentation.downloadTask, tasks,
    )
    val speed = queueSummarySpeed(task, completed, liveProgress, presentation.downloadState)
    QueueStatusSurface(
        modifier = modifier,
        tag = "queue_download_summary",
        accent = colors.accentBlue,
        running = task != null,
        cardSheen = cardSheen,
        progress = display.progress.takeIf { task != null },
        progressKey = task?.taskId,
    ) {
        Row(Modifier.fillMaxSize().padding(padding), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            AnimatedContent(
                targetState = task,
                contentKey = { it != null },
                modifier = Modifier.weight(1f).fillMaxHeight(),
                transitionSpec = {
                    fadeIn(tween(160)).togetherWith(fadeOut(tween(100)))
                        .using(SizeTransform(sizeAnimationSpec = { _, _ -> snap() }))
                },
                label = "summaryDownloadPresence",
            ) { shownTask ->
                if (shownTask == null) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        SummaryStateIcon(presentation.downloadState, generation = false)
                    }
                } else Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.SpaceBetween) {
                    Box(Modifier.fillMaxWidth().height(headerHeight), contentAlignment = Alignment.CenterStart) {
                        SummaryFilename(shownTask, Modifier.fillMaxWidth())
                    }
                    // Speed keeps its natural width; the size label uses the remaining room.
                    Row(Modifier.fillMaxWidth().height(headerHeight), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                        TransferInfoPill(transferTaskFileSizeText(shownTask), TransferCardPillTone.SIZE,
                            modifier = Modifier.weight(1f, fill = false).testTag("queue_download_size"),
                            compact = true)
                        // Numeric changes retain the shell; only availability fades.
                        AnimatedContent(
                            targetState = speed,
                            contentKey = { it != null },
                            transitionSpec = {
                                fadeIn(tween(140)).togetherWith(fadeOut(tween(100)))
                                    .using(SizeTransform(sizeAnimationSpec = { _, _ -> snap() }))
                            },
                            label = "summarySpeedPresence",
                        ) { shownSpeed ->
                            if (shownSpeed != null) TransferInfoPill(
                                text = formatSpeed(shownSpeed),
                                tone = TransferCardPillTone.SPEED,
                                modifier = Modifier.testTag("queue_download_speed"),
                                compact = true,
                                animatedValue = shownSpeed,
                            )
                        }
                    }
                }
            }
            QueueRemainingBadge(presentation.downloadRemaining, generation = false)
        }
    }
}

@Composable
private fun GenerationStatusCard(
    presentation: TransferQueuePresentation,
    tasks: List<TransferTask>,
    cardSheen: Brush,
    padding: Dp,
    headerHeight: Dp,
    bodyHeight: Dp,
    rowHeight: Dp,
    stackedTime: Boolean,
    modifier: Modifier,
) {
    QueueStatusSurface(
        modifier = modifier,
        tag = "queue_generation_summary",
        accent = AppTheme.colors.accentPurple,
        running = presentation.generationState == QueueActivityState.RUNNING,
        breathing = true,
        cardSheen = cardSheen,
    ) {
        Row(Modifier.fillMaxSize().padding(padding), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            AnimatedGenerationQueueRows(
                tasks = presentation.generationTasks,
                allTasks = tasks,
                rowHeight = rowHeight,
                idleHeight = bodyHeight,
                modifier = Modifier.weight(1f).height(bodyHeight),
                idleContent = {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        SummaryStateIcon(QueueActivityState.IDLE, generation = true)
                    }
                },
            ) { task, phase, rowModifier ->
                val completedLabel = stringResource(R.string.done)
                Box(rowModifier.testTag("queue_generation_task_${task.taskId}")) {
                    Box(Modifier.fillMaxSize().then(if (phase.completed) Modifier
                        .testTag("queue_generation_completed_${task.taskId}")
                        .semantics { stateDescription = completedLabel } else Modifier)) {
                        GenerationTaskRow(task, stackedTime, headerHeight, phase, Modifier.fillMaxSize())
                    }
                }
            }
            // Counts stay centered in the whole card while task rows keep their top anchor.
            QueueRemainingBadge(presentation.generationRemaining, generation = true)
        }
    }
}

@Composable
private fun GenerationTaskRow(task: TransferTask, stackedTime: Boolean, titleRowHeight: Dp, phase: GenerationRowPhase, modifier: Modifier) {
    val startedAt = task.frameGenerationStartedAtElapsedMs
    val successTint by animateFloatAsState(
        if (phase.completed) 1f else 0f,
        tween(110), label = "generationFilenameColor",
    )
    // Theme foreground/background must switch together; only successful completion blends.
    val nameColor = lerp(AppTheme.colors.onBackground, AppTheme.colors.statusConnected, successTint)
    // A separate clock follows each actual renderer, never waiting/preparation time. The
    // effect is local to this row and stops immediately when it leaves the current snapshot.
    var clock by remember(task.taskId, startedAt) { mutableLongStateOf(android.os.SystemClock.elapsedRealtime()) }
    LaunchedEffect(task.taskId, startedAt, phase.frozen) {
        if (startedAt != null && !phase.frozen) {
            while (true) {
                clock = android.os.SystemClock.elapsedRealtime()
                delay(200L)
            }
        }
    }
    val elapsed = task.frameGenerationElapsedMs?.takeIf { phase.frozen }
        ?: startedAt?.let { task.frameGenerationAccumulatedMs + (clock - it).coerceAtLeast(0L) }
    if (stackedTime) {
        Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Box(Modifier.fillMaxWidth().height(titleRowHeight), contentAlignment = Alignment.CenterStart) {
                SummaryFilename(task, Modifier.fillMaxWidth(), includeExtension = false, color = nameColor)
            }
            GenerationTime(elapsed)
        }
    } else {
        Row(modifier, verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            SummaryFilename(task, Modifier.weight(1f), includeExtension = false, color = nameColor)
            GenerationTime(elapsed)
        }
    }
}

@Composable
private fun GenerationTime(elapsed: Long?) {
    TransferInfoPill(text = elapsed?.let(::formatDuration).orEmpty(),
        tone = TransferCardPillTone.GENERATION_DURATION, waiting = elapsed == null, compact = true)
}

@Composable
private fun SummaryFilename(
    task: TransferTask,
    modifier: Modifier,
    includeExtension: Boolean = true,
    color: Color? = null,
) {
    val alpha = remember { Animatable(1f) }
    var previousId by remember { mutableLongStateOf(task.taskId) }
    LaunchedEffect(task.taskId) {
        if (previousId != task.taskId) {
            previousId = task.taskId
            alpha.snapTo(0.72f)
            alpha.animateTo(1f, tween(160))
        }
    }
    val name = task.file.fileName
    val displayedName = if (includeExtension) name else name.substringBeforeLast('.', name)
    TransferFileTitle(displayedName, cancelled = false,
        modifier = modifier.graphicsLayer { this.alpha = alpha.value }
            .clearAndSetSemantics { text = AnnotatedString(task.file.fileName) },
        style = MaterialTheme.typography.labelMedium, color = color)
}

/** Decorative state only: idle has no moving spinner and is never a second action button. */
@Composable
private fun SummaryStateIcon(state: QueueActivityState, generation: Boolean) {
    val description = stringResource(when (state) {
        QueueActivityState.PAUSED -> R.string.queue_summary_paused
        QueueActivityState.WAITING -> R.string.queue_focus_waiting_transfer
        else -> R.string.queue_summary_idle
    })
    val icon = when (state) {
        QueueActivityState.PAUSED -> TransferQueuePauseIcon
        QueueActivityState.WAITING -> Icons.Default.Schedule
        else -> if (generation) Icons.Default.AutoAwesome else Icons.Default.Downloading
    }
    Icon(icon, contentDescription = description, modifier = Modifier.size(24.dp),
        tint = AppTheme.colors.onSurfaceVariant.copy(alpha = if (state == QueueActivityState.IDLE) 0.48f else 0.76f))
}

@Composable
private fun QueueRemainingBadge(count: Int, generation: Boolean) {
    // Emit no layout node at zero, so the idle content fills the whole card and centers there.
    // Completion rows/progress keep their own lifetime; an empty count must not end them early.
    if (count <= 0) return
    val colors = AppTheme.colors
    val accent = if (generation) colors.accentPurple else colors.accentBlue
    val description = stringResource(if (generation) R.string.queue_summary_generation_remaining
        else R.string.queue_summary_download_remaining, count)
    Box(
        Modifier.clearAndSetSemantics {
                testTag = if (generation) "queue_generation_count" else "queue_download_count"
                contentDescription = description
            }
            .clip(RoundedCornerShape(50)).background(accent.copy(alpha = 0.09f))
            // Both parents anchor the badge at their trailing edge. Snap the inner digit
            // width and let this shell spring toward the left, keeping its right edge still.
            .animateContentSize(animationSpec = Motion.bouncy(), alignment = Alignment.CenterEnd)
            .widthIn(min = 26.dp).padding(horizontal = 6.dp, vertical = 2.dp),
        contentAlignment = Alignment.Center,
    ) {
        AnimatedQueuePillCount(count, accent, if (generation) "summaryGenerationCount" else "summaryDownloadCount")
    }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun QueueStatusSurface(
    modifier: Modifier,
    tag: String,
    accent: Color,
    running: Boolean,
    cardSheen: Brush,
    breathing: Boolean = false,
    progress: State<Float>? = null,
    progressKey: Long? = null,
    content: @Composable BoxScope.() -> Unit,
) {
    val colors = AppTheme.colors
    // Theme base and foreground switch together; animate activity tint only, otherwise a
    // light-to-dark switch briefly leaves bright text on the outgoing light container.
    val activityTint = animateFloatAsState(if (running) 0.09f else 0.035f,
        tween(220, easing = FastOutSlowInEasing), label = "${tag}Tint")
    val ambientAlpha = if (breathing) {
        val presence = animateFloatAsState(if (running) 1f else 0f, tween(220),
            label = "${tag}BreathingPresence")
        val keepBreathing by remember(running, presence) {
            derivedStateOf { running || presence.value > 0f }
        }
        val pulse = rememberAmbientBreathingAlpha(
            breathing = keepBreathing,
            restingAlpha = 0f,
            minAlpha = 0f,
            maxAlpha = 0.08f,
            durationMillis = 2_400,
            label = "${tag}Breathing",
        )
        remember(presence, pulse) { derivedStateOf { presence.value * pulse.value } }
    } else null
    val border = remember(colors) {
        Brush.verticalGradient(listOf(colors.glassSheen.copy(alpha = 0.32f), colors.cardHairline,
            Color.Black.copy(alpha = 0.08f)))
    }
    val shape = RoundedCornerShape(16.dp)
    Card(
        modifier = modifier.fillMaxWidth().testTag(tag).semantics {
            testTagsAsResourceId = true
            if (progress != null) progressBarRangeInfo = ProgressBarRangeInfo(progress.value, 0f..1f)
        }.shadow(6.dp, shape, clip = false, ambientColor = Color.Black.copy(alpha = 0.08f),
            spotColor = Color.Black.copy(alpha = 0.12f)),
        shape = shape,
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
        border = BorderStroke(1.dp, border),
        colors = CardDefaults.cardColors(containerColor = Color.Transparent),
    ) {
        Box(Modifier.fillMaxSize().drawBehind {
            // Read activity color in drawing, like the progress and breathing layers. Fast
            // task handoffs no longer recompose the card's text/layout on every tint frame.
            drawRect(lerp(colors.surface, accent, activityTint.value))
            drawRect(cardSheen)
            // Only the surface breathes. Filenames, timers, layout and transfer work stay still;
            // the loop ends after the exit fade or when this list item leaves composition.
            ambientAlpha?.value?.takeIf { it > 0f }?.let { drawRect(accent.copy(alpha = it)) }
        }) {
            if (progress != null) {
                LiquidProgressFill(progress = { progress.value }, waveEligible = true, seedKey = progressKey,
                    color = accent.copy(alpha = 0.10f), modifier = Modifier.matchParentSize(),
                    label = "summaryTransferWave")
            }
            content()
        }
    }
}
