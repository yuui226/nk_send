package com.ztransfer.ui.screen

import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask

data class TransferQueueActionVisibility(
    val hasRetryable: Boolean,
    val hasClearable: Boolean,
)

fun transferQueueActionVisibility(
    tasks: List<TransferTask>,
    isTransferring: Boolean,
    removingTaskIds: Set<Long>,
    suppressAll: Boolean = false,
): TransferQueueActionVisibility = TransferQueueActionVisibility(
    hasRetryable = !suppressAll && !isTransferring && tasks.any { task ->
        task.taskId !in removingTaskIds &&
            (task.status == TransferStatus.FAILED || task.status == TransferStatus.CANCELLED)
    },
    hasClearable = !suppressAll && tasks.any { task ->
        task.taskId !in removingTaskIds &&
            task.status != TransferStatus.TRANSFERING &&
            !task.isGeneratingFrame
    },
)
