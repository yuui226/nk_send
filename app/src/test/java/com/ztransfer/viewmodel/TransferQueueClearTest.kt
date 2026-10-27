package com.ztransfer.viewmodel

import com.ztransfer.protocol.NikonCamera
import com.ztransfer.ui.screen.QueueActivityState
import com.ztransfer.ui.screen.transferQueuePresentation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class TransferQueueClearTest {
    private fun task(id: Long, status: TransferStatus = TransferStatus.COMPLETED) = TransferTask(
        taskId = id,
        file = NikonCamera.FileInfo(id.toInt(), 100L, "DSC_$id.JPG", captureDate = null),
        status = status,
    )

    @Test
    fun selectionProtectsCurrentDownloadAndEveryAdmittedGeneration() {
        val tasks = listOf(
            task(1, TransferStatus.TRANSFERING), task(2, TransferStatus.WAITING),
            task(3), task(4, TransferStatus.FAILED), task(5, TransferStatus.CANCELLED),
            task(6).copy(isGeneratingFrame = true, frameGenerationStartedAtElapsedMs = 10),
            task(7).copy(isGeneratingFrame = true),
            task(8, TransferStatus.TRANSFERING).copy(isGeneratingFrame = true),
        )
        assertEquals(setOf(2L, 3L, 4L, 5L), clearQueueTargetIds(tasks))
    }

    @Test
    fun withdrawalCancelsOnlyWaitingTasksInTheCapturedSelection() {
        val selectedWaiting = task(1, TransferStatus.WAITING).copy(speed = 20)
        val selectedDone = task(2)
        val targets = clearQueueTargetIds(listOf(selectedWaiting, selectedDone))
        val newlyQueued = task(3, TransferStatus.WAITING)
        val newlyCompleted = task(4)
        val withdrawn = withdrawQueueTargets(
            listOf(selectedWaiting, selectedDone, newlyQueued, newlyCompleted), targets,
        )
        assertEquals(TransferStatus.CANCELLED, withdrawn[0].status)
        assertEquals(0L, withdrawn[0].speed)
        assertSame(selectedDone, withdrawn[1])
        assertSame(newlyQueued, withdrawn[2])
        assertSame(newlyCompleted, withdrawn[3])
    }

    @Test
    fun withdrawalRechecksTargetsThatBecameBusy() {
        val waiting = task(1, TransferStatus.WAITING)
        val targets = clearQueueTargetIds(listOf(waiting))
        val startedDownload = waiting.copy(status = TransferStatus.TRANSFERING)
        val admittedEffect = waiting.copy(isGeneratingFrame = true)
        for (busy in listOf(startedDownload, admittedEffect)) {
            assertSame(busy, withdrawQueueTargets(listOf(busy), targets).single())
        }
    }

    @Test
    fun withdrawalDoesNotCancelATerminalTargetRetriedAfterSelection() {
        val originallyWaiting = task(1, TransferStatus.WAITING)
        val retriedTerminal = task(2, TransferStatus.WAITING)
        // Both IDs may be removal targets, but only ID 1 was WAITING in the captured snapshot.
        val afterWithdrawal = withdrawQueueTargets(listOf(originallyWaiting, retriedTerminal), setOf(1L))
        assertEquals(TransferStatus.CANCELLED, afterWithdrawal.first().status)
        assertSame(retriedTerminal, afterWithdrawal.last())
    }

    @Test
    fun originalDownloadAndGenerationSurviveFinishingDuringTheRemovalAnimation() {
        val active = task(1, TransferStatus.TRANSFERING)
        val waiting = task(2, TransferStatus.WAITING)
        val runningEffect = task(3).copy(isGeneratingFrame = true, frameGenerationStartedAtElapsedMs = 10)
        val waitingEffect = task(4).copy(isGeneratingFrame = true)
        val targets = clearQueueTargetIds(listOf(active, waiting, runningEffect, waitingEffect))
        val now = listOf(
            active.copy(status = TransferStatus.COMPLETED, elapsedMs = 20),
            waiting.copy(status = TransferStatus.CANCELLED),
            runningEffect.copy(isGeneratingFrame = false, frameGenerationElapsedMs = 25),
            waitingEffect.copy(isGeneratingFrame = false, frameGenerationElapsedMs = 30),
        )
        assertEquals(listOf(1L, 3L, 4L), removeQueueTargets(now, targets).map { it.taskId })
    }

    @Test
    fun laterTasksSurviveRegardlessOfHowFastTheyFinish() {
        val original = task(1)
        val targets = clearQueueTargetIds(listOf(original))
        val later = listOf(task(2), task(3, TransferStatus.WAITING),
            task(4, TransferStatus.TRANSFERING), task(5).copy(isGeneratingFrame = true))
        assertEquals(later, removeQueueTargets(listOf(original) + later, targets))
    }

    @Test
    fun retriedWaitingAndBusyTargetsAreProtectedAgainAtCleanup() {
        val failed = task(1, TransferStatus.FAILED)
        val targets = clearQueueTargetIds(listOf(failed))
        val protected = listOf(
            failed.copy(status = TransferStatus.WAITING),
            failed.copy(status = TransferStatus.TRANSFERING),
            failed.copy(status = TransferStatus.COMPLETED, isGeneratingFrame = true),
        )
        for (retry in protected) {
            assertSame(retry, removeQueueTargets(listOf(retry), targets).single())
        }
    }

    @Test
    fun cleanupAfterIndividualRowsHaveDisappearedIsIdempotentAndTargeted() {
        val targets = setOf(1L, 2L)
        val first = task(1, TransferStatus.FAILED)
        val second = task(2, TransferStatus.CANCELLED)
        val kept = task(3)
        val afterFirstRow = removeQueueTargets(listOf(first, second, kept), setOf(1L))
        val afterBatch = removeQueueTargets(afterFirstRow, targets)
        assertEquals(listOf(kept), afterBatch)
        assertEquals(afterBatch, removeQueueTargets(afterBatch, targets))
    }

    @Test
    fun clearingPendingDownloadsImmediatelyUpdatesOnlyTheirRemainingCount() {
        val active = task(1, TransferStatus.TRANSFERING).copy(progress = .4f, speed = 42)
        val waiting = task(2, TransferStatus.WAITING)
        val effect = task(3).copy(isGeneratingFrame = true)
        val snapshot = listOf(active, waiting, effect)
        val targets = clearQueueTargetIds(snapshot)
        val withdrawn = withdrawQueueTargets(snapshot, targets)
        val summary = transferQueuePresentation(withdrawn, isTransferring = true, excludedTaskIds = targets)
        assertSame(active, summary.downloadTask)
        assertEquals(QueueActivityState.RUNNING, summary.downloadState)
        assertEquals(1, summary.downloadRemaining)
        assertEquals(1, summary.generationRemaining)
        assertEquals(listOf(effect), summary.generationTasks)
    }
}
