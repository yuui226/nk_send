package com.ztransfer.ui.screen

import com.ztransfer.protocol.NikonCamera
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferQueueActionVisibilityTest {
    private fun task(
        handle: Int,
        status: TransferStatus,
        isGeneratingFrame: Boolean = false,
    ) = TransferTask(
        file = NikonCamera.FileInfo(
            handle = handle,
            size = 100L,
            fileName = "DSC_$handle.JPG",
            captureDate = null,
        ),
        status = status,
        isGeneratingFrame = isGeneratingFrame,
    )

    @Test
    fun withdrawnCardDoesNotFlashGlobalRetryWhileItCollapses() {
        val cancelled = task(handle = 1, status = TransferStatus.CANCELLED)

        val visibility = transferQueueActionVisibility(
            tasks = listOf(cancelled),
            isTransferring = false,
            removingTaskIds = setOf(cancelled.taskId),
        )

        assertFalse(visibility.hasRetryable)
        assertFalse(visibility.hasClearable)
    }

    @Test
    fun clearAllDoesNotExposeActionsForAnyDepartingCard() {
        val cancelled = task(handle = 1, status = TransferStatus.CANCELLED)
        val failed = task(handle = 2, status = TransferStatus.FAILED)
        val completed = task(handle = 3, status = TransferStatus.COMPLETED)
        val tasks = listOf(cancelled, failed, completed)

        val visibility = transferQueueActionVisibility(
            tasks = tasks,
            isTransferring = false,
            removingTaskIds = tasks.mapTo(HashSet()) { it.taskId },
        )

        assertFalse(visibility.hasRetryable)
        assertFalse(visibility.hasClearable)
    }

    @Test
    fun clearAllCleanupWindowSuppressesActionsFromANewlyCompletedTask() {
        val completedDuringCleanup = task(handle = 1, status = TransferStatus.COMPLETED)

        val visibility = transferQueueActionVisibility(
            tasks = listOf(completedDuringCleanup),
            isTransferring = false,
            removingTaskIds = emptySet(),
            suppressAll = true,
        )

        assertFalse(visibility.hasRetryable)
        assertFalse(visibility.hasClearable)
    }

    @Test
    fun unrelatedFailedCardStillKeepsTheCorrectGlobalActionsVisible() {
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
}
