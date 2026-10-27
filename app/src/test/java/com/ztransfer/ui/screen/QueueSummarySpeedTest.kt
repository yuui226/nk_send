package com.ztransfer.ui.screen

import com.ztransfer.protocol.NikonCamera
import com.ztransfer.viewmodel.ActiveTransferProgress
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QueueSummarySpeedTest {
    private val current = TransferTask(taskId = 2,
        file = NikonCamera.FileInfo(2, 100L, "DSC_2.JPG", captureDate = null),
        status = TransferStatus.TRANSFERING)

    @Test fun firstUnknownSampleDoesNotInventZeroSpeed() {
        assertNull(queueSummarySpeed(current, null, ActiveTransferProgress(2), QueueActivityState.RUNNING))
    }

    @Test fun nextFileKeepsBatchSpeedUntilItsOwnFirstSample() {
        val starting = ActiveTransferProgress(2, retainedBytesPerSecond = 42L)
        assertEquals(42L, queueSummarySpeed(current, null, starting, QueueActivityState.RUNNING))
        assertEquals(9L, queueSummarySpeed(current, null, starting.copy(bytesPerSecond = 9L), QueueActivityState.RUNNING))
    }

    @Test fun unrelatedSnapshotCannotLendItsSpeedToCurrentFile() {
        val other = ActiveTransferProgress(9, bytesPerSecond = 99, retainedBytesPerSecond = 99)
        assertNull(queueSummarySpeed(current, null, other, QueueActivityState.RUNNING))
        assertEquals(5L, queueSummarySpeed(current.copy(speed = 5), null, other, QueueActivityState.RUNNING))
    }

    @Test fun idleAndPausedHideAllOldSpeedData() {
        val old = ActiveTransferProgress(1, bytesPerSecond = 42, retainedBytesPerSecond = 42)
        for (state in listOf(QueueActivityState.IDLE, QueueActivityState.PAUSED)) {
            assertNull(queueSummarySpeed(null, null, old, state))
        }
    }

    @Test fun preparationGapRetainsOnlyKnownBatchSpeed() {
        val old = ActiveTransferProgress(1, retainedBytesPerSecond = 42)
        assertEquals(42L, queueSummarySpeed(null, null, old, QueueActivityState.WAITING))
        assertNull(queueSummarySpeed(null, null, old.copy(retainedBytesPerSecond = 0), QueueActivityState.WAITING))
    }

    @Test fun completionAnimationUsesFinishedFilesOwnStatistics() {
        val done = current.copy(status = TransferStatus.COMPLETED, downloadMBps = 2f, speed = 1)
        val next = ActiveTransferProgress(3, bytesPerSecond = 99, retainedBytesPerSecond = 99)
        assertEquals(2L * 1024 * 1024, queueSummarySpeed(done, done, next, QueueActivityState.RUNNING))
    }

    @Test fun unavailableCompletionAverageUsesItsOwnLastSample() {
        for (mean in listOf(0f, Float.NaN, Float.POSITIVE_INFINITY)) {
            val done = current.copy(downloadMBps = mean, speed = 25)
            assertEquals(25L, queueSummarySpeed(done, done, ActiveTransferProgress(3, bytesPerSecond = 99), QueueActivityState.IDLE))
        }
    }

    @Test fun missingCompletionStatisticsNeverBorrowNextFilesSpeed() {
        val done = current.copy(status = TransferStatus.COMPLETED)
        assertNull(queueSummarySpeed(done, done, ActiveTransferProgress(3, retainedBytesPerSecond = 99), QueueActivityState.RUNNING))
    }
}
