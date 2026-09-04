package com.ztransfer.viewmodel

import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.frame.PhotoFrameMetadataSettings
import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.defaultPhotoFrameMetadataSettings
import com.ztransfer.frame.isSupportedPhotoFrameSourceExtension
import com.ztransfer.protocol.CameraFileInfo

/** Immutable queue snapshot shared by Android and the future iOS transfer coordinator. */
data class TransferTask(
    val file: CameraFileInfo,
    override val taskId: Long,
    val framePreset: PhotoFramePreset? = null,
    val frameBorderRequested: Boolean = true,
    val frameMetadataSettings: PhotoFrameMetadataSettings? = null,
    val frameWatermarkRequested: PhotoFrameWatermark = PhotoFrameWatermark(),
    val photoFilterRequested: PhotoFilterSelection? = null,
    val destinationFolderName: String? = null,
    override val status: TransferStatus = TransferStatus.WAITING,
    val progress: Float = 0f,
    val speed: Long = 0,
    val downloaded: Long = 0,
    val error: String? = null,
    val skipped: Boolean = false,
    val downloadMBps: Float = 0f,
    val elapsedMs: Long? = null,
    val isGeneratingFrame: Boolean = false,
    val frameGenerationStartedAtElapsedMs: Long? = null,
    val frameGenerationElapsedMs: Long? = null,
) : TransferQueueItem

fun TransferTask.startFrameGeneration(nowElapsedMs: Long): TransferTask = copy(
    isGeneratingFrame = true,
    frameGenerationStartedAtElapsedMs = nowElapsedMs,
    frameGenerationElapsedMs = null,
)

fun TransferTask.finishFrameGeneration(nowElapsedMs: Long): TransferTask {
    if (!isGeneratingFrame) return this
    val elapsed = frameGenerationStartedAtElapsedMs?.let { startedAt ->
        (nowElapsedMs - startedAt).coerceAtLeast(0L)
    }
    return copy(
        isGeneratingFrame = false,
        frameGenerationStartedAtElapsedMs = null,
        frameGenerationElapsedMs = elapsed,
    )
}

fun TransferTask.withActiveProgress(active: ActiveTransferProgress?): TransferTask =
    if (active?.taskId == taskId && status == TransferStatus.TRANSFERING) {
        copy(
            progress = active.fraction,
            downloaded = active.downloaded,
            speed = active.bytesPerSecond,
        )
    } else {
        this
    }

fun TransferTask.newAttempt(newTaskId: Long): TransferTask = copy(
    taskId = newTaskId,
    status = TransferStatus.WAITING,
    progress = 0f,
    speed = 0L,
    downloaded = 0L,
    error = null,
    skipped = false,
    downloadMBps = 0f,
    elapsedMs = null,
    isGeneratingFrame = false,
    frameGenerationStartedAtElapsedMs = null,
    frameGenerationElapsedMs = null,
)

/** Builds immutable task snapshots; the platform supplies a monotonic task-id source and day. */
fun createQueueTasks(
    files: List<CameraFileInfo>,
    photoFrameEnabled: Boolean,
    photoFrameBorderEnabled: Boolean = true,
    photoFramePreset: PhotoFramePreset,
    photoFrameWatermark: PhotoFrameWatermark,
    photoFrameMetadataSettings: PhotoFrameMetadataSettings =
        defaultPhotoFrameMetadataSettings(photoFramePreset),
    photoFilter: PhotoFilterSelection? = null,
    organizeTransfersByDate: Boolean = false,
    fallbackDayKey: Int,
    nextTaskId: () -> Long,
): List<TransferTask> = files.asSequence()
    .distinctBy(CameraFileInfo::handle)
    .map { file ->
        TransferTask(
            file = file,
            taskId = nextTaskId(),
            framePreset = photoFramePreset.takeIf {
                shouldGeneratePhotoFrame(photoFrameEnabled, file.extension)
            },
            frameBorderRequested = photoFrameBorderEnabled,
            frameMetadataSettings = photoFrameMetadataSettings,
            frameWatermarkRequested = photoFrameWatermark,
            photoFilterRequested = photoFilter.takeIf {
                isSupportedPhotoFrameSourceExtension(file.extension)
            },
            destinationFolderName = transferDestinationFolderName(
                captureDate = file.captureDate,
                organizeTransfersByDate = organizeTransfersByDate,
                fallbackDayKey = fallbackDayKey,
            ),
        )
    }
    .toList()
