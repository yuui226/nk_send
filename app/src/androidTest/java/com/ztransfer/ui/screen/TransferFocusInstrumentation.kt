package com.ztransfer.ui.screen

import android.app.Activity
import android.app.Instrumentation
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Bundle
import android.os.SystemClock
import android.view.KeyEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import com.ztransfer.MainActivity
import com.ztransfer.Screen
import com.ztransfer.SharedQueueControls
import com.ztransfer.R
import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.ui.theme.ThemeMode
import com.ztransfer.ui.theme.ZTransferTheme
import com.ztransfer.viewmodel.ActiveTransferProgress
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferState
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import com.ztransfer.viewmodel.TransferViewModel
import com.ztransfer.viewmodel.SavedOriginalOutput
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collect
import java.io.File
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.roundToInt

/** Emulator-only presentation checks. No queue execution, camera connection, or preference writes. */
class TransferFocusInstrumentation : Instrumentation() {
    private companion object {
        const val DOWNLOAD_CARD = "queue_download_summary"
        const val GENERATION_CARD = "queue_generation_summary"
        const val DOWNLOAD_COUNT = "queue_download_count"
        const val GENERATION_COUNT = "queue_generation_count"
        const val DOWNLOAD_SPEED = "queue_download_speed"
        const val DOWNLOAD_SIZE = "queue_download_size"
        const val GENERATION_TASK_PREFIX = "queue_generation_task_"
        const val GENERATION_COMPLETED_PREFIX = "queue_generation_completed_"
        const val HISTORY_LIST = "queue_history_list"
        const val SHARED_EXECUTION = "shared_queue_execution"
        const val SHARED_PILL = "shared_queue_pill"
        val durationPattern = Regex("\\d+(?:\\.\\d+)?s|\\d+m\\d+s")
    }

    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val report = Bundle()
        val store = ViewModelStore()
        var activity: MainActivity? = null
        var result = Activity.RESULT_CANCELED
        try {
            uiAutomation.serviceInfo = uiAutomation.serviceInfo.apply {
                flags = flags or AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                    AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
            }
            val monitor = addMonitor(MainActivity::class.java.name, null, false)
            targetContext.startActivity(Intent(targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            activity = checkNotNull(waitForMonitorWithTimeout(monitor, 10_000)) as MainActivity
            removeMonitor(monitor)
            val host = checkNotNull(activity)
            lateinit var transfer: TransferViewModel
            lateinit var camera: CameraViewModel
            val theme = mutableStateOf(ThemeMode.LIGHT)
            val route = mutableStateOf(Screen.Transfer.route)
            val heightOverride = mutableStateOf<Int?>(null)
            val animateDownloadProbe = mutableStateOf(true)
            val measuredPaneHeight = AtomicInteger()
            val sharedControlsAnchorRight = AtomicInteger()
            val downloadProbe = AtomicReference<QueueDownloadDisplay>()
            val probeRevision = AtomicLong(-1)
            val probeFrames = Collections.synchronizedList(ArrayList<DownloadProbeFrame>())
            runOnMainSync {
                val provider = ViewModelProvider(store, ViewModelProvider.AndroidViewModelFactory.getInstance(host.application))
                transfer = provider[TransferViewModel::class.java]
                camera = provider[CameraViewModel::class.java]
                host.setContent {
                    ZTransferTheme(themeMode = theme.value) {
                        ObserveDownloadDisplay(transfer, downloadProbe, probeRevision, probeFrames,
                            animate = animateDownloadProbe.value)
                        val density = LocalDensity.current
                        val constrainedHeight = heightOverride.value
                        CompositionLocalProvider(LocalDensity provides Density(density.density,
                            fontScale = if (constrainedHeight != null) 1.2f else density.fontScale)) {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            val paneModifier = if (constrainedHeight != null)
                                Modifier.width(300.dp).height(constrainedHeight.dp) else Modifier.fillMaxSize()
                            Box(paneModifier.onSizeChanged { measuredPaneHeight.set(it.height) }) {
                                TransferScreen(transfer, camera, 0L, false, {})
                                SharedQueueControls(
                                    route = route.value,
                                    transferViewModel = transfer,
                                    cameraViewModel = camera,
                                    heldCount = 0,
                                    catchNonce = 0L,
                                    filePreviewVisible = false,
                                    visibilityAlpha = { 1f },
                                    onBoundsChanged = { sharedControlsAnchorRight.set(it.right.roundToInt()) },
                                    onNavigateToTransfer = {},
                                    onControlAction = {},
                                )
                            }
                        }
                        }
                    }
                }
            }
            @Suppress("UNCHECKED_CAST")
            val state = TransferViewModel::class.java.getDeclaredField("_state").apply { isAccessible = true }
                .get(transfer) as MutableStateFlow<TransferState>
            @Suppress("UNCHECKED_CAST")
            val progress = TransferViewModel::class.java.getDeclaredField("_activeTransferProgress").apply { isAccessible = true }
                .get(transfer) as MutableStateFlow<ActiveTransferProgress?>
            fun publish(
                tasks: List<TransferTask>,
                transferring: Boolean,
                active: ActiveTransferProgress? = null,
                pauseAfterCurrent: Boolean = false,
            ) {
                runOnMainSync {
                    progress.value = active
                    state.value = state.value.copy(tasks = tasks, isTransferring = transferring,
                        pauseAfterCurrent = pauseAfterCurrent,
                        taskStructureRevision = state.value.taskStructureRevision + 1)
                }
            }
            fun awaitProbe(message: String, stableMs: Long = 0, condition: (QueueDownloadDisplay) -> Boolean) {
                val revision = state.value.taskStructureRevision
                val deadline = SystemClock.uptimeMillis() + 2000
                var stableSince: Long? = null
                do {
                    val now = SystemClock.uptimeMillis()
                    val display = downloadProbe.get()
                    if (probeRevision.get() >= revision && display != null && condition(display)) {
                        if (stableSince == null) stableSince = now
                        if (now - stableSince >= stableMs) return
                    } else stableSince = null
                    SystemClock.sleep(5)
                } while (SystemClock.uptimeMillis() < deadline)
                error(message)
            }
            fun recordedProbeFrames(): List<DownloadProbeFrame> = synchronized(probeFrames) { probeFrames.toList() }
            // MainActivity applies the user's language override; targetContext may use a different locale.
            val idle = host.getString(R.string.queue_summary_idle)
            val paused = host.getString(R.string.queue_summary_paused)
            val waitingGeneration = host.getString(R.string.status_waiting)
            fun awaitSummaries(downloads: Int, generations: Int) {
                awaitCondition("Summary counts do not match $downloads downloads / $generations generations", stableMs = 120) {
                    tagged(DOWNLOAD_CARD).size == 1 && tagged(GENERATION_CARD).size == 1 &&
                        tagged(DOWNLOAD_COUNT).singleOrNull()?.contentDescription?.toString() ==
                            host.getString(R.string.queue_summary_download_remaining, downloads) &&
                        tagged(GENERATION_COUNT).singleOrNull()?.contentDescription?.toString() ==
                            host.getString(R.string.queue_summary_generation_remaining, generations)
                }
                awaitCondition("Summary cards are not aligned side by side at 55:45", stableMs = 120) {
                    val download = tagged(DOWNLOAD_CARD).singleOrNull()?.let(::bounds)
                    val generation = tagged(GENERATION_CARD).singleOrNull()?.let(::bounds)
                    val downloadCount = tagged(DOWNLOAD_COUNT).singleOrNull()?.let(::bounds)
                    val generationCount = tagged(GENERATION_COUNT).singleOrNull()?.let(::bounds)
                    download != null && generation != null && download.right <= generation.left &&
                        abs(download.top - generation.top) <= 2 && abs(download.bottom - generation.bottom) <= 2 &&
                        downloadCount != null && generationCount != null &&
                        abs(downloadCount.centerY() - generationCount.centerY()) <= 1 &&
                        download.width() > generation.width() &&
                        download.width().toFloat() / (download.width() + generation.width()) in 0.545f..0.555f
                }
            }
            fun awaitSummaryText(tag: String, text: String) =
                awaitCondition("Missing $text in summary $tag") { summaryText(tag).contains(text) }

            // Both cards are present before any work exists, including two independent zero counts.
            publish(emptyList(), false)
            awaitSummaries(0, 0)
            awaitSummaryText(DOWNLOAD_CARD, idle)
            awaitSummaryText(GENERATION_CARD, idle)
            awaitGenerationRows()
            screenshot("queue-summary-empty.png", darkBackground = false)

            // Digit-width changes grow inward from the fixed trailing edge. Sample the whole
            // transition without assuming monotonic width: the spring is allowed to overshoot.
            fun countTasks(count: Int): List<TransferTask> = (1..count).map {
                task(9000L + it, "WAIT_$it.JPG", TransferStatus.WAITING)
            } + (1..count).map {
                task(10000L + it, "DSC_${9414 + it}.JPG", TransferStatus.COMPLETED)
                    .copy(isGeneratingFrame = true)
            }
            publish(countTasks(9), false)
            awaitSummaries(9, 9)
            fun countRects() = listOf(DOWNLOAD_COUNT, GENERATION_COUNT).map {
                bounds(checkNotNull(tagged(it).singleOrNull()))
            }
            fun cardHeights() = listOf(DOWNLOAD_CARD, GENERATION_CARD).map {
                bounds(checkNotNull(tagged(it).singleOrNull())).height()
            }
            val countOrigins = countRects()
            val countCardHeights = cardHeights()
            fun sampleCountResize(count: Int): List<IntRange> {
                val startWidths = countRects().map { it.width() }
                publish(countTasks(count), false)
                val minimum = startWidths.toMutableList()
                val maximum = minimum.toMutableList()
                fun sampleRects(): List<Rect> {
                    val current = countRects()
                    current.forEachIndexed { index, rect ->
                        check(abs(rect.right - countOrigins[index].right) <= 1) {
                            "Count right edge moved during resize to $count: $current"
                        }
                        minimum[index] = minOf(minimum[index], rect.width())
                        maximum[index] = maxOf(maximum[index], rect.width())
                    }
                    check(cardHeights() == countCardHeights) { "Count digit changes resized the cards" }
                    return current
                }
                val deadline = SystemClock.uptimeMillis() + 3500
                var previousWidths: List<Int>? = null
                var stableSince: Long? = null
                var settled = false
                do {
                    val widths = sampleRects().map { it.width() }
                    val descriptionsReady =
                        tagged(DOWNLOAD_COUNT).singleOrNull()?.contentDescription?.toString() ==
                            host.getString(R.string.queue_summary_download_remaining, count) &&
                        tagged(GENERATION_COUNT).singleOrNull()?.contentDescription?.toString() ==
                            host.getString(R.string.queue_summary_generation_remaining, count)
                    val resized = widths.indices.all { abs(widths[it] - startWidths[it]) > 1 }
                    val now = SystemClock.uptimeMillis()
                    if (descriptionsReady && resized) {
                        if (stableSince == null || widths != previousWidths) stableSince = now
                        if (now - checkNotNull(stableSince) >= 200) {
                            settled = true
                            break
                        }
                    } else stableSince = null
                    previousWidths = widths
                    SystemClock.sleep(10)
                } while (SystemClock.uptimeMillis() < deadline)
                check(settled) { "Count resize to $count did not settle: $minimum / $maximum" }
                awaitSummaries(count, count)
                // Include the confirmed new layout, even if accessibility first exposed old bounds.
                sampleRects()
                return minimum.indices.map { minimum[it]..maximum[it] }
            }
            val growingRanges = sampleCountResize(120)
            awaitCondition("Three-digit counts did not widen inward") {
                countRects().withIndex().all { (index, rect) -> rect.width() > countOrigins[index].width() }
            }
            val wideCounts = countRects()
            val shrinkingRanges = sampleCountResize(9)
            awaitCondition("One-digit counts did not return to their original widths", stableMs = 120) {
                countRects().withIndex().all { (index, rect) ->
                    abs(rect.width() - countOrigins[index].width()) <= 1 &&
                        abs(rect.right - countOrigins[index].right) <= 1
                }
            }
            countOrigins.indices.forEach { index ->
                check(growingRanges[index].last > countOrigins[index].width() &&
                    shrinkingRanges[index].first < wideCounts[index].width()) {
                    "Count width did not expand and contract: $growingRanges / $shrinkingRanges"
                }
            }
            publish(emptyList(), false)
            awaitSummaries(0, 0)
            awaitGenerationRows()

            val history = (10L..21L).map { task(it, "HIST_$it.JPG", TransferStatus.COMPLETED) }
            val generation = task(1, "DSC_9415.JPG", TransferStatus.COMPLETED).copy(
                framePreset = PhotoFramePreset.MINIMAL, isGeneratingFrame = true,
                frameGenerationStartedAtElapsedMs = SystemClock.elapsedRealtime(), elapsedMs = 230,
                downloadMBps = 42f,
            )
            val pendingGeneration = task(2, "DSC_9416.JPG", TransferStatus.COMPLETED).copy(
                framePreset = PhotoFramePreset.MINIMAL, isGeneratingFrame = true,
            )
            val downloading = task(3, "TX_03.JPG", TransferStatus.TRANSFERING)
            val waitingDownload = task(4, "WAIT_04.JPG", TransferStatus.WAITING)
            val active = ActiveTransferProgress(3, .37f, 3_700_000, 42L * 1024 * 1024)
            val initial = listOf(generation, pendingGeneration, downloading, waitingDownload) + history
            publish(initial, true, active)
            awaitSummaries(2, 2)
            awaitSummaryText(DOWNLOAD_CARD, "TX_03.JPG")
            awaitDownloadProgress(.37f)
            awaitSummaryText(DOWNLOAD_CARD, "42.0 MB/s")
            awaitSummaryText(GENERATION_CARD, "DSC_9415.JPG")
            awaitGenerationRows(1, 2)
            awaitCondition("One-running/one-waiting generation rows have incorrect clocks") {
                durationPattern.containsMatchIn(summaryText("${GENERATION_TASK_PREFIX}1")) &&
                    !durationPattern.containsMatchIn(summaryText("${GENERATION_TASK_PREFIX}2")) &&
                    summaryText("${GENERATION_TASK_PREFIX}2").contains(waitingGeneration)
            }
            check(!summaryText(GENERATION_CARD).contains(host.getString(R.string.photo_frame_minimal))) {
                "Generation summary still displays effect parameters"
            }
            check(!summaryText(GENERATION_CARD).contains("TX_03.JPG")) { "Download leaked into generation summary" }
            check(!summaryText(DOWNLOAD_CARD).contains("DSC_9415.JPG")) { "Generation leaked into download summary" }

            // Exercise the real shared controls without clicking Start/Pause or executing work.
            // Visibility can precede the execution button's entry spring settling. Measure the
            // baseline only after its right edge reaches the independent fixed TopEnd anchor.
            awaitCondition("Transfer route did not retain only its execution control", stableMs = 120) {
                val execution = tagged(SHARED_EXECUTION).singleOrNull()?.let(::bounds)
                val anchorRight = sharedControlsAnchorRight.get()
                execution != null && tagged(SHARED_PILL).isEmpty() && anchorRight > 0 &&
                    abs(execution.right - anchorRight) <= 2
            }
            val transferExecutionRight = bounds(checkNotNull(tagged(SHARED_EXECUTION).singleOrNull())).right
            runOnMainSync { route.value = Screen.Files.route }
            awaitCondition("Files route did not show both queue controls", stableMs = 120) {
                val execution = tagged(SHARED_EXECUTION).singleOrNull()?.let(::bounds)
                val pill = tagged(SHARED_PILL).singleOrNull()?.let(::bounds)
                execution != null && pill != null && execution.right < transferExecutionRight &&
                    execution.right <= pill.left
            }
            val filesExecutionRight = bounds(checkNotNull(tagged(SHARED_EXECUTION).singleOrNull())).right
            val retainedPillNode = checkNotNull(tagged(SHARED_PILL).singleOrNull())
            val retainedPillDebug = accessibilityNodeDebug(retainedPillNode)
            // A count-only Surface can be narrower than its 48dp accessibility touch target,
            // whose expanded bounds extend past the visual edge. The custom execution control
            // on Transfer shares the exact TopEnd anchor without that minimum-touch expansion.
            val filesPillRight = transferExecutionRight
            runOnMainSync { route.value = Screen.Transfer.route }
            val returningMessage = "Returning to Transfer did not hide the pill and move execution to the right"
            var returningDiagnostics = "No return-transition sample recorded"
            try {
                awaitCondition(returningMessage, stableMs = 120) {
                    val executions = tagged(SHARED_EXECUTION)
                    val execution = executions.singleOrNull()?.let(::bounds)
                    val pills = tagged(SHARED_PILL)
                    returningDiagnostics = "initialRight=$transferExecutionRight, filesRight=$filesExecutionRight, " +
                        "currentRight=${execution?.right}, anchorRight=${sharedControlsAnchorRight.get()}, " +
                        "executionCount=${executions.size}, pillCount=${pills.size}, executionBounds=$execution"
                    pills.isEmpty() && execution != null && execution.right > filesExecutionRight &&
                        abs(execution.right - transferExecutionRight) <= 2
                }
            } catch (error: Throwable) {
                throw IllegalStateException("$returningMessage; $returningDiagnostics", error)
            }

            // Hidden is a zero-width state of the same capsule. New data must stay current
            // without reopening it, and reopening must not create a fresh capsule instance.
            val hiddenUpdate = active.copy(bytesPerSecond = 21L * 1024 * 1024,
                retainedBytesPerSecond = 21L * 1024 * 1024)
            publish(initial + task(7, "WAIT_07.JPG", TransferStatus.WAITING), true, hiddenUpdate)
            awaitCondition("A hidden queue update reopened the capsule or shifted execution", stableMs = 120) {
                val execution = tagged(SHARED_EXECUTION).singleOrNull()?.let(::bounds)
                tagged(SHARED_PILL).isEmpty() && execution != null &&
                    abs(execution.right - transferExecutionRight) <= 2
            }
            runOnMainSync { route.value = Screen.Files.route }
            var restoredPillDiagnostics = "No restored-pill sample recorded"
            fun restoredPillIsCurrent(): Boolean {
                val pills = tagged(SHARED_PILL)
                val executions = tagged(SHARED_EXECUTION)
                val pill = pills.singleOrNull()
                val pillBounds = pill?.let(::bounds)
                val execution = executions.singleOrNull()?.let(::bounds)
                val content = summaryText(SHARED_PILL)
                val sameNode = pill != null && pill == retainedPillNode
                val executionBeforePill = execution != null && pillBounds != null && execution.right <= pillBounds.left
                val fixedRight = pillBounds != null && abs(pillBounds.right - filesPillRight) <= 2
                val speedCurrent = content.contains("21.0 MB/s")
                val countCurrent = Regex("(?:^|\\s|,)3(?:$|\\s|,)").containsMatchIn(content)
                restoredPillDiagnostics = "singlePill=${pills.size == 1}, sameNode=$sameNode, " +
                    "singleExecution=${executions.size == 1}, executionBeforePill=$executionBeforePill, " +
                    "fixedRight=$fixedRight, speedCurrent=$speedCurrent, countCurrent=$countCurrent; " +
                    "pillBounds=$pillBounds, originRight=$filesPillRight, currentRight=${pillBounds?.right}, " +
                    "rightDelta=${pillBounds?.right?.minus(filesPillRight)}, executionBounds=$execution, " +
                    "originalExecutionRight=$filesExecutionRight, transferExecutionRight=$transferExecutionRight; " +
                    "content=${content.replace("\n", "\\n")}; retained={$retainedPillDebug}; " +
                    "current=${pills.map(::accessibilityNodeDebug)}; " +
                    "executions=${executions.map(::accessibilityNodeDebug)}"
                return pill != null && sameNode && execution != null && executionBeforePill && fixedRight &&
                    speedCurrent && countCurrent
            }
            fun awaitRestoredPill(message: String, stableMs: Long) {
                try {
                    awaitCondition(message, stableMs, ::restoredPillIsCurrent)
                } catch (error: Throwable) {
                    throw IllegalStateException("$message; $restoredPillDiagnostics", error)
                }
            }
            awaitRestoredPill("Reopened capsule lost its identity or hidden updates", stableMs = 120)

            // Reverse the width spring before it settles; only one pill/control may survive.
            runOnMainSync { route.value = Screen.Transfer.route }
            SystemClock.sleep(80)
            runOnMainSync { route.value = Screen.Files.route }
            awaitRestoredPill("Rapid route reversal left stale or duplicate queue controls", stableMs = 150)
            runOnMainSync { route.value = Screen.Transfer.route }
            awaitCondition("Capsule did not finish collapsing after rapid reversal", stableMs = 120) {
                val execution = tagged(SHARED_EXECUTION).singleOrNull()?.let(::bounds)
                tagged(SHARED_PILL).isEmpty() && execution != null &&
                    abs(execution.right - transferExecutionRight) <= 2
            }
            publish(initial, true, active)
            awaitSummaries(2, 2)

            // The summary group is the first list item, not a pinned overlay. Scroll the actual
            // history and return it to the same origin before continuing the rendering scenarios.
            val originalHeaderTop = bounds(checkNotNull(tagged(DOWNLOAD_CARD).singleOrNull())).top
            val originalTaskIds = state.value.tasks.map { it.taskId }
            val historyList = checkNotNull(tagged(HISTORY_LIST).singleOrNull())
            check(historyList.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)) {
                "History list did not accept a forward scroll"
            }
            awaitCondition("Summary group remained pinned while history scrolled", stableMs = 120) {
                tagged(DOWNLOAD_CARD).singleOrNull()?.let { bounds(it).top < originalHeaderTop - 2 } ?: true
            }
            fun headerAtOriginalTop(): Boolean = tagged(DOWNLOAD_CARD).singleOrNull()?.let {
                abs(bounds(it).top - originalHeaderTop) <= 2
            } == true
            val returnDeadline = SystemClock.uptimeMillis() + 4000
            var nextBackwardScroll = 0L
            while (!headerAtOriginalTop() && SystemClock.uptimeMillis() < returnDeadline) {
                val now = SystemClock.uptimeMillis()
                if (now >= nextBackwardScroll) {
                    tagged(HISTORY_LIST).singleOrNull()?.performAction(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
                    nextBackwardScroll = now + 300
                }
                SystemClock.sleep(35)
            }
            awaitCondition("Summary group did not return to its original list position", stableMs = 120) {
                headerAtOriginalTop() && tagged(DOWNLOAD_CARD).size == 1 &&
                    tagged(GENERATION_CARD).size == 1 && tagged(HISTORY_LIST).size == 1
            }
            awaitText("HIST_21.JPG")
            check(state.value.tasks.map { it.taskId } == originalTaskIds) {
                "Scrolling the summary group changed or discarded history tasks"
            }

            val runningSecond = pendingGeneration.copy(frameGenerationStartedAtElapsedMs = SystemClock.elapsedRealtime() - 800)
            val twoRunning = initial.map { if (it.taskId == 2L) runningSecond else it }
            publish(twoRunning, true, active)
            awaitSummaries(2, 2)
            awaitGenerationRows(1, 2)
            awaitCondition("Two running generation rows did not both display elapsed time") {
                listOf(1L, 2L).all { durationPattern.containsMatchIn(summaryText("$GENERATION_TASK_PREFIX$it")) }
            }
            screenshot("queue-summary-light.png", darkBackground = false)
            runOnMainSync { theme.value = ThemeMode.DARK }
            screenshot("queue-summary-dark.png", darkBackground = true)

            // A surviving task keeps its node and moves into the vacated first row; newcomers
            // append beneath it rather than taking the old task's former position.
            val firstRowTop = bounds(checkNotNull(tagged("${GENERATION_TASK_PREFIX}1").singleOrNull())).top
            val survivingRow = checkNotNull(tagged("${GENERATION_TASK_PREFIX}2").singleOrNull())
            val survivingTop = bounds(survivingRow).top
            check(survivingTop > firstRowTop) { "Generation fixture does not have two distinct rows" }
            val newGeneration = task(5, "DSC_9417.JPG", TransferStatus.COMPLETED).copy(
                isGeneratingFrame = true, frameGenerationStartedAtElapsedMs = SystemClock.elapsedRealtime(),
            )
            val replacedFirst = twoRunning.map {
                if (it.taskId == 1L) it.copy(isGeneratingFrame = false, frameGenerationStartedAtElapsedMs = null,
                    frameGenerationElapsedMs = 1000) else it
            } + newGeneration
            publish(replacedFirst, true, active)
            awaitSummaries(2, 2)
            awaitGenerationRows(2, 5)
            awaitCondition("Surviving generation task was recreated or failed to move into the first row", stableMs = 200) {
                tagged("${GENERATION_TASK_PREFIX}2").singleOrNull()?.let {
                    it == survivingRow && abs(bounds(it).top - firstRowTop) <= 2 &&
                        bounds(it).top < survivingTop
                } == true
            }
            check(bounds(checkNotNull(tagged("${GENERATION_TASK_PREFIX}5").singleOrNull())).top > firstRowTop) {
                "New generation task did not append below the surviving first row"
            }
            publish(listOf(runningSecond, downloading, waitingDownload) + history, true, active)
            awaitSummaries(2, 1)
            awaitGenerationRows(2)
            awaitCondition("Completing the second row displaced or recreated the surviving first row", stableMs = 200) {
                tagged("${GENERATION_TASK_PREFIX}2").singleOrNull()?.let {
                    it == survivingRow && abs(bounds(it).top - firstRowTop) <= 2
                } == true
            }
            publish(listOf(downloading, waitingDownload) + history, true, active)
            awaitSummaries(2, 0)
            awaitGenerationRows()
            awaitSummaryText(GENERATION_CARD, idle)

            // Real admitted waiting work forms a two-row viewport. A completed head keeps its
            // final time briefly, then the next waiting row moves up and another candidate enters.
            val queuedFirst = task(80, "GEN_QUEUE_80.JPG", TransferStatus.COMPLETED).copy(
                isGeneratingFrame = true,
                frameGenerationStartedAtElapsedMs = SystemClock.elapsedRealtime() - 6000,
            )
            val queuedRest = (81L..83L).map { id ->
                task(id, "GEN_QUEUE_$id.JPG", TransferStatus.COMPLETED).copy(isGeneratingFrame = true)
            }
            var queueFixture = listOf(queuedFirst) + queuedRest
            publish(queueFixture + history, false)
            awaitSummaries(0, 4)
            awaitGenerationRows(80, 81)
            val queueCardHeight = bounds(checkNotNull(tagged(GENERATION_CARD).singleOrNull())).height()
            val queueFirstTop = bounds(checkNotNull(tagged("${GENERATION_TASK_PREFIX}80").singleOrNull())).top
            val queuedPeer = checkNotNull(tagged("${GENERATION_TASK_PREFIX}81").singleOrNull())
            val queueSecondTop = bounds(queuedPeer).top
            check(queueSecondTop > queueFirstTop) { "Generation queue fixture does not have two rows" }
            fun assertQueueHeight() {
                check(bounds(checkNotNull(tagged(GENERATION_CARD).singleOrNull())).height() == queueCardHeight) {
                    "Generation completion changed the fixed queue-card height"
                }
            }
            fun awaitCompletedRow(id: Long, finalTime: String) {
                // Observe the hold directly, before count/layout helpers spend its finite lifetime.
                awaitCondition("Successful generation $id did not retain its final time and completion marker") {
                    val root = uiAutomation.rootInActiveWindow
                    val row = tagged("$GENERATION_TASK_PREFIX$id", root).singleOrNull()
                    tagged("$GENERATION_COMPLETED_PREFIX$id", root).size == 1 && row != null &&
                        accessibilityText(row).contains(finalTime)
                }
                assertQueueHeight()
            }
            fun awaitRetirementWithoutSuccess(id: Long, vararg remainingIds: Long) {
                awaitCondition("Failed/cancelled generation $id did not retire correctly", stableMs = 150) {
                    check(tagged("$GENERATION_COMPLETED_PREFIX$id").isEmpty()) {
                        "Failed/cancelled generation $id was incorrectly marked successful"
                    }
                    assertQueueHeight()
                    val rows = generationRows()
                    val actualIds = rows.mapNotNull {
                        it.viewIdResourceName?.substringAfterLast('/')
                            ?.removePrefix(GENERATION_TASK_PREFIX)?.toLongOrNull()
                    }
                    rows.size == remainingIds.size && actualIds.toSet() == remainingIds.toSet()
                }
            }
            queueFixture = queueFixture.map { row ->
                if (row.taskId == 80L) row.copy(isGeneratingFrame = false,
                    frameGenerationStartedAtElapsedMs = null, frameGenerationElapsedMs = 2400) else row
            }
            publish(queueFixture + history, false)
            awaitCompletedRow(80, "2.4s")
            screenshot("queue-summary-generation-completed.png")
            awaitSummaries(0, 3)
            awaitGenerationRows(81, 82)
            awaitCondition("Completed head did not release its row for the waiting peer", stableMs = 120) {
                tagged("${GENERATION_TASK_PREFIX}81").singleOrNull()?.let {
                    it == queuedPeer && abs(bounds(it).top - queueFirstTop) <= 2
                } == true && tagged("${GENERATION_COMPLETED_PREFIX}80").isEmpty() &&
                    tagged("${GENERATION_TASK_PREFIX}82").singleOrNull()?.let {
                        abs(bounds(it).top - queueSecondTop) <= 2
                    } == true
            }
            assertQueueHeight()
            queueFixture = queueFixture.map { row ->
                if (row.taskId == 81L) row.copy(isGeneratingFrame = false,
                    frameGenerationStartedAtElapsedMs = null, frameGenerationElapsedMs = 900,
                    frameGenerationError = "Fixture generation failure") else row
            }
            publish(queueFixture + history, false)
            awaitRetirementWithoutSuccess(81, 82, 83)
            awaitSummaries(0, 2)
            queueFixture = queueFixture.map { row ->
                if (row.taskId == 82L) row.copy(status = TransferStatus.CANCELLED,
                    isGeneratingFrame = false, frameGenerationStartedAtElapsedMs = null,
                    frameGenerationElapsedMs = 700) else row
            }
            publish(queueFixture + history, false)
            awaitRetirementWithoutSuccess(82, 83)
            awaitSummaries(0, 1)
            awaitCondition("Last waiting generation row moved into the middle instead of the first position", stableMs = 120) {
                tagged("${GENERATION_TASK_PREFIX}83").singleOrNull()?.let {
                    abs(bounds(it).top - queueFirstTop) <= 2
                } == true
            }
            queueFixture = queueFixture.map { row ->
                if (row.taskId == 83L) row.copy(frameGenerationStartedAtElapsedMs =
                    SystemClock.elapsedRealtime() - 1000) else row
            }
            publish(queueFixture + history, false)
            awaitCondition("Last admitted generation did not show its running clock") {
                durationPattern.containsMatchIn(summaryText("${GENERATION_TASK_PREFIX}83"))
            }
            queueFixture = queueFixture.map { row ->
                if (row.taskId == 83L) row.copy(isGeneratingFrame = false,
                    frameGenerationStartedAtElapsedMs = null, frameGenerationElapsedMs = 5700) else row
            }
            publish(queueFixture + history, false)
            awaitCompletedRow(83, "5.7s")
            awaitSummaries(0, 0)
            awaitGenerationRows()
            awaitSummaryText(GENERATION_CARD, idle)
            check(tagged("${GENERATION_COMPLETED_PREFIX}83").isEmpty()) {
                "Last completed generation remained after the queue became idle"
            }
            assertQueueHeight()

            // Invoke the real clear APIs against the fake VM state. No transfer worker runs:
            // the publication between begin/finish deterministically models the 320ms race.
            val clearingCurrent = task(8200, "CLEAR_CURRENT.JPG", TransferStatus.TRANSFERING)
            val clearingWaiting = task(8201, "CLEAR_WAITING.JPG", TransferStatus.WAITING)
            val clearingGeneration = task(8202, "CLEAR_GENERATING.JPG", TransferStatus.COMPLETED).copy(
                isGeneratingFrame = true, frameGenerationStartedAtElapsedMs = SystemClock.elapsedRealtime(),
            )
            val clearingPrepared = task(8203, "CLEAR_PREPARED.JPG", TransferStatus.COMPLETED)
                .copy(isGeneratingFrame = true)
            val clearingFailed = task(8204, "CLEAR_FAILED.JPG", TransferStatus.FAILED)
            val individualWaiting = task(8205, "REMOVE_SINGLE.JPG", TransferStatus.WAITING)
            val clearingActive = ActiveTransferProgress(clearingCurrent.taskId, .4f,
                bytesPerSecond = 7L * 1024 * 1024, retainedBytesPerSecond = 7L * 1024 * 1024)
            publish(listOf(clearingCurrent, clearingWaiting, clearingGeneration, clearingPrepared,
                clearingFailed, individualWaiting), true, clearingActive)
            awaitSummaries(3, 2)
            runOnMainSync {
                check(!transfer.removeTask(clearingCurrent.taskId)) { "Single removal deleted an active download" }
                check(!transfer.removeTask(clearingGeneration.taskId)) { "Single removal deleted running generation" }
                check(!transfer.removeTask(clearingPrepared.taskId)) { "Single removal deleted admitted waiting generation" }
                transfer.withdrawTask(individualWaiting.taskId)
                check(state.value.tasks.single { it.taskId == individualWaiting.taskId }.status == TransferStatus.CANCELLED) {
                    "Single withdrawal did not cancel its selected waiting task"
                }
                check(transfer.removeTask(individualWaiting.taskId)) { "Single removal did not remove its withdrawn task" }
            }
            awaitSummaries(2, 2)
            var clearTargetIds = emptySet<Long>()
            runOnMainSync { clearTargetIds = transfer.beginClearQueue() }
            check(clearTargetIds == setOf(clearingWaiting.taskId, clearingFailed.taskId)) {
                "Batch clear did not capture only the original eligible targets: $clearTargetIds"
            }
            awaitSummaries(1, 2)
            awaitSummaryText(DOWNLOAD_CARD, "CLEAR_CURRENT.JPG")
            awaitDownloadProgress(.4f)
            val completedDuringClear = clearingCurrent.copy(status = TransferStatus.COMPLETED,
                progress = 1f, elapsedMs = 80, downloadMBps = 7f)
            val addedDuringClear = task(8206, "CLEAR_NEW_COMPLETED.JPG", TransferStatus.COMPLETED)
                .copy(progress = 1f, elapsedMs = 20, downloadMBps = 12f)
            publish(listOf(completedDuringClear, clearingWaiting.copy(status = TransferStatus.CANCELLED),
                clearingGeneration, clearingPrepared, clearingFailed, addedDuringClear), false)
            runOnMainSync { transfer.finishClearQueue(clearTargetIds) }
            check(state.value.tasks.map { it.taskId } == listOf(8200L, 8202L, 8203L, 8206L)) {
                "Clear cleanup removed the protected current/new task or retained an original target: " +
                    state.value.tasks.map { it.taskId }
            }
            awaitSummaries(0, 2)
            awaitGenerationRows(8202, 8203)
            awaitSummaryText(DOWNLOAD_CARD, idle)
            awaitDownloadProgress(null)
            awaitCondition("Clear cleanup left a speed label after all downloads ended", stableMs = 120) {
                tagged(DOWNLOAD_SPEED).isEmpty()
            }

            runOnMainSync { heightOverride.value = 360 }
            publish(twoRunning.map { task ->
                if (task.taskId == downloading.taskId) task.copy(file = task.file.copy(
                    fileName = "Very_long_camera_filename_20261026_123456789.JPG")) else task
            }, true, active)
            awaitSummaries(2, 2)
            awaitGenerationRows(1, 2)
            awaitDownloadProgress(.37f)
            screenshot("queue-summary-compact.png")
            runOnMainSync { heightOverride.value = null; theme.value = ThemeMode.LIGHT }

            // The summary supplements the full history; the active task is not removed from it.
            publish(listOf(downloading), true, active)
            awaitSummaries(1, 0)
            awaitCount("TX_03.JPG", expected = 2, timeoutMs = 2500)
            val downloadBottom = bounds(checkNotNull(tagged(DOWNLOAD_CARD).singleOrNull())).bottom
            check(nodes("TX_03.JPG").any { bounds(it).top > downloadBottom }) {
                "Active download is missing from the complete historical list"
            }

            // When only generation remains, the download count is zero and its speed label is absent.
            publish(listOf(generation, pendingGeneration) + history, false, active)
            awaitSummaries(0, 2)
            awaitSummaryText(DOWNLOAD_CARD, idle)
            awaitSummaryText(GENERATION_CARD, "DSC_9415.JPG")
            awaitCondition("Idle download summary kept stale data") {
                !summaryText(DOWNLOAD_CARD).contains("TX_03.JPG") &&
                    !summaryText(DOWNLOAD_CARD).contains("42.0 MB/s") && tagged(DOWNLOAD_SPEED).isEmpty()
            }
            awaitDownloadProgress(null)

            // A requested pause still shows the real current file, then stops presenting waiting files as active.
            publish(initial, true, active, pauseAfterCurrent = true)
            awaitSummaries(2, 2)
            awaitSummaryText(DOWNLOAD_CARD, "TX_03.JPG")
            val afterDownload = initial.map { if (it.taskId == downloading.taskId) it.copy(
                status = TransferStatus.COMPLETED, progress = 1f, elapsedMs = 300,
            ) else it }
            publish(afterDownload, true, pauseAfterCurrent = true)
            awaitSummaries(1, 2)
            awaitSummaryText(DOWNLOAD_CARD, paused)
            awaitSummaryText(GENERATION_CARD, "DSC_9415.JPG")
            awaitDownloadProgress(null)
            publish(afterDownload, false)
            awaitSummaries(1, 2)
            awaitSummaryText(DOWNLOAD_CARD, paused)
            awaitCondition("Paused download summary retained a speed label", stableMs = 120) {
                tagged(DOWNLOAD_SPEED).isEmpty()
            }

            // Waiting for generation never displays a running stopwatch or an active download count.
            publish(listOf(pendingGeneration) + history, false)
            awaitSummaries(0, 1)
            awaitGenerationRows(2)
            awaitSummaryText(GENERATION_CARD, waitingGeneration)
            awaitCondition("Generation waiting state displayed elapsed processing time") {
                !durationPattern.containsMatchIn(summaryText(GENERATION_CARD))
            }
            publish(listOf(generation.copy(status = TransferStatus.TRANSFERING)), false,
                ActiveTransferProgress(generation.taskId, .77f, bytesPerSecond = 99L * 1024 * 1024))
            awaitSummaries(0, 1)
            awaitSummaryText(DOWNLOAD_CARD, idle)
            awaitDownloadProgress(null)

            // The first file has no speed label until a sample exists. Subsequent files keep
            // the same shell and the previous sample until their own first sample arrives.
            val noSample = task(30, "TX_30.JPG", TransferStatus.TRANSFERING).copy(progress = .08f, speed = 0)
            publish(listOf(noSample) + history, true, ActiveTransferProgress(noSample.taskId, .08f,
                bytesPerSecond = 0, retainedBytesPerSecond = 0))
            awaitSummaries(1, 0)
            awaitSummaryText(DOWNLOAD_CARD, "TX_30.JPG")
            awaitDownloadProgress(.08f)
            awaitCondition("First unsampled download displayed a placeholder speed", stableMs = 120) {
                tagged(DOWNLOAD_SPEED).isEmpty() && !summaryText(DOWNLOAD_CARD).contains("B/s")
            }
            runOnMainSync {
                progress.value = ActiveTransferProgress(noSample.taskId, .25f,
                    bytesPerSecond = 42L * 1024 * 1024, retainedBytesPerSecond = 42L * 1024 * 1024)
            }
            awaitSummaryText(DOWNLOAD_SPEED, "42.0 MB/s")
            val retainedSpeedNode = checkNotNull(tagged(DOWNLOAD_SPEED).singleOrNull())
            val retainedSpeedLeft = bounds(retainedSpeedNode).left
            val nextUnsampled = task(31, "TX_31.JPG", TransferStatus.TRANSFERING).copy(progress = .08f)
            val previousCompleted = noSample.copy(status = TransferStatus.COMPLETED, progress = 1f,
                elapsedMs = 100, downloadMBps = 42f)
            publish(listOf(previousCompleted, nextUnsampled) + history, true,
                ActiveTransferProgress(nextUnsampled.taskId, .08f,
                    bytesPerSecond = 0, retainedBytesPerSecond = 42L * 1024 * 1024))
            awaitSummaries(1, 0)
            awaitSummaryText(DOWNLOAD_CARD, "TX_31.JPG")
            awaitDownloadProgress(.08f)
            awaitCondition("New file discarded the retained speed or rebuilt its shell", stableMs = 120) {
                val speedNode = tagged(DOWNLOAD_SPEED).singleOrNull()
                speedNode != null && speedNode == retainedSpeedNode &&
                    summaryText(DOWNLOAD_SPEED) == "42.0 MB/s"
            }
            awaitCondition("Download size does not precede the speed shell") {
                val sizeNode = tagged(DOWNLOAD_SIZE).singleOrNull()
                val speedNode = tagged(DOWNLOAD_SPEED).singleOrNull()
                sizeNode != null && speedNode != null && bounds(sizeNode).right <= bounds(speedNode).left
            }
            // Only the high-frequency stream changes here: the summary must not depend on a
            // coincidental task-list update to reveal the first valid speed sample.
            runOnMainSync {
                progress.value = ActiveTransferProgress(nextUnsampled.taskId, .25f,
                    bytesPerSecond = 9L * 1024 * 1024, retainedBytesPerSecond = 9L * 1024 * 1024)
            }
            awaitDownloadProgress(.25f)
            awaitSummaryText(DOWNLOAD_CARD, "9.0 MB/s")
            awaitCondition("Speed update replaced, duplicated or shifted its shell", stableMs = 120) {
                val speedNode = tagged(DOWNLOAD_SPEED).singleOrNull()
                speedNode != null && speedNode == retainedSpeedNode &&
                    bounds(speedNode).left == retainedSpeedLeft && summaryText(DOWNLOAD_SPEED) == "9.0 MB/s"
            }
            // Decimal-place, leading-digit and unit changes all retain a single shell and
            // expose only the latest complete value, never outgoing/incoming text duplicates.
            for ((sample, label) in listOf(
                (9.1 * 1024 * 1024).toLong() to "9.1 MB/s",
                (19.1 * 1024 * 1024).toLong() to "19.1 MB/s",
                800L * 1024 to "800.0 KB/s",
                (1.2 * 1024 * 1024).toLong() to "1.2 MB/s",
            )) {
                runOnMainSync {
                    progress.value = ActiveTransferProgress(nextUnsampled.taskId, .25f,
                        bytesPerSecond = sample, retainedBytesPerSecond = sample)
                }
                awaitCondition("Numeric/unit update duplicated, rebuilt or misstated the speed shell: $label", stableMs = 120) {
                    val speedNode = tagged(DOWNLOAD_SPEED).singleOrNull()
                    speedNode != null && speedNode == retainedSpeedNode && summaryText(DOWNLOAD_SPEED) == label
                }
            }

            // A mismatched high-frequency snapshot must never leak another file's progress or speed.
            val mismatch = task(40, "TX_40.JPG", TransferStatus.TRANSFERING).copy(progress = .12f)
            publish(listOf(mismatch) + history, true, ActiveTransferProgress(999, .93f, bytesPerSecond = 999L))
            awaitSummaries(1, 0)
            awaitDownloadProgress(.12f)
            check(!summaryText(DOWNLOAD_CARD).contains("999 B/s")) {
                "Another task's statistics leaked into download summary"
            }
            awaitCondition("Mismatched sample created a speed label for an unsampled file", stableMs = 120) {
                tagged(DOWNLOAD_SPEED).isEmpty()
            }

            // Fast transitions replace data in the same two cards, without accumulating outgoing cards.
            for (id in 50L..69L) {
                publish(listOf(task(id, "TX_$id.JPG", TransferStatus.TRANSFERING)) + history, true,
                    ActiveTransferProgress(id, .41f, bytesPerSecond = 17L * 1024 * 1024))
                SystemClock.sleep(25)
            }
            awaitSummaries(1, 0)
            awaitSummaryText(DOWNLOAD_CARD, "TX_69.JPG")
            awaitDownloadProgress(.41f)
            awaitSummaryText(DOWNLOAD_CARD, "17.0 MB/s")
            awaitCondition("An outgoing task remained in the download summary") {
                !summaryText(DOWNLOAD_CARD).contains("TX_68.JPG")
            }

            // A real completion may briefly finish its fill; afterward both permanent cards must
            // return to zero/idle with no stale task, speed, progress, or accumulated outgoing cards.
            val completedFast = task(69, "TX_69.JPG", TransferStatus.COMPLETED).copy(
                progress = 1f, elapsedMs = 240, downloadMBps = 17f,
            )
            publish(listOf(completedFast) + history, false)
            awaitSummaries(0, 0)
            awaitSummaryText(DOWNLOAD_CARD, idle)
            awaitSummaryText(GENERATION_CARD, idle)
            awaitDownloadProgress(null)
            awaitCondition("Completed download remained in the idle summary") {
                val content = summaryText(DOWNLOAD_CARD)
                !content.contains("TX_69.JPG") && !content.contains("17.0 MB/s") &&
                    tagged(DOWNLOAD_SPEED).isEmpty()
            }
            publish(emptyList(), false)
            awaitSummaries(0, 0)
            awaitAbsent("HIST_21.JPG", timeoutMs = 2500)

            // Observe the shared production helper directly: accessibility may miss its 40ms
            // full-fill frame. The independent probe uses the same fake VM inputs and frame clock.
            val observed = task(700, "OBSERVED_700.JPG", TransferStatus.TRANSFERING)
            publish(listOf(observed), true, ActiveTransferProgress(700, .15f))
            awaitProbe("Probe did not observe the original download at .15") {
                it.task?.taskId == 700L && !it.completing && abs(it.progress.value - .15f) < .005f
            }
            probeFrames.clear()
            val completedObserved = observed.copy(status = TransferStatus.COMPLETED, progress = 1f,
                elapsedMs = 120, downloadMBps = 20f)
            var handoffTasks = listOf(completedObserved, task(701, "NEXT_701.JPG", TransferStatus.TRANSFERING))
            publish(handoffTasks, true, ActiveTransferProgress(701, .2f))
            awaitProbe("Successful observed download did not retain its identity while completing") {
                it.task?.taskId == 700L && it.completing
            }
            runOnMainSync {
                check(downloadProbe.get()?.let { it.task?.taskId == 700L && it.completing } == true) {
                    "Completion hold ended before the conflated-update fixture began"
                }
                // Publish the entire burst without yielding the main thread: host scheduling
                // between separate runOnMainSync calls must not let the 160ms hold finish.
                for (id in 702L..704L) {
                    handoffTasks = handoffTasks.map {
                        if (it.status == TransferStatus.TRANSFERING) it.copy(status = TransferStatus.COMPLETED,
                            progress = 1f, elapsedMs = 8) else it
                    } + task(id, "NEXT_$id.JPG", TransferStatus.TRANSFERING)
                    progress.value = ActiveTransferProgress(id, .2f)
                    state.value = state.value.copy(tasks = handoffTasks, isTransferring = true,
                        pauseAfterCurrent = false,
                        taskStructureRevision = state.value.taskStructureRevision + 1)
                }
            }
            awaitProbe("Successful completion never reached a visible full-fill frame") {
                recordedProbeFrames().any { frame -> frame.taskId == 700L && frame.completing && frame.progress >= .999f }
            }
            awaitProbe("Completion hold did not yield directly to the newest download") {
                it.task?.taskId == 704L && !it.completing && abs(it.progress.value - .2f) < .005f
            }
            val completionFrames = recordedProbeFrames()
            check(completionFrames.filter { it.completing }.all { it.taskId == 700L }) {
                "Unobserved intermediate files accumulated completion animations: $completionFrames"
            }
            check(completionFrames.firstOrNull { it.taskId != null && it.taskId != 700L }?.taskId == 704L) {
                "Completion replayed stale intermediate downloads: $completionFrames"
            }

            val failing = task(710, "FAIL_710.JPG", TransferStatus.TRANSFERING)
            publish(listOf(failing), true, ActiveTransferProgress(710, .2f))
            awaitProbe("Probe did not observe the failing download") {
                it.task?.taskId == 710L && !it.completing && abs(it.progress.value - .2f) < .005f
            }
            probeFrames.clear()
            publish(listOf(failing.copy(status = TransferStatus.FAILED, error = "Test failure")), false)
            awaitProbe("Failure incorrectly retained a successful completion", stableMs = 100) {
                it.task == null && !it.completing && it.progress.value == 0f
            }
            check(recordedProbeFrames().none { it.completing || it.progress > .3f }) {
                "A failed download falsely filled to completion"
            }
            probeFrames.clear()
            val generationOnly = task(720, "GEN_ONLY.JPG", TransferStatus.TRANSFERING).copy(
                isGeneratingFrame = true, frameGenerationStartedAtElapsedMs = SystemClock.elapsedRealtime(),
            )
            publish(listOf(generationOnly), false, ActiveTransferProgress(720, .9f))
            awaitProbe("Pure local generation created download progress", stableMs = 100) {
                it.task == null && !it.completing && it.progress.value == 0f
            }
            check(recordedProbeFrames().none { it.completing || it.taskId != null || it.progress != 0f }) {
                "Pure generation created a download completion animation"
            }

            // A fully hidden capsule still follows the latest owner and target, but must stop
            // both progress springs and successful-file holds until it becomes visible again.
            val hiddenOriginal = task(730, "HIDDEN_730.JPG", TransferStatus.TRANSFERING)
            publish(listOf(hiddenOriginal), true, ActiveTransferProgress(730, .1f))
            awaitProbe("Probe did not settle before the hidden-animation check") {
                it.task?.taskId == 730L && !it.animation.isRunning && abs(it.progress.value - .1f) < .005f
            }
            publish(listOf(hiddenOriginal), true, ActiveTransferProgress(730, .85f))
            awaitProbe("Visible progress did not start an animation before hiding") {
                it.task?.taskId == 730L && it.animation.isRunning
            }
            runOnMainSync { animateDownloadProbe.value = false }
            awaitProbe("Hiding did not cancel the progress spring and adopt its latest target", stableMs = 100) {
                it.task?.taskId == 730L && !it.completing && !it.animation.isRunning &&
                    abs(it.progress.value - .85f) < .005f
            }
            probeFrames.clear()
            publish(listOf(hiddenOriginal), true, ActiveTransferProgress(730, .95f))
            awaitProbe("Hidden progress did not follow an update without animating", stableMs = 80) {
                it.task?.taskId == 730L && !it.completing && !it.animation.isRunning &&
                    abs(it.progress.value - .95f) < .005f
            }
            var hiddenTasks = listOf(hiddenOriginal)
            for (id in 731L..733L) {
                hiddenTasks = hiddenTasks.map {
                    if (it.status == TransferStatus.TRANSFERING) it.copy(status = TransferStatus.COMPLETED,
                        progress = 1f, elapsedMs = 120) else it
                } + task(id, "HIDDEN_$id.JPG", TransferStatus.TRANSFERING)
                publish(hiddenTasks, true, ActiveTransferProgress(id, .25f))
                awaitProbe("Hidden owner $id was delayed by a completion hold or progress animation", stableMs = 80) {
                    it.task?.taskId == id && !it.completing && !it.animation.isRunning &&
                        abs(it.progress.value - .25f) < .005f
                }
            }
            publish(hiddenTasks.map { it.copy(status = TransferStatus.COMPLETED, progress = 1f) }, false)
            awaitProbe("A hidden terminal queue retained progress or an invisible completion", stableMs = 100) {
                it.task == null && !it.completing && !it.animation.isRunning && it.progress.value == 0f
            }
            check(recordedProbeFrames().none { it.completing || it.animationRunning }) {
                "The hidden download display ran animation work: ${recordedProbeFrames()}"
            }
            val resumed = task(734, "RESUMED_734.JPG", TransferStatus.TRANSFERING)
            publish(listOf(resumed), true, ActiveTransferProgress(734, .33f))
            awaitProbe("The hidden display did not adopt the owner to resume") {
                it.task?.taskId == 734L && !it.animation.isRunning && abs(it.progress.value - .33f) < .005f
            }
            probeFrames.clear()
            runOnMainSync { animateDownloadProbe.value = true }
            publish(listOf(resumed), true, ActiveTransferProgress(734, .8f))
            awaitProbe("The visible display did not resume progress from its latest hidden owner") {
                it.task?.taskId == 734L && !it.completing && !it.animation.isRunning &&
                    abs(it.progress.value - .8f) < .005f
            }
            val resumedFrames = recordedProbeFrames()
            check(resumedFrames.all { it.taskId == 734L && !it.completing && it.progress >= .329f } &&
                resumedFrames.any { it.animationRunning && it.progress > .335f && it.progress < .795f }) {
                "Resuming replayed an old file/reset or skipped its visible animation: $resumedFrames"
            }
            publish(emptyList(), false)
            awaitSummaries(0, 0)

            // Both action buttons remain below both summaries at 360dp and at the old 420dp
            // compact-layout boundary. Both constrained sizes use 1.2 font scale.
            runOnMainSync { heightOverride.value = 360 }
            val failed = task(400, "FAILED_400.JPG", TransferStatus.FAILED).copy(
                error = "Test failure",
                savedOriginalOutput = SavedOriginalOutput("content://test/source", "content://test/tree",
                    "content://test/parent", "FAILED_400.JPG"),
            )
            val compactTasks = listOf(generation, pendingGeneration, failed) + history
            publish(compactTasks, false)
            awaitSummaries(0, 2)
            awaitSummaryText(GENERATION_CARD, "DSC_9415.JPG")
            val clearDescription = host.getString(R.string.cd_clear_queue)
            val retryDescription = host.getString(R.string.cd_retry_failed)
            for (height in listOf(360, 420)) {
                runOnMainSync { heightOverride.value = height }
                val expectedHeightPx = (height * host.resources.displayMetrics.density).roundToInt()
                awaitCondition("Test pane did not reach ${height}dp") {
                    abs(measuredPaneHeight.get() - expectedHeightPx) <= 1
                }
                awaitCondition("${height}dp actions overlap the summaries", stableMs = 250) {
                    val clearBounds = clickableBounds(clearDescription)
                    val retryBounds = clickableBounds(retryDescription)
                    val downloadBounds = tagged(DOWNLOAD_CARD).singleOrNull()?.let(::bounds)
                    val generationBounds = tagged(GENERATION_CARD).singleOrNull()?.let(::bounds)
                    val summaryBottom = if (downloadBounds != null && generationBounds != null)
                        maxOf(downloadBounds.bottom, generationBounds.bottom) else null
                    clearBounds != null && retryBounds != null && summaryBottom != null &&
                        clearBounds.top >= summaryBottom && retryBounds.top >= summaryBottom &&
                        !Rect.intersects(clearBounds, retryBounds) &&
                        (height != 360 || abs(clearBounds.centerY() - retryBounds.centerY()) <= 3)
                }
                screenshot(if (height == 360) "queue-summary-compact-actions.png" else "queue-summary-420-actions.png")
            }
            check(checkNotNull(clickableNode(clearDescription)).performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                "Clear confirmation did not open"
            }
            val clearTitle = host.getString(R.string.clear_queue_title)
            awaitText(clearTitle)
            sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            awaitAbsent(clearTitle, timeoutMs = 2500)
            check(state.value.tasks.map { it.taskId } == compactTasks.map { it.taskId }) {
                "Back from clear confirmation modified the queue"
            }
            publish(emptyList(), false)
            awaitSummaries(0, 0)
            awaitSummaryText(DOWNLOAD_CARD, idle)
            awaitSummaryText(GENERATION_CARD, idle)
            awaitAbsent("DSC_9415.JPG", timeoutMs = 2500)

            // Completion feedback belongs to the observed batch, rather than every terminal
            // task still kept in history. Exercise the actual Files-route controls here.
            runOnMainSync {
                heightOverride.value = null
                route.value = Screen.Files.route
            }
            fun doneIsVisible() = summaryText(SHARED_PILL).lineSequence().any { it == "Done" }
            fun assertNoDoneFor(message: String, durationMs: Long) {
                val deadline = SystemClock.uptimeMillis() + durationMs
                do {
                    check(!doneIsVisible()) { message }
                    SystemClock.sleep(35)
                } while (SystemClock.uptimeMillis() < deadline)
            }
            val batchFailure = task(800, "BATCH_FAIL_800.JPG", TransferStatus.TRANSFERING)
            publish(listOf(batchFailure), true, ActiveTransferProgress(800, .2f))
            awaitCondition("Files controls did not observe the batch that will fail", stableMs = 120) {
                tagged(SHARED_EXECUTION).size == 1 && tagged(SHARED_PILL).size == 1 && !doneIsVisible()
            }
            val failedHistory = batchFailure.copy(status = TransferStatus.FAILED, error = "Test failure")
            publish(listOf(failedHistory), false)
            assertNoDoneFor("A failed batch displayed successful Done feedback", durationMs = 2100)
            awaitCondition("Failed batch retained its execution control", stableMs = 100) {
                tagged(SHARED_EXECUTION).isEmpty()
            }

            // A fast failure may first reach the UI as terminal; it still belongs to the
            // observed batch even when no WAITING/TRANSFERING snapshot for that file arrived.
            val coalescedActive = task(802, "COALESCED_ACTIVE.JPG", TransferStatus.TRANSFERING)
            publish(listOf(failedHistory, coalescedActive), true, ActiveTransferProgress(802, .2f))
            awaitCondition("Files controls did not observe the batch before its coalesced failure", stableMs = 120) {
                tagged(SHARED_EXECUTION).size == 1 && tagged(SHARED_PILL).size == 1 && !doneIsVisible()
            }
            val coalescedFailure = task(803, "COALESCED_FAILED.JPG", TransferStatus.FAILED)
                .copy(error = "Fast test failure")
            publish(listOf(failedHistory, coalescedActive, coalescedFailure), true,
                ActiveTransferProgress(802, .2f))
            awaitProbe("The coalesced-failure snapshot did not reach the controls fixture") {
                it.task?.taskId == 802L && !it.completing
            }
            publish(listOf(failedHistory, coalescedActive.copy(status = TransferStatus.COMPLETED,
                progress = 1f, elapsedMs = 120), coalescedFailure), false)
            assertNoDoneFor("An already-failed new task was omitted from batch completion feedback", durationMs = 350)
            awaitCondition("Coalesced-failure batch did not settle without Done", stableMs = 100) {
                tagged(SHARED_EXECUTION).isEmpty() && !doneIsVisible()
            }

            val nextBatch = task(801, "NEXT_BATCH_801.JPG", TransferStatus.TRANSFERING)
            publish(listOf(failedHistory, nextBatch), true, ActiveTransferProgress(801, .2f))
            awaitCondition("Files controls did not observe the new batch beside failed history", stableMs = 120) {
                tagged(SHARED_EXECUTION).size == 1 && tagged(SHARED_PILL).size == 1 && !doneIsVisible()
            }
            val nextCompleted = nextBatch.copy(status = TransferStatus.COMPLETED, progress = 1f,
                elapsedMs = 120, downloadMBps = 20f)
            publish(listOf(failedHistory, nextCompleted), false)
            awaitCondition("Old failed history suppressed Done for a newly successful batch") { doneIsVisible() }
            val doneObservedAt = SystemClock.uptimeMillis()
            val expiryDeadline = doneObservedAt + 2700
            var hiddenSince: Long? = null
            var expiredWhileUpdating = false
            var metadataRevision = 0L
            do {
                // Keep publishing terminal metadata through expiry. A task-list-keyed effect
                // must not cancel or restart the original 1800ms completion timer.
                publish(listOf(failedHistory, nextCompleted.copy(elapsedMs = 120 + metadataRevision)), false)
                metadataRevision++
                val now = SystemClock.uptimeMillis()
                if (!doneIsVisible()) {
                    if (hiddenSince == null) hiddenSince = now
                    if (now - checkNotNull(hiddenSince) >= 200) {
                        expiredWhileUpdating = true
                        break
                    }
                } else hiddenSince = null
                SystemClock.sleep(100)
            } while (SystemClock.uptimeMillis() < expiryDeadline)
            check(expiredWhileUpdating) { "Terminal metadata changes restarted or stranded the Done hold" }
            publish(listOf(failedHistory, nextCompleted.copy(elapsedMs = 999)), false)
            assertNoDoneFor("Terminal metadata replayed completion after Done expired", durationMs = 300)
            publish(emptyList(), false)
            awaitSummaries(0, 0)
            report.putString("result", "PASS: 55:45 aligned list-header cards, scroll-away/return with intact history, independent counts/history, top-aligned generation rows with stable identity and upward peer handoff, completed-row final-time hold and queued waiting-row replenishment, failure/cancellation without success markers, fixed queue height, waiting clocks, no idle/initial speed placeholder, retained speed between downloads, size-before-speed persistent shell through digit and unit changes, pause, matching IDs, shared completion/conflation helper, hidden progress without animation and correct resume, failed-batch Done suppression, fresh-success Done despite failed history and bounded expiry during metadata updates, targeted single/batch clear preserving busy work and tasks completing or added during cleanup, 300dp width and 360/420dp height actions; theme screenshots")
            report.putString("screenshots", "cache/queue-summary-empty.png, cache/queue-summary-light.png, cache/queue-summary-dark.png, cache/queue-summary-generation-completed.png, cache/queue-summary-compact.png, cache/queue-summary-compact-actions.png, cache/queue-summary-420-actions.png")
            result = Activity.RESULT_OK
        } catch (error: Throwable) {
            report.putString("failure", error.stackTraceToString())
            runCatching { screenshot("queue-focus-failure.png") }
        } finally {
            runOnMainSync {
                activity?.setContent {}
                store.clear()
                activity?.finish()
            }
        }
        finish(result, report)
    }

    private fun task(id: Long, name: String, status: TransferStatus) = TransferTask(
        file = NikonCamera.FileInfo(handle = id.toInt(), size = 10L * 1024 * 1024,
            fileName = name, captureDate = null),
        taskId = id,
        status = status,
    )

    private data class DownloadProbeFrame(
        val taskId: Long?,
        val completing: Boolean,
        val progress: Float,
        val animationRunning: Boolean,
    )

    @Composable
    private fun ObserveDownloadDisplay(
        transfer: TransferViewModel,
        probe: AtomicReference<QueueDownloadDisplay>,
        revision: AtomicLong,
        frames: MutableList<DownloadProbeFrame>,
        animate: Boolean,
    ) {
        val state by transfer.state.collectAsState()
        val progress by transfer.activeTransferProgress.collectAsState()
        val active = state.tasks.firstOrNull { it.status == TransferStatus.TRANSFERING && !it.isGeneratingFrame }
        val display = rememberQueueDownloadDisplay(state.tasks, active, progress, animate = animate)
        SideEffect {
            probe.set(display)
            revision.set(state.taskStructureRevision)
        }
        LaunchedEffect(display) {
            snapshotFlow {
                DownloadProbeFrame(display.task?.taskId, display.completing, display.progress.value,
                    display.animation.isRunning)
            }
                .collect { frames.add(it) }
        }
    }

    private fun nodes(text: String): List<AccessibilityNodeInfo> {
        val result = ArrayList<AccessibilityNodeInfo>()
        fun visit(node: AccessibilityNodeInfo) {
            if (node.isVisibleToUser && node.text?.toString() == text) result += node
            for (index in 0 until node.childCount) node.getChild(index)?.let(::visit)
        }
        uiAutomation.rootInActiveWindow?.let(::visit)
        return result
    }

    private fun bounds(node: AccessibilityNodeInfo): Rect = Rect().also(node::getBoundsInScreen)

    private fun accessibilityNodeDebug(node: AccessibilityNodeInfo): String =
        "hash=${node.hashCode()}, resourceId=${node.viewIdResourceName}, windowId=${node.windowId}, " +
            "class=${node.className}, visible=${node.isVisibleToUser}, enabled=${node.isEnabled}, " +
            "clickable=${node.isClickable}, children=${node.childCount}, bounds=${bounds(node)}, raw=$node"

    private fun tagged(
        tag: String,
        root: AccessibilityNodeInfo? = uiAutomation.rootInActiveWindow,
    ): List<AccessibilityNodeInfo> {
        val result = ArrayList<AccessibilityNodeInfo>()
        fun visit(node: AccessibilityNodeInfo) {
            val id = node.viewIdResourceName
            if (node.isVisibleToUser && (id == tag || id?.endsWith("/$tag") == true)) result += node
            for (index in 0 until node.childCount) node.getChild(index)?.let(::visit)
        }
        root?.let(::visit)
        return result
    }

    private fun generationRows(): List<AccessibilityNodeInfo> {
        val result = ArrayList<AccessibilityNodeInfo>()
        fun visit(node: AccessibilityNodeInfo) {
            val id = node.viewIdResourceName?.substringAfterLast('/')
            if (node.isVisibleToUser && id?.startsWith(GENERATION_TASK_PREFIX) == true) result += node
            for (index in 0 until node.childCount) node.getChild(index)?.let(::visit)
        }
        tagged(GENERATION_CARD).singleOrNull()?.let(::visit)
        return result
    }

    private fun awaitGenerationRows(vararg expectedIds: Long) {
        awaitCondition("Generation rows do not match ${expectedIds.toList()}", stableMs = 120) {
            val rows = generationRows()
            val ids = rows.mapNotNull {
                it.viewIdResourceName?.substringAfterLast('/')?.removePrefix(GENERATION_TASK_PREFIX)?.toLongOrNull()
            }
            rows.size == expectedIds.size && ids.toSet() == expectedIds.toSet()
        }
    }

    private fun summaryText(tag: String): String =
        tagged(tag).singleOrNull()?.let(::accessibilityText).orEmpty()

    private fun accessibilityText(root: AccessibilityNodeInfo): String {
        val parts = ArrayList<String>()
        fun visit(node: AccessibilityNodeInfo) {
            if (!node.isVisibleToUser) return
            node.text?.toString()?.let(parts::add)
            node.contentDescription?.toString()?.let(parts::add)
            for (index in 0 until node.childCount) node.getChild(index)?.let(::visit)
        }
        visit(root)
        return parts.joinToString("\n")
    }

    private fun awaitDownloadProgress(expected: Float?) {
        awaitCondition("Download accessibility progress did not reach $expected", stableMs = 80) {
            val card = tagged(DOWNLOAD_CARD).singleOrNull()
            val range = card?.rangeInfo
            card != null && if (expected == null) range == null else range != null &&
                abs(range.min) < .001f && abs(range.max - 1f) < .001f &&
                abs(range.current - expected) < .005f
        }
        check(!Regex("\\d+(?:\\.\\d+)?%").containsMatchIn(summaryText(DOWNLOAD_CARD))) {
            "Download summary still displays percentage text"
        }
    }

    private fun clickableNode(description: String): AccessibilityNodeInfo? {
        fun visit(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if (node.isVisibleToUser && node.contentDescription?.toString() == description) return node
            for (index in 0 until node.childCount) node.getChild(index)?.let { child ->
                visit(child)?.let { return it }
            }
            return null
        }
        var node = uiAutomation.rootInActiveWindow?.let(::visit) ?: return null
        while (!node.isClickable) node = node.parent ?: return null
        return node
    }

    private fun clickableBounds(description: String): Rect? = clickableNode(description)?.let(::bounds)

    private fun awaitCondition(message: String, stableMs: Long = 0, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 3500
        var stableSince: Long? = null
        do {
            val now = SystemClock.uptimeMillis()
            if (condition()) {
                if (stableSince == null) stableSince = now
                if (now - stableSince >= stableMs) return
            } else stableSince = null
            SystemClock.sleep(35)
        } while (SystemClock.uptimeMillis() < deadline)
        error(message)
    }

    private fun awaitText(text: String) {
        val deadline = SystemClock.uptimeMillis() + 4000
        while (nodes(text).isEmpty() && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(35)
        check(nodes(text).isNotEmpty()) { "Missing visible text: $text" }
    }

    private fun awaitAbsent(text: String, timeoutMs: Long = 4000) {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (nodes(text).isNotEmpty() && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(35)
        check(nodes(text).isEmpty()) { "Unexpected visible text: $text" }
    }

    private fun awaitCount(text: String, expected: Int, timeoutMs: Long) {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (nodes(text).size != expected && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(35)
        check(nodes(text).size == expected) { "Expected $expected visible instances of $text; found ${nodes(text).size}" }
    }

    private fun screenshot(name: String, darkBackground: Boolean? = null) {
        val deadline = SystemClock.uptimeMillis() + 4000
        var image = checkNotNull(uiAutomation.takeScreenshot())
        fun matchesTheme(): Boolean {
            if (darkBackground == null) return true
            val pixel = image.getPixel(8, image.height / 2)
            val brightness = (android.graphics.Color.red(pixel) + android.graphics.Color.green(pixel) +
                android.graphics.Color.blue(pixel)) / 3
            return if (darkBackground) brightness < 100 else brightness > 160
        }
        // Accessibility and SurfaceFlinger can publish different frames on a software GPU.
        while (!matchesTheme() && SystemClock.uptimeMillis() < deadline) {
            image.recycle()
            SystemClock.sleep(100)
            image = checkNotNull(uiAutomation.takeScreenshot())
        }
        check(matchesTheme()) { "Theme did not reach the rendered frame: $name" }
        File(targetContext.cacheDir, name).outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        image.recycle()
    }
}
