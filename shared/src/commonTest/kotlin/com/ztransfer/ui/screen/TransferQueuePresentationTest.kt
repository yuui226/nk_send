package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TransferQueuePresentationTest {
    private fun task(handle: Int, status: TransferStatus) = TransferTask(
        file = CameraFileInfo(
            handle = handle,
            size = 100L,
            fileName = "DSC_$handle.JPG",
            captureDate = null,
        ),
        taskId = handle.toLong(),
        status = status,
    )

    @Test
    fun withdrawnOrSuppressedCardsDoNotExposeGlobalActions() {
        val cancelled = task(handle = 1, status = TransferStatus.CANCELLED)
        val withdrawn = transferQueueActionVisibility(
            tasks = listOf(cancelled),
            isTransferring = false,
            removingTaskIds = setOf(cancelled.taskId),
        )
        val suppressed = transferQueueActionVisibility(
            tasks = listOf(task(handle = 2, status = TransferStatus.COMPLETED)),
            isTransferring = false,
            removingTaskIds = emptySet(),
            suppressAll = true,
        )

        assertFalse(withdrawn.hasRetryable)
        assertFalse(withdrawn.hasClearable)
        assertFalse(suppressed.hasRetryable)
        assertFalse(suppressed.hasClearable)
    }

    @Test
    fun unrelatedFailedCardKeepsTheCorrectGlobalActionsVisible() {
        val departing = task(handle = 1, status = TransferStatus.CANCELLED)
        val failed = task(handle = 2, status = TransferStatus.FAILED)

        val visibility = transferQueueActionVisibility(
            tasks = listOf(departing, failed),
            isTransferring = false,
            removingTaskIds = setOf(departing.taskId),
        )

        assertTrue(visibility.hasRetryable)
        assertTrue(visibility.hasClearable)
    }

    @Test
    fun clearAllHidesActionsWhenEveryTerminalCardIsDeparting() {
        val tasks = listOf(
            task(handle = 1, status = TransferStatus.CANCELLED),
            task(handle = 2, status = TransferStatus.FAILED),
            task(handle = 3, status = TransferStatus.COMPLETED),
        )

        val visibility = transferQueueActionVisibility(
            tasks = tasks,
            isTransferring = false,
            removingTaskIds = tasks.mapTo(HashSet()) { it.taskId },
        )

        assertFalse(visibility.hasRetryable)
        assertFalse(visibility.hasClearable)
    }
}
