package com.ztransfer.ui.screen

import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class TransferQueuePresentationTest {
    @Test
    fun existingOutputChecksStayOutOfBothSummariesUntilGenerationIsConfirmed() {
        for (status in listOf(TransferStatus.COMPLETED, TransferStatus.TRANSFERING)) {
            val checking = task(1, status, generating = true).copy(frameGenerationPendingCheck = true)
            assertEquals(TransferQueuePresentation(), transferQueuePresentation(listOf(checking), true))
            val skipped = checking.copy(isGeneratingFrame = false, frameGenerationPendingCheck = false,
                status = TransferStatus.COMPLETED, frameGenerationSkipped = true)
            assertEquals(TransferQueuePresentation(), transferQueuePresentation(listOf(skipped), false))

            val confirmed = checking.copy(frameGenerationPendingCheck = false,
                frameGenerationStartedAtElapsedMs = 100L)
            val running = transferQueuePresentation(listOf(confirmed), true)
            assertEquals(listOf(confirmed), running.generationTasks)
            assertEquals(1, running.generationRemaining)
            assertEquals(QueueActivityState.RUNNING, running.generationState)
            assertEquals(0, running.downloadRemaining)
            assertNull(running.downloadTask)
        }
    }

    @Test
    fun hiddenChecksDoNotChangeTheRealDownloadOrGenerationQueueOrder() {
        val checking = task(1, generating = true).copy(frameGenerationPendingCheck = true)
        val running = task(2, generating = true, startedAt = 100L)
        val waiting = task(3, generating = true)
        val download = task(4, TransferStatus.TRANSFERING)
        val summary = transferQueuePresentation(listOf(checking, waiting, download, running), true)
        assertEquals(listOf(running, waiting), summary.generationTasks)
        assertEquals(2, summary.generationRemaining)
        assertEquals(1, summary.downloadRemaining)
        assertSame(download, summary.downloadTask)
    }

    private fun task(
        id: Long,
        status: TransferStatus = TransferStatus.COMPLETED,
        generating: Boolean = false,
        startedAt: Long? = null,
    ) = TransferTask(
        taskId = id,
        file = NikonCamera.FileInfo(
            handle = id.toInt(),
            size = 100L,
            fileName = "DSC_$id.JPG",
            captureDate = null,
        ),
        status = status,
        isGeneratingFrame = generating,
        frameGenerationStartedAtElapsedMs = startedAt,
    )

    @Test
    fun emptyOrTerminalQueueLeavesBothSummariesIdleWithNoRetainedStatistics() {
        val terminalTasks = listOf(
            task(1).copy(elapsedMs = 250, downloadMBps = 19f),
            task(2, TransferStatus.FAILED).copy(error = "transfer failed"),
            task(3, TransferStatus.CANCELLED),
            task(4).copy(frameGenerationError = "effect failed"),
            task(5).copy(skipped = true, frameGenerationSkipped = true),
        )
        for (tasks in listOf(emptyList(), terminalTasks)) {
            for (transferring in listOf(false, true)) {
                assertEquals(TransferQueuePresentation(), transferQueuePresentation(tasks, transferring))
            }
        }
    }

    @Test
    fun simultaneousQueuesExposeTheirOwnRunningFileAndRemainingCount() {
        val generation = task(1, generating = true, startedAt = 100L)
        val pendingGeneration = task(2, generating = true)
        val download = task(3, TransferStatus.TRANSFERING)
        val pendingDownload = task(4, TransferStatus.WAITING)
        val summary = transferQueuePresentation(
            listOf(generation, pendingGeneration, download, pendingDownload, task(5)), true,
        )

        assertSame(download, summary.downloadTask)
        assertEquals(QueueActivityState.RUNNING, summary.downloadState)
        assertEquals(2, summary.downloadRemaining)
        assertSame(generation, summary.generationTasks.firstOrNull())
        assertEquals(QueueActivityState.RUNNING, summary.generationState)
        assertEquals(2, summary.generationRemaining)
    }

    @Test
    fun generationWaitingForMetadataDoesNotDisplaceAnActuallyRunningJob() {
        val waiting = task(1, generating = true)
        val running = task(2, generating = true, startedAt = 100L)
        val summary = transferQueuePresentation(listOf(waiting, running), false)

        assertSame(running, summary.generationTasks.firstOrNull())
        assertEquals(QueueActivityState.RUNNING, summary.generationState)
        assertEquals(2, summary.generationRemaining)
        assertNull(summary.downloadTask)
        assertEquals(0, summary.downloadRemaining)
    }

    @Test
    fun generationPreparationUsesAStableCandidateWithoutClaimingItHasStarted() {
        val retry = task(30, generating = true)
        val older = task(20, generating = true)
        val summary = transferQueuePresentation(listOf(retry, older), false)

        assertSame(older, summary.generationTasks.firstOrNull())
        assertEquals(QueueActivityState.WAITING, summary.generationState)
        assertEquals(2, summary.generationRemaining)
        assertNull(summary.generationTasks.firstOrNull()?.frameGenerationStartedAtElapsedMs)
    }

    @Test
    fun legacyCropTransferStatusCountsOnlyAsGeneration() {
        for (startedAt in listOf(null, 100L)) {
            val crop = task(1, TransferStatus.TRANSFERING, generating = true, startedAt = startedAt)
            val summary = transferQueuePresentation(listOf(crop), true)

            assertNull(summary.downloadTask)
            assertEquals(QueueActivityState.IDLE, summary.downloadState)
            assertEquals(0, summary.downloadRemaining)
            assertSame(crop, summary.generationTasks.firstOrNull())
            assertEquals(1, summary.generationRemaining)
            assertEquals(
                if (startedAt == null) QueueActivityState.WAITING else QueueActivityState.RUNNING,
                summary.generationState,
            )
        }
    }

    @Test
    fun downloadGapDoesNotInventTheNextFileFromTaskOrderOrRetryId() {
        val retry = task(30, TransferStatus.WAITING)
        val waiting = task(20, TransferStatus.WAITING)
        val summary = transferQueuePresentation(listOf(retry, waiting), true)

        assertNull(summary.downloadTask)
        assertEquals(QueueActivityState.WAITING, summary.downloadState)
        assertEquals(2, summary.downloadRemaining)

        val startedRetry = retry.copy(status = TransferStatus.TRANSFERING)
        val running = transferQueuePresentation(listOf(startedRetry, waiting), true)
        assertSame(startedRetry, running.downloadTask)
        assertEquals(QueueActivityState.RUNNING, running.downloadState)
    }

    @Test
    fun pausedDownloadQueueRetainsItsCountAndDoesNotPauseGeneration() {
        val waiting = task(1, TransferStatus.WAITING)
        val running = task(2, generating = true, startedAt = 100L)
        val summary = transferQueuePresentation(listOf(waiting, running), false)

        assertNull(summary.downloadTask)
        assertEquals(QueueActivityState.PAUSED, summary.downloadState)
        assertEquals(1, summary.downloadRemaining)
        assertSame(running, summary.generationTasks.firstOrNull())
        assertEquals(QueueActivityState.RUNNING, summary.generationState)
    }

    @Test
    fun pauseAfterCurrentLeavesTheActualDownloadRunningUntilItFinishes() {
        val current = task(1, TransferStatus.TRANSFERING)
        val waiting = task(2, TransferStatus.WAITING)
        for (transferring in listOf(false, true)) {
            val summary = transferQueuePresentation(
                listOf(current, waiting), transferring, pauseAfterCurrent = true,
            )
            assertSame(current, summary.downloadTask)
            assertEquals(QueueActivityState.RUNNING, summary.downloadState)
            assertEquals(2, summary.downloadRemaining)
        }
    }

    @Test
    fun pauseRequestPreventsFalseWaitingActivityDuringBatchCleanup() {
        val summary = transferQueuePresentation(
            listOf(task(1), task(2, TransferStatus.WAITING)),
            isTransferring = true,
            pauseAfterCurrent = true,
        )

        assertNull(summary.downloadTask)
        assertEquals(QueueActivityState.PAUSED, summary.downloadState)
        assertEquals(1, summary.downloadRemaining)
    }

    @Test
    fun noRemainingDownloadIsIdleEvenIfTheBatchPauseFlagIsStillSet() {
        val summary = transferQueuePresentation(
            listOf(task(1), task(2, generating = true)),
            isTransferring = true,
            pauseAfterCurrent = true,
        )

        assertNull(summary.downloadTask)
        assertEquals(QueueActivityState.IDLE, summary.downloadState)
        assertEquals(0, summary.downloadRemaining)
        assertEquals(QueueActivityState.WAITING, summary.generationState)
    }

    @Test
    fun futureEffectsDoNotCountAsAdmittedGeneration() {
        val active = task(1, TransferStatus.TRANSFERING).copy(framePreset = PhotoFramePreset.MIST)
        val waiting = task(2, TransferStatus.WAITING).copy(framePreset = PhotoFramePreset.MIST)
        val summary = transferQueuePresentation(listOf(active, waiting), true)

        assertEquals(2, summary.downloadRemaining)
        assertEquals(0, summary.generationRemaining)
        assertEquals(QueueActivityState.IDLE, summary.generationState)
        assertNull(summary.generationTasks.firstOrNull())
    }

    @Test
    fun downloadToGenerationHandoffDoesNotCountTheSameTaskInBothQueues() {
        val downloading = task(1, TransferStatus.TRANSFERING)
        val next = task(2, TransferStatus.WAITING)
        val before = transferQueuePresentation(listOf(downloading, next), true)
        assertEquals(2, before.downloadRemaining)
        assertEquals(0, before.generationRemaining)

        val admitted = downloading.copy(status = TransferStatus.COMPLETED, isGeneratingFrame = true)
        val after = transferQueuePresentation(listOf(admitted, next), true)
        assertEquals(1, after.downloadRemaining)
        assertNull(after.downloadTask)
        assertEquals(QueueActivityState.WAITING, after.downloadState)
        assertEquals(1, after.generationRemaining)
        assertSame(admitted, after.generationTasks.firstOrNull())
    }

    @Test
    fun wirelessGenerationGapClearsTheFileAndClockWithoutAffectingDownload() {
        val download = task(2, TransferStatus.TRANSFERING)
        val running = task(1, generating = true, startedAt = 100L)
        val before = transferQueuePresentation(listOf(running, download), true)
        assertSame(running, before.generationTasks.firstOrNull())

        val finished = running.copy(isGeneratingFrame = false, frameGenerationElapsedMs = 250)
        val after = transferQueuePresentation(listOf(finished, download), true)
        assertSame(download, after.downloadTask)
        assertEquals(1, after.downloadRemaining)
        assertNull(after.generationTasks.firstOrNull())
        assertEquals(0, after.generationRemaining)
        assertEquals(QueueActivityState.IDLE, after.generationState)
    }

    @Test
    fun endedDownloadsDoNotLeaveStaleStatsWhileGenerationContinues() {
        val finishedDownload = task(2).copy(elapsedMs = 2_000, downloadMBps = 20f)
        val generation = task(1, generating = true, startedAt = 100L)
        val summary = transferQueuePresentation(listOf(generation, finishedDownload), false)

        assertNull(summary.downloadTask)
        assertEquals(QueueActivityState.IDLE, summary.downloadState)
        assertEquals(0, summary.downloadRemaining)
        assertSame(generation, summary.generationTasks.firstOrNull())
        assertEquals(QueueActivityState.RUNNING, summary.generationState)
    }

    @Test
    fun skippedOriginalCanStillHaveRealGenerationWork() {
        val originalSkipped = task(1, generating = true).copy(skipped = true)
        val summary = transferQueuePresentation(listOf(originalSkipped), false)

        assertEquals(0, summary.downloadRemaining)
        assertEquals(1, summary.generationRemaining)
        assertSame(originalSkipped, summary.generationTasks.firstOrNull())
        assertEquals(QueueActivityState.WAITING, summary.generationState)
    }

    @Test
    fun excludedWaitingTaskDoesNotInflateTheRemainingCount() {
        val hidden = task(1, TransferStatus.WAITING)
        val visible = task(2, TransferStatus.WAITING)
        val summary = transferQueuePresentation(
            listOf(hidden, visible), true, excludedTaskIds = setOf(hidden.taskId),
        )

        assertEquals(1, summary.downloadRemaining)
        assertNull(summary.downloadTask)
        assertEquals(QueueActivityState.WAITING, summary.downloadState)
    }

    @Test
    fun staleRemovalMarkerCannotHideAnAlreadyStartedDownload() {
        val download = task(1, TransferStatus.TRANSFERING)
        val summary = transferQueuePresentation(
            listOf(download), true, excludedTaskIds = setOf(download.taskId),
        )

        assertSame(download, summary.downloadTask)
        assertEquals(QueueActivityState.RUNNING, summary.downloadState)
        assertEquals(1, summary.downloadRemaining)
    }

    @Test
    fun staleRemovalMarkerCannotHideAdmittedOrRunningGeneration() {
        for (startedAt in listOf(null, 100L)) {
            val generation = task(1, generating = true, startedAt = startedAt)
            val summary = transferQueuePresentation(
                listOf(generation), false, excludedTaskIds = setOf(generation.taskId),
            )

            assertSame(generation, summary.generationTasks.firstOrNull())
            assertEquals(1, summary.generationRemaining)
            assertEquals(
                if (startedAt == null) QueueActivityState.WAITING else QueueActivityState.RUNNING,
                summary.generationState,
            )
        }
    }

    @Test
    fun retriesAndRemovalCannotResurrectAnOldAttempt() {
        val old = task(1, generating = true, startedAt = 100L)
        assertSame(old, transferQueuePresentation(listOf(old), false).generationTasks.firstOrNull())

        val retry = old.copy(taskId = 99, frameGenerationStartedAtElapsedMs = null)
        val summary = transferQueuePresentation(listOf(retry), false)
        assertSame(retry, summary.generationTasks.firstOrNull())
        assertEquals(QueueActivityState.WAITING, summary.generationState)
        assertEquals(TransferQueuePresentation(), transferQueuePresentation(emptyList(), false))
    }

    @Test
    fun newSnapshotAlwaysSuppliesTheCurrentTaskData() {
        val before = task(1, TransferStatus.TRANSFERING).copy(progress = 0.1f, speed = 1L)
        assertSame(before, transferQueuePresentation(listOf(before), true).downloadTask)

        val after = before.copy(progress = 0.9f, speed = 2L)
        assertSame(after, transferQueuePresentation(listOf(after), true).downloadTask)
    }

    @Test
    fun actuallyRunningJobsTakeBothRowsBeforeWaitingWorkAndKeepRemainingCountSeparate() {
        val preparing = task(1, generating = true)
        val first = task(2, generating = true, startedAt = 100L)
        val second = task(3, generating = true, startedAt = 150L)
        val staleStartedAt = task(4, startedAt = 50L)
        val summary = transferQueuePresentation(listOf(preparing, first, staleStartedAt, second), false)

        assertEquals(listOf(first, second, preparing), summary.generationTasks)
        assertSame(first, summary.generationTasks.firstOrNull())
        assertEquals(3, summary.generationRemaining)
        assertEquals(QueueActivityState.RUNNING, summary.generationState)
    }

    @Test
    fun twoVisibleGenerationRowsDoNotLimitTheRealRemainingCount() {
        val first = task(1, generating = true, startedAt = 100L)
        val second = task(2, generating = true, startedAt = 150L)
        val extra = task(3, generating = true, startedAt = 180L)
        val preparing = task(4, generating = true)
        val summary = transferQueuePresentation(listOf(first, second, extra, preparing), false)

        assertEquals(listOf(first, second, extra, preparing), summary.generationTasks)
        assertEquals(4, summary.generationRemaining)
    }

    @Test
    fun waitingGenerationKeepsItsPreparationStateInTheSummaryRow() {
        val preparing = task(1, generating = true)
        val summary = transferQueuePresentation(listOf(preparing), false)
        assertEquals(listOf(preparing), summary.generationTasks)
        assertSame(preparing, summary.generationTasks.firstOrNull())
        assertEquals(QueueActivityState.WAITING, summary.generationState)
        assertNull(summary.generationTasks.single().frameGenerationStartedAtElapsedMs)
    }

    @Test
    fun oneRunningJobGetsPriorityThenTheOldestWaitingCandidate() {
        val newerWaiting = task(20, generating = true)
        val olderWaiting = task(10, generating = true)
        val running = task(30, generating = true, startedAt = 100L)
        val summary = transferQueuePresentation(listOf(newerWaiting, olderWaiting, running), false)

        assertEquals(listOf(running, olderWaiting, newerWaiting), summary.generationTasks)
        assertSame(running, summary.generationTasks.firstOrNull())
        assertEquals(3, summary.generationRemaining)
        assertNull(summary.generationTasks[1].frameGenerationStartedAtElapsedMs)
    }

    @Test
    fun twoWaitingRowsAreSelectedByStableTaskIdRatherThanHistoricalListPosition() {
        val first = task(10, generating = true)
        val second = task(20, generating = true)
        val retry = task(30, generating = true)
        val summary = transferQueuePresentation(listOf(retry, second, first), false)

        assertEquals(listOf(first, second, retry), summary.generationTasks)
        assertEquals(QueueActivityState.WAITING, summary.generationState)
        assertSame(first, summary.generationTasks.firstOrNull())
        assertEquals(3, summary.generationRemaining)
    }
}
