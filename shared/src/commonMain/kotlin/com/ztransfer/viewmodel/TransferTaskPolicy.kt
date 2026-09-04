package com.ztransfer.viewmodel

import com.ztransfer.protocol.CameraFileInfo

fun normalizeThumbnailColumns(columns: Int): Int = columns.coerceIn(2, 4)

fun newMediaQueueCandidates(
    files: List<CameraFileInfo>,
    queuedTasks: List<TransferTask>,
): List<CameraFileInfo> {
    val queued = queuedTasks.asSequence()
        .mapTo(HashSet()) { task -> automaticTransferFileIdentity(task.file) }
    return files.asSequence()
        .distinctBy(::automaticTransferFileIdentity)
        .filterNot { automaticTransferFileIdentity(it) in queued }
        .toList()
}

fun withdrawWaitingTransferTasks(
    tasks: List<TransferTask>,
    taskId: Long? = null,
): List<TransferTask> = tasks.map { task ->
    if (task.status == TransferStatus.WAITING && (taskId == null || task.taskId == taskId)) {
        task.copy(status = TransferStatus.CANCELLED, speed = 0L)
    } else {
        task
    }
}

fun keepUnclearedTransferTasks(tasks: List<TransferTask>): List<TransferTask> = tasks.filter {
    it.status == TransferStatus.TRANSFERING ||
        it.status == TransferStatus.WAITING ||
        it.isGeneratingFrame
}

fun removeTransferTaskIfTerminal(
    tasks: List<TransferTask>,
    taskId: Long,
): List<TransferTask> = tasks.filterNot {
    it.taskId == taskId &&
        it.status != TransferStatus.TRANSFERING &&
        it.status != TransferStatus.WAITING &&
        !it.isGeneratingFrame
}

fun replaceRetryableTransferTasks(
    tasks: List<TransferTask>,
    attemptsByOldTaskId: Map<Long, TransferTask>,
): List<TransferTask> = tasks.map { task ->
    if (task.status == TransferStatus.FAILED || task.status == TransferStatus.CANCELLED) {
        attemptsByOldTaskId[task.taskId] ?: task
    } else {
        task
    }
}

private fun automaticTransferFileIdentity(file: CameraFileInfo): String =
    automaticTransferFileIdentity(file.fileName, file.size, file.captureDate)
