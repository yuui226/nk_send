package com.ztransfer.viewmodel

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TransferQueuePolicyTest {
    @Test
    fun transferStatusNamesAndOrderRemainCompatible() {
        assertEquals(
            listOf("WAITING", "TRANSFERING", "COMPLETED", "FAILED", "CANCELLED"),
            TransferStatus.entries.map(TransferStatus::name),
        )
    }

    @Test
    fun activeProgressDefaultsRemainZero() {
        assertEquals(
            ActiveTransferProgress(taskId = 7L),
            ActiveTransferProgress(
                taskId = 7L,
                fraction = 0f,
                downloaded = 0L,
                bytesPerSecond = 0L,
                retainedBytesPerSecond = 0L,
            ),
        )
    }

    @Test
    fun executionStatePreservesPauseAndResumeTransitions() {
        val idle = TransferExecutionState()
        assertEquals(idle, idle.pauseRequested())

        val running = idle.started()
        assertEquals(TransferExecutionState(isTransferring = true), running)

        val pauseRequested = running.pauseRequested()
        assertEquals(
            TransferExecutionState(isTransferring = true, pauseAfterCurrent = true),
            pauseRequested,
        )
        assertEquals(TransferExecutionState(), pauseRequested.resumed().finished(false))
        assertEquals(
            TransferExecutionState(isTransferring = false, pauseAfterCurrent = true),
            pauseRequested.finished(stoppedAfterCurrent = true),
        )
        assertEquals(TransferExecutionState(isTransferring = true), pauseRequested.started())
    }

    @Test
    fun enqueueGatePreservesEveryBooleanCombination() {
        val expected = mapOf(
            Triple(false, false, false) to true,
            Triple(false, false, true) to false,
            Triple(false, true, false) to true,
            Triple(false, true, true) to false,
            Triple(true, false, false) to false,
            Triple(true, false, true) to false,
            Triple(true, true, false) to true,
            Triple(true, true, true) to false,
        )

        expected.forEach { (input, result) ->
            assertEquals(
                result,
                shouldRunQueueAfterEnqueue(
                    deferTransferStart = input.first,
                    isTransferring = input.second,
                    pauseAfterCurrent = input.third,
                ),
                input.toString(),
            )
        }
    }

    @Test
    fun pauseIsObservedOnlyAtTheNextCompleteTaskBoundary() {
        assertFalse(shouldPauseBeforeNextTransfer(false, false))
        assertFalse(shouldPauseBeforeNextTransfer(false, true))
        assertTrue(shouldPauseBeforeNextTransfer(true, false))
        assertFalse(shouldPauseBeforeNextTransfer(true, true))
    }

    @Test
    fun pauseKeepsTheNextTaskWaitingUntilExplicitResume() {
        val queue = TransferTaskQueue<Item>()
        val current = item(1)
        val next = item(2)
        queue.addAll(listOf(current, next))
        assertTrue(shouldRunQueueAfterEnqueue(false, false, false))
        assertEquals(current, queue.takeFirst())

        // The current task completes normally; observing pause does not claim the next task.
        assertTrue(shouldPauseBeforeNextTransfer(true, false))

        // Explicit resume clears the platform flag and the same FIFO head is still available.
        assertFalse(shouldPauseBeforeNextTransfer(false, false))
        assertEquals(next, queue.takeFirst())
    }

    @Test
    fun sameTaskRecheckRunsBeforeARequestedPauseBoundary() {
        assertFalse(
            shouldPauseBeforeNextTransfer(
                pauseAfterCurrent = true,
                isRecheckingCurrentTask = true,
            ),
        )
    }

    @Test
    fun queueSpeedKeepsTheLastPositiveSampleAcrossFileBoundaries() {
        assertEquals(12L, retainLastValidTransferSpeed(0L, 12L))
        assertEquals(12L, retainLastValidTransferSpeed(12L, 0L))
        assertEquals(12L, retainLastValidTransferSpeed(12L, -1L))
        assertEquals(9L, retainLastValidTransferSpeed(12L, 9L))
        assertEquals(0L, retainLastValidTransferSpeed(-4L, 0L))
    }

    @Test
    fun pendingQueuePreservesFifoAndRemovesQueuedWithdrawal() {
        val first = item(1)
        val second = item(2)
        val third = item(3)
        val queue = TransferTaskQueue<Item>()
        queue.addAll(listOf(first, second, third))

        queue.withdraw(listOf(second.taskId))

        assertEquals(first, queue.takeFirst())
        assertEquals(third, queue.takeFirst())
        assertNull(queue.takeFirst())
        assertFalse(queue.consumeWithdrawal(second.taskId))
    }

    @Test
    fun claimedPreflightTaskCanBeWithdrawnExactlyOnce() {
        val claimed = item(1)
        val queue = TransferTaskQueue<Item>()
        queue.addAll(listOf(claimed))
        assertEquals(claimed, queue.takeFirst())

        queue.withdraw(listOf(claimed.taskId))

        assertTrue(queue.consumeWithdrawal(claimed.taskId))
        assertFalse(queue.consumeWithdrawal(claimed.taskId))
    }

    @Test
    fun clearDropsQueuedTasksAndClaimedWithdrawalMarkers() {
        val queue = TransferTaskQueue<Item>()
        queue.addAll(listOf(item(1)))
        queue.withdraw(listOf(2L))

        queue.clear()

        assertNull(queue.takeFirst())
        assertFalse(queue.consumeWithdrawal(2L))
    }

    @Test
    fun addingTheSameTaskIdUpdatesItsValueWithoutChangingItsPosition() {
        val queue = TransferTaskQueue<Item>()
        queue.addAll(listOf(item(1), item(2)))
        val replacement = item(1, TransferStatus.FAILED)

        queue.addAll(listOf(replacement))

        assertEquals(replacement, queue.takeFirst())
        assertEquals(item(2), queue.takeFirst())
    }

    @Test
    fun retrySelectionIncludesOnlyFailedOrCancelledTasksNotLeavingTheUi() {
        val waiting = item(1, TransferStatus.WAITING)
        val transferring = item(2, TransferStatus.TRANSFERING)
        val completed = item(3, TransferStatus.COMPLETED)
        val failed = item(4, TransferStatus.FAILED)
        val cancelled = item(5, TransferStatus.CANCELLED)

        assertEquals(
            setOf(cancelled.taskId),
            retryableTransferTaskIds(
                listOf(waiting, transferring, completed, failed, cancelled),
                excludedTaskIds = setOf(failed.taskId),
            ),
        )
    }

    private data class Item(
        override val taskId: Long,
        override val status: TransferStatus,
    ) : TransferQueueItem

    private fun item(
        id: Long,
        status: TransferStatus = TransferStatus.WAITING,
    ) = Item(id, status)
}
