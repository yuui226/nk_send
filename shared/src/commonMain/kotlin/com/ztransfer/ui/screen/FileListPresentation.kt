package com.ztransfer.ui.screen

import com.ztransfer.catalog.UNKNOWN_CAPTURE_DATE_GROUP_KEY
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask

/** Platform-neutral signal fields rendered by the file-list toolbar. */
data class FileListSignalUiState(
    val rssi: Int?,
    val connected: Boolean,
    val connectionType: CameraConnectionType?,
    val staMode: Boolean,
)

fun buildLatestTaskIndexByHandle(tasks: List<TransferTask>): Map<Int, Int> = buildMap {
    tasks.forEachIndexed { index, task -> put(task.file.handle, index) }
}

enum class PillMode { DONE, PAUSED, GENERATING, COUNTING }

fun queuePillMode(
    downloadRemaining: Int,
    generationRemaining: Int,
    paused: Boolean = false,
): PillMode = when {
    paused && downloadRemaining > 0 -> PillMode.PAUSED
    downloadRemaining > 0 -> PillMode.COUNTING
    generationRemaining > 0 -> PillMode.GENERATING
    else -> PillMode.DONE
}

fun queuePillDisplayRemaining(actualRemaining: Int, heldCount: Int): Int {
    val actual = actualRemaining.coerceAtLeast(0)
    // heldCount represents queue cards whose flight animation has not landed yet.
    return (actual - heldCount.coerceAtLeast(0)).coerceAtLeast(0)
}

fun queuePillAllRemainingTasksAreInFlight(
    actualRemaining: Int,
    heldCount: Int,
): Boolean = actualRemaining > 0 &&
    heldCount > 0 &&
    queuePillDisplayRemaining(actualRemaining, heldCount) == 0

enum class QueueExecutionControl { START, PAUSE }

fun queueExecutionControl(
    isTransferring: Boolean,
    waitingCount: Int,
): QueueExecutionControl? = when {
    isTransferring -> QueueExecutionControl.PAUSE
    waitingCount > 0 -> QueueExecutionControl.START
    else -> null
}

data class PublishedCameraFileIdentity(
    val fileName: String,
    val size: Long,
    val captureDate: String?,
)

fun CameraFileInfo.publishedIdentity() = PublishedCameraFileIdentity(
    fileName = fileName,
    size = size,
    captureDate = captureDate,
)

/** Dates whose logical camera photos disappeared in the latest authoritative update. */
fun publishedCameraRemovalDates(
    previous: List<CameraFileInfo>,
    current: List<CameraFileInfo>,
): Set<String> {
    if (previous.isEmpty()) return emptySet()
    val currentHandles = current.asSequence().mapTo(HashSet(current.size)) { it.handle }
    val missingHandles = previous.filter { it.handle !in currentHandles }
    if (missingHandles.isEmpty()) return emptySet()
    // A surviving dual-card alias is an identity switch, not a visible deletion.
    val currentIdentities = current.asSequence()
        .mapTo(HashSet(current.size)) { it.publishedIdentity() }
    return missingHandles.asSequence()
        .filter { it.publishedIdentity() !in currentIdentities }
        .mapTo(LinkedHashSet()) {
            it.captureDate?.take(8) ?: UNKNOWN_CAPTURE_DATE_GROUP_KEY
        }
}

data class QueuePillTaskSummary(
    val downloadRemaining: Int,
    val generationRemaining: Int,
    val activeDownloadTaskId: Long?,
    val activeProgressTaskId: Long?,
    val hasActive: Boolean,
    val hasCancelled: Boolean,
)

/** Produces every low-frequency queue-pill field in one pass. */
fun summarizeQueuePillTasks(tasks: List<TransferTask>): QueuePillTaskSummary {
    var downloadRemaining = 0
    var generationRemaining = 0
    var activeDownloadTaskId: Long? = null
    var firstGeneratingTaskId: Long? = null
    var firstWaitingTaskId: Long? = null
    var hasCancelled = false

    tasks.forEach { task ->
        when (task.status) {
            TransferStatus.WAITING -> {
                downloadRemaining++
                if (firstWaitingTaskId == null) firstWaitingTaskId = task.taskId
            }
            TransferStatus.TRANSFERING -> {
                downloadRemaining++
                if (activeDownloadTaskId == null) activeDownloadTaskId = task.taskId
            }
            TransferStatus.CANCELLED -> hasCancelled = true
            TransferStatus.COMPLETED,
            TransferStatus.FAILED -> Unit
        }
        if (task.isGeneratingFrame) {
            generationRemaining++
            if (firstGeneratingTaskId == null) firstGeneratingTaskId = task.taskId
        }
    }

    return QueuePillTaskSummary(
        downloadRemaining = downloadRemaining,
        generationRemaining = generationRemaining,
        activeDownloadTaskId = activeDownloadTaskId,
        activeProgressTaskId = activeDownloadTaskId
            ?: firstGeneratingTaskId
            ?: firstWaitingTaskId,
        hasActive = activeDownloadTaskId != null || generationRemaining > 0,
        hasCancelled = hasCancelled,
    )
}

/** A restored file-list session falls back to its historical Wi-Fi presentation. */
fun disconnectedConnectionType(connectionType: CameraConnectionType?): CameraConnectionType =
    connectionType ?: CameraConnectionType.WIFI
