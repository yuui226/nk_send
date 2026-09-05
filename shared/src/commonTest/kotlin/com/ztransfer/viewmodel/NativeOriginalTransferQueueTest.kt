package com.ztransfer.viewmodel

import com.ztransfer.protocol.PtpObjectInfo
import kotlin.test.*

class NativeOriginalTransferQueueTest {
    @Test fun catalogEnqueuePreservesMergedStoresAndRejectsMismatchedMetadataWithoutConsumingIds() {
        val source = info()
        val file = com.ztransfer.protocol.CameraFileInfo(7, source.size, source.fileName!!, source.captureDate, true, setOf(0x10001, 0x20001))
        val queue = NativeOriginalTransferQueue()
        assertNull(queue.enqueueCatalog(source, file.copy(size = 99), false, 0))
        assertNull(queue.enqueueCatalog(source, file.copy(handle = 8), false, 0))
        assertNull(queue.enqueueCatalog(source, file.copy(isProtected = false), false, 0))
        assertNull(queue.enqueueCatalog(info(folder = true), file, false, 0))
        val first = assertNotNull(queue.enqueueCatalog(source, file, true, 0))
        assertEquals(1L, first.taskId)
        assertEquals(file, first.file)
        val second = assertNotNull(queue.enqueue(source, true, 0))
        assertEquals(first.destinationFolderName, second.destinationFolderName)
        queue.start()
        assertEquals(first.taskId, queue.takeNext()?.taskId)
        queue.completed(first.taskId, source.size, 1)
        assertEquals(second.taskId, queue.takeNext()?.taskId)
    }
    private fun info(handle: Int = 7, complete: Boolean = true, folder: Boolean = false) =
        PtpObjectInfo(handle, 0x10001, if (folder) 0x3001 else 0x3801, 3, "DSC_0007.JPG", "20260905T120000", true, folder, complete)

    @Test fun pageSnapshotIsSeparateFromActiveProgressAndRetainsIdentity() {
        val queue = NativeOriginalTransferQueue()
        val task = requireNotNull(queue.enqueue(info(), true, 0))
        queue.start(); queue.takeNext()
        val snapshot = requireNotNull(queue.taskSnapshotAt(0))
        queue.progress(task.taskId, 2, 4, 100)
        assertSame(snapshot, queue.taskSnapshotAt(0))
        assertEquals(0L, snapshot.downloaded)
        assertEquals(2L, queue.progressSnapshot()?.downloaded)
        assertEquals(task.file, snapshot.file)
        assertEquals(task.destinationFolderName, snapshot.destinationFolderName)
        queue.failed(task.taskId, "offline", false)
        assertNull(queue.progressSnapshot())
        assertEquals(2L, queue.taskSnapshotAt(0)?.downloaded)
        assertNull(queue.taskSnapshotAt(-1))
        assertNull(queue.taskSnapshotAt(1))
    }

    @Test fun withdrawAllAndAnimatedRemovalProtectActiveAndNewWaitingTasks() {
        val queue = NativeOriginalTransferQueue()
        val active = requireNotNull(queue.enqueue(info(1), false, 0))
        val waiting = requireNotNull(queue.enqueue(info(2), false, 0))
        queue.start(); queue.takeNext()
        assertFalse(queue.removeTask(active.taskId))
        assertFalse(queue.removeTask(waiting.taskId))
        queue.withdrawPending()
        assertEquals(TransferStatus.TRANSFERING, queue.taskAt(0)?.status)
        assertEquals(TransferStatus.CANCELLED, queue.taskAt(1)?.status)
        val retry = requireNotNull(queue.retry(waiting.taskId))
        assertFalse(queue.removeTask(waiting.taskId)) // old animation cannot delete replacement
        assertFalse(queue.removeTask(retry.taskId))
        queue.clearTerminal()
        assertEquals(2, queue.count)
        queue.completed(active.taskId, 3, 1)
        assertEquals(retry.taskId, queue.takeNext()?.taskId)
        assertTrue(queue.removeTask(active.taskId))
        assertFalse(queue.removeTask(active.taskId))
        assertFalse(queue.removeTask(Long.MAX_VALUE))
    }

    @Test fun withdrawAllCannotLeavePendingWorkBehindAfterHistoryIsCleared() {
        val queue = NativeOriginalTransferQueue()
        val active = requireNotNull(queue.enqueue(info(1), false, 0))
        queue.enqueue(info(2), false, 0)
        queue.enqueue(info(3), false, 0)
        queue.start(); queue.takeNext()
        queue.withdrawPending()
        queue.clearTerminal()
        assertEquals(1, queue.count)
        queue.completed(active.taskId, 3, 1)
        assertNull(queue.takeNext())
        queue.finishRun()
        assertFalse(queue.running)
        queue.clearTerminal()
        assertEquals(0, queue.count)
    }

    @Test fun retryAllReusesSharedEligibilityExclusionsAndHistoryOrder() {
        val queue = NativeOriginalTransferQueue()
        val first = requireNotNull(queue.enqueue(info(1), false, 0))
        val excluded = requireNotNull(queue.enqueue(info(2), false, 0))
        val third = requireNotNull(queue.enqueue(info(3), false, 0))
        queue.withdrawPending()
        assertEquals(2, queue.retryFailed(setOf(excluded.taskId)))
        val firstRetry = requireNotNull(queue.taskAt(0))
        val thirdRetry = requireNotNull(queue.taskAt(2))
        assertNotEquals(first.taskId, firstRetry.taskId)
        assertNotEquals(third.taskId, thirdRetry.taskId)
        assertEquals(first.file, firstRetry.file)
        assertEquals(TransferStatus.CANCELLED, queue.taskAt(1)?.status)
        assertEquals(0, queue.retryFailed(setOf(excluded.taskId)))
        queue.start()
        assertEquals(firstRetry.taskId, queue.takeNext()?.taskId)
        queue.completed(firstRetry.taskId, 3, 1)
        assertEquals(thirdRetry.taskId, queue.takeNext()?.taskId)
    }

    @Test fun completedSpeedUsesSharedEndToEndArithmeticAndZeroDurationGuard() {
        for ((bytes, elapsed, expected) in listOf(Triple(2_097_152L, 1_000L, 2f), Triple(3L, 0L, 0f))) {
            val queue = NativeOriginalTransferQueue()
            val task = requireNotNull(queue.enqueue(info(), false, 0))
            queue.start(); queue.takeNext()
            queue.completed(task.taskId, bytes, elapsed)
            assertEquals(expected, queue.taskAt(0)?.downloadMBps)
            assertEquals(elapsed, queue.taskAt(0)?.elapsedMs)
            assertNull(queue.progressSnapshot())
        }
    }

    @Test
    fun fifoManualDuplicatesAndDateSnapshotUseSharedModels() {
        val queue = NativeOriginalTransferQueue()
        val first = requireNotNull(queue.enqueue(info(), true, 20260101))
        val second = requireNotNull(queue.enqueue(info(), false, 20260101))
        assertNotEquals(first.taskId, second.taskId)
        assertEquals("ZT2026-09-05", first.destinationFolderName)
        assertEquals(setOf(0x10001), first.file.storageIds)
        assertTrue(queue.start())
        assertFalse(queue.start())
        assertEquals(first.taskId, queue.takeNext()?.taskId)
        assertNull(queue.takeNext())
        queue.completed(first.taskId, 3, 100)
        assertEquals(second.taskId, queue.takeNext()?.taskId)
        queue.completed(second.taskId, 3, 100)
        assertNull(queue.takeNext())
        queue.finishRun()
        assertFalse(queue.running)
        assertEquals(TransferStatus.COMPLETED, queue.taskAt(0)?.status)
    }

    @Test
    fun pauseFinishesCurrentAndRetainsPendingForExplicitResume() {
        val queue = NativeOriginalTransferQueue()
        val first = requireNotNull(queue.enqueue(info(1), false, 0))
        val second = requireNotNull(queue.enqueue(info(2), false, 0))
        queue.start()
        queue.takeNext()
        queue.pauseAfterCurrent()
        queue.completed(first.taskId, 3, 1)
        assertNull(queue.takeNext())
        queue.finishRun()
        assertTrue(queue.paused)
        assertFalse(queue.shouldAutoStart(false))
        assertTrue(queue.start())
        assertEquals(second.taskId, queue.takeNext()?.taskId)
    }

    @Test
    fun withdrawnWaitingTaskCanRetryWithNewIdentityAndNoOldStats() {
        val queue = NativeOriginalTransferQueue()
        val first = requireNotNull(queue.enqueue(info(), false, 0))
        queue.withdraw(first.taskId)
        assertEquals(TransferStatus.CANCELLED, queue.taskAt(0)?.status)
        val retry = requireNotNull(queue.retry(first.taskId))
        assertNotEquals(first.taskId, retry.taskId)
        assertEquals(0L, retry.downloaded)
        queue.start()
        assertEquals(retry.taskId, queue.takeNext()?.taskId)
        queue.completed(first.taskId, 100, 100) // stale completion cannot complete the new attempt
        assertEquals(TransferStatus.TRANSFERING, queue.taskAt(0)?.status)
        queue.failed(retry.taskId, "offline", false)
        assertEquals(TransferStatus.FAILED, queue.taskAt(0)?.status)
    }

    @Test
    fun clearHistoryKeepsWaitingAndActiveAndRejectsUnsafeMetadata() {
        val queue = NativeOriginalTransferQueue()
        assertNull(queue.enqueue(info(complete = false), false, 0))
        assertNull(queue.enqueue(info(folder = true), false, 0))
        val first = requireNotNull(queue.enqueue(info(), false, 0))
        val second = requireNotNull(queue.enqueue(info(8), false, 0))
        queue.withdraw(first.taskId)
        queue.clearTerminal()
        assertEquals(1, queue.count)
        queue.start()
        assertEquals(second.taskId, queue.takeNext()?.taskId)
        queue.clearTerminal()
        assertEquals(1, queue.count)
        queue.withdraw(second.taskId)
        assertEquals(TransferStatus.TRANSFERING, queue.taskAt(0)?.status)
    }

    @Test
    fun autoStartDelegatesToExistingExecutionPolicy() {
        val queue = NativeOriginalTransferQueue()
        assertFalse(queue.shouldAutoStart(true))
        assertTrue(queue.shouldAutoStart(false))
        queue.enqueue(info(), false, 0)
        queue.start()
        assertTrue(queue.shouldAutoStart(true))
        queue.pauseAfterCurrent()
        assertFalse(queue.shouldAutoStart(false))
    }

    @Test fun lateProgressCannotChangeCompletedOrRetriedTask() {
        val queue = NativeOriginalTransferQueue()
        val task = requireNotNull(queue.enqueue(info(), false, 0))
        queue.start(); queue.takeNext()
        queue.progress(task.taskId, 2, 4, 100)
        assertEquals(0.5f, queue.taskAt(0)?.progress)
        queue.progress(task.taskId, 1, 4, 50) // Out-of-order callbacks cannot regress bytes.
        assertEquals(2L, queue.taskAt(0)?.downloaded)
        queue.failed(task.taskId, "interrupted", true)
        assertEquals(2L, queue.taskAt(0)?.downloaded)
        assertEquals(0L, queue.taskAt(0)?.speed)
        val retry = requireNotNull(queue.retry(task.taskId))
        queue.takeNext()
        queue.progress(task.taskId, 99, 100, 100)
        assertEquals(0L, queue.taskAt(0)?.downloaded)
        queue.completed(retry.taskId, 3, 10)
        queue.progress(retry.taskId, 2, 3, 100)
        assertEquals(3L, queue.taskAt(0)?.downloaded)
        assertEquals(1f, queue.taskAt(0)?.progress)
    }
}
