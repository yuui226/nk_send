package com.ztransfer.ui.screen

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

internal enum class GenerationRowPhase(val completed: Boolean, val retiring: Boolean) {
    ACTIVE(completed = false, retiring = false),
    SUCCEEDED(completed = true, retiring = false),
    EXITING(completed = false, retiring = true),
    EXITING_SUCCESS(completed = true, retiring = true);

    val frozen: Boolean get() = this != ACTIVE
}

internal data class GenerationRowSnapshot(
    val task: TransferTask,
    val position: Int,
    val phase: GenerationRowPhase = GenerationRowPhase.ACTIVE,
)

private const val VISIBLE_GENERATION_ROWS = 2
private const val PREPARED_GENERATION_ROWS = VISIBLE_GENERATION_ROWS + 1

/** A terminal download or a skipped effect must never produce a green generation success. */
internal fun generationReallyCompleted(task: TransferTask?): Boolean = task != null &&
    task.status == TransferStatus.COMPLETED && !task.isGeneratingFrame &&
    task.frameGenerationElapsedMs != null && !task.frameGenerationSkipped &&
    task.frameGenerationError == null && task.error == null

/**
 * Follow the actual queue order, with at most three resident rows and two brief departures.
 * Success holds occupy their old slots until their animation advances; invisible jobs that
 * finish farther down the queue never accumulate as retrospective success animations.
 */
internal fun generationRowSnapshots(
    previous: List<GenerationRowSnapshot>,
    tasks: List<TransferTask>,
    allTasks: List<TransferTask> = tasks,
): List<GenerationRowSnapshot> {
    val previousIds = previous.mapTo(HashSet()) { it.task.taskId }
    val currentPrevious = HashMap<Long, TransferTask>()
    val queueHead = ArrayList<TransferTask>(PREPARED_GENERATION_ROWS)
    for (task in tasks) {
        if (!task.isGeneratingFrame) continue
        if (task.taskId in previousIds) currentPrevious[task.taskId] = task
        if (queueHead.size < PREPARED_GENERATION_ROWS && queueHead.none { it.taskId == task.taskId }) {
            queueHead.add(task)
        }
    }
    // Only the bounded old rows need terminal lookup; never create a map of the whole history.
    val finalTasks = HashMap<Long, TransferTask>()
    if (previousIds.isNotEmpty()) {
        for (task in allTasks) {
            if (task.taskId in previousIds) finalTasks[task.taskId] = task
            if (finalTasks.size == previousIds.size) break
        }
    }
    fun finalSnapshot(row: GenerationRowSnapshot): TransferTask =
        finalTasks[row.task.taskId]?.takeIf { it.frameGenerationElapsedMs != null } ?: row.task

    val holds = previous.mapNotNull { row ->
        val id = row.task.taskId
        if (row.phase.retiring || id in currentPrevious || row.position >= VISIBLE_GENERATION_ROWS) {
            null
        } else if (row.phase == GenerationRowPhase.SUCCEEDED) {
            // Metadata updates neither restart the hold nor change its frozen successful time.
            row.takeIf { finalTasks[id] == null || generationReallyCompleted(finalTasks[id]) }
        } else if (generationReallyCompleted(finalTasks[id])) {
            row.copy(task = finalSnapshot(row), phase = GenerationRowPhase.SUCCEEDED)
        } else null
    }.sortedBy { it.position }.take(VISIBLE_GENERATION_ROWS)
    val holdIds = holds.mapTo(HashSet()) { it.task.taskId }
    val current = queueHead.filterNot { it.taskId in holdIds }
        .take(PREPARED_GENERATION_ROWS - holds.size)
        .map { GenerationRowSnapshot(it, position = 0) }.toMutableList()
    val residentIds = current.mapTo(HashSet()) { it.task.taskId }.apply { addAll(holdIds) }
    val occupiedOldPositions = previous.filter {
        !it.phase.retiring && it.task.taskId in residentIds
    }.mapTo(HashSet()) { it.position }
    for (hold in holds) {
        // If an earlier row has begun exiting, a remaining green row moves up with its peers.
        val insertion = (0 until hold.position).count { it in occupiedOldPositions }
        current.add(insertion.coerceAtMost(current.size), hold)
    }
    val residentRows = current.mapIndexed { index, row -> row.copy(position = index) }
    val newlyRetiring = previous.filter {
        !it.phase.retiring && it.task.taskId !in residentIds && it.position < VISIBLE_GENERATION_ROWS
    }.map { row ->
        val keepGreen = row.phase.completed &&
            (finalTasks[row.task.taskId] == null || generationReallyCompleted(finalTasks[row.task.taskId]))
        row.copy(task = finalSnapshot(row), phase = if (keepGreen)
            GenerationRowPhase.EXITING_SUCCESS else GenerationRowPhase.EXITING)
    }
    val alreadyRetiring = previous.filter {
        it.phase.retiring && it.task.taskId !in residentIds
    }.map { row ->
        // A late final duration can replace a frozen live clock once; never keep ticking an exit.
        if (row.task.frameGenerationElapsedMs == null) row.copy(task = finalSnapshot(row)) else row
    }
    return (newlyRetiring + alreadyRetiring).take(VISIBLE_GENERATION_ROWS) + residentRows
}

/** Ignore stale animation callbacks after a task has been retried or its phase has advanced. */
internal fun finishGenerationRowPhase(
    rows: List<GenerationRowSnapshot>,
    taskId: Long,
    expected: GenerationRowPhase,
): List<GenerationRowSnapshot> = when {
    expected == GenerationRowPhase.SUCCEEDED -> rows.map {
        if (it.task.taskId == taskId && it.phase == expected)
            it.copy(phase = GenerationRowPhase.EXITING_SUCCESS) else it
    }
    expected.retiring -> rows.filterNot { it.task.taskId == taskId && it.phase == expected }
    else -> rows
}

/** A fixed two-row viewport. The third row is prepared below the clip for continuous upward motion. */
@Composable
internal fun AnimatedGenerationQueueRows(
    tasks: List<TransferTask>,
    allTasks: List<TransferTask>,
    rowHeight: Dp,
    modifier: Modifier = Modifier,
    rowGap: Dp = 6.dp,
    idleHeight: Dp = rowHeight,
    idleContent: @Composable () -> Unit,
    rowContent: @Composable (task: TransferTask, phase: GenerationRowPhase, modifier: Modifier) -> Unit,
) {
    var retainedRows by remember { mutableStateOf<List<GenerationRowSnapshot>>(emptyList()) }
    val rows = generationRowSnapshots(retainedRows, tasks, allTasks)
    SideEffect {
        if (retainedRows != rows) retainedRows = rows
    }
    Box(modifier.clipToBounds()) {
        AnimatedVisibility(
            visible = rows.isEmpty(),
            modifier = Modifier.align(Alignment.TopStart).fillMaxWidth().height(idleHeight)
                .then(if (rows.isNotEmpty()) Modifier.clearAndSetSemantics { } else Modifier),
            enter = fadeIn(tween(160)),
            exit = fadeOut(tween(100)),
        ) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.CenterStart) { idleContent() }
        }
        rows.forEach { row ->
            key(row.task.taskId) {
                AnimatedGenerationRow(
                    row = row,
                    rowHeight = rowHeight,
                    rowGap = rowGap,
                    onPhaseFinished = { id, phase ->
                        retainedRows = finishGenerationRowPhase(retainedRows, id, phase)
                    },
                    rowContent = rowContent,
                )
            }
        }
    }
}

@Composable
private fun AnimatedGenerationRow(
    row: GenerationRowSnapshot,
    rowHeight: Dp,
    rowGap: Dp,
    onPhaseFinished: (Long, GenerationRowPhase) -> Unit,
    rowContent: @Composable (TransferTask, GenerationRowPhase, Modifier) -> Unit,
) {
    val stride = rowHeight + rowGap
    val baseTop = stride * row.position
    val top = remember { Animatable((baseTop + stride).value) }
    val alpha = remember { Animatable(0f) }
    val latestOnPhaseFinished by rememberUpdatedState(onPhaseFinished)
    // A lower row must not pass through a still-running first row on its way out.
    val exitTravel = if (row.position == 0) stride else minOf(rowGap, 6.dp)
    val targetTop = if (row.phase.retiring) baseTop - exitTravel else baseTop
    LaunchedEffect(targetTop) {
        top.animateTo(targetTop.value, tween(180, easing = FastOutSlowInEasing))
    }
    LaunchedEffect(row.phase) {
        when {
            row.phase == GenerationRowPhase.SUCCEEDED -> {
                coroutineScope {
                    launch { alpha.animateTo(1f, tween(60)) }
                    // An animation clock respects Android's duration scale, including zero.
                    Animatable(0f).animateTo(1f, tween(220))
                }
                latestOnPhaseFinished(row.task.taskId, row.phase)
            }
            row.phase.retiring -> {
                alpha.animateTo(0f, tween(140))
                latestOnPhaseFinished(row.task.taskId, row.phase)
            }
            else -> alpha.animateTo(1f, tween(180))
        }
    }
    Box(
        Modifier.offset { IntOffset(0, top.value.dp.roundToPx()) }
            .graphicsLayer { this.alpha = alpha.value }
            .fillMaxWidth().height(rowHeight)
            .then(if (row.phase.retiring || row.position >= VISIBLE_GENERATION_ROWS)
                Modifier.clearAndSetSemantics { } else Modifier),
    ) {
        rowContent(row.task, row.phase, Modifier.fillMaxSize())
    }
}
