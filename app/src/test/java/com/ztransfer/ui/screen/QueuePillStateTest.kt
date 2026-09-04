package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class QueuePillStateTest {
    private fun task(
        handle: Int,
        status: TransferStatus,
        isGeneratingFrame: Boolean = false,
    ) = TransferTask(
        file = CameraFileInfo(
            handle = handle,
            size = 100L,
            fileName = "DSC_$handle.JPG",
            captureDate = null,
        ),
        status = status,
        isGeneratingFrame = isGeneratingFrame,
    )

    @Test
    fun transferDisplayTakesPriorityOverConcurrentEffectGeneration() {
        assertEquals(
            PillMode.COUNTING,
            queuePillMode(downloadRemaining = 8, generationRemaining = 5),
        )
    }

    @Test
    fun effectGenerationIsShownOnlyAfterTransferFinishes() {
        assertEquals(
            PillMode.GENERATING,
            queuePillMode(downloadRemaining = 0, generationRemaining = 5),
        )
        assertEquals(
            PillMode.DONE,
            queuePillMode(downloadRemaining = 0, generationRemaining = 0),
        )
    }

    @Test
    fun idleWaitingQueueUsesTheCompactPausedPill() {
        assertEquals(
            PillMode.PAUSED,
            queuePillMode(
                downloadRemaining = 8,
                generationRemaining = 0,
                paused = true,
            ),
        )
        assertNotEquals(
            queuePillWidthKey(PillMode.PAUSED, speedText = null, count = 9),
            queuePillWidthKey(PillMode.PAUSED, speedText = null, count = 10),
        )
    }

    @Test
    fun transferPageControlDependsOnRuntimeNotDeferredPreference() {
        assertEquals(
            QueueExecutionControl.PAUSE,
            queueExecutionControl(isTransferring = true, waitingCount = 0),
        )
        assertEquals(
            QueueExecutionControl.START,
            queueExecutionControl(isTransferring = false, waitingCount = 3),
        )
        assertEquals(
            null,
            queueExecutionControl(isTransferring = false, waitingCount = 0),
        )
    }

    @Test
    fun flightHoldKeepsNewQueueAtZeroUntilCardsLand() {
        assertEquals(0, queuePillDisplayRemaining(actualRemaining = 24, heldCount = 24))
        assertEquals(0, queuePillDisplayRemaining(actualRemaining = 18, heldCount = 24))
    }

    @Test
    fun flightHoldStillDelaysOnlyTheNewlyAddedPartOfAnExistingQueue() {
        assertEquals(7, queuePillDisplayRemaining(actualRemaining = 27, heldCount = 20))
    }

    @Test
    fun overlappingFlightsIncreaseCountOnlyWhenEachCardLands() {
        // Both taps have reached the real queue, but neither animation has landed yet.
        assertEquals(0, queuePillDisplayRemaining(actualRemaining = 2, heldCount = 2))
        // The first animation lands while the second is still flying.
        assertEquals(1, queuePillDisplayRemaining(actualRemaining = 2, heldCount = 1))
        // The second animation lands last; the count progresses monotonically: 0 -> 1 -> 2.
        assertEquals(2, queuePillDisplayRemaining(actualRemaining = 2, heldCount = 0))
    }

    @Test
    fun allHeldTasksUseTheDefaultIconUntilTheFirstCardLands() {
        assertTrue(
            queuePillAllRemainingTasksAreInFlight(actualRemaining = 2, heldCount = 2)
        )
        assertFalse(
            queuePillAllRemainingTasksAreInFlight(actualRemaining = 27, heldCount = 20)
        )
        assertFalse(
            queuePillAllRemainingTasksAreInFlight(actualRemaining = 0, heldCount = 2)
        )
    }

    @Test
    fun genuinelyEmptyQueueStillDisplaysZero() {
        assertEquals(0, queuePillDisplayRemaining(actualRemaining = 0, heldCount = 20))
    }

    @Test
    fun equalWidthSpeedValuesShareAStableWidthKey() {
        assertEquals(
            queuePillWidthKey(PillMode.COUNTING, "1.0 MB/s", count = 8),
            queuePillWidthKey(PillMode.COUNTING, "9.9 MB/s", count = 8),
        )
    }

    @Test
    fun speedUnitAndDigitTransitionsRequestFreshWidthMeasurements() {
        val hundredsOfKilobytes = queuePillWidthKey(
            PillMode.COUNTING,
            "999.9 KB/s",
            count = 8,
        )
        assertNotEquals(
            hundredsOfKilobytes,
            queuePillWidthKey(PillMode.COUNTING, "1.0 MB/s", count = 8),
        )
        assertNotEquals(
            queuePillWidthKey(PillMode.COUNTING, "9.9 MB/s", count = 8),
            queuePillWidthKey(PillMode.COUNTING, "10.0 MB/s", count = 8),
        )
    }

    @Test
    fun countDigitAndSpeedVisibilityTransitionsRequestFreshWidths() {
        val base = queuePillWidthKey(PillMode.COUNTING, "1.0 MB/s", count = 99)
        assertNotEquals(
            base,
            queuePillWidthKey(PillMode.COUNTING, "1.0 MB/s", count = 100),
        )
        assertNotEquals(
            base,
            queuePillWidthKey(PillMode.COUNTING, speedText = null, count = 99),
        )
    }

    @Test
    fun taskSummaryPreservesQueuePillPriorityInOnePass() {
        val waiting = task(handle = 1, status = TransferStatus.WAITING)
        val generating = task(
            handle = 2,
            status = TransferStatus.COMPLETED,
            isGeneratingFrame = true,
        )
        val active = task(handle = 3, status = TransferStatus.TRANSFERING)
        val cancelled = task(handle = 4, status = TransferStatus.CANCELLED)

        val summary = summarizeQueuePillTasks(
            listOf(waiting, generating, active, cancelled),
        )

        assertEquals(2, summary.downloadRemaining)
        assertEquals(1, summary.generationRemaining)
        assertEquals(active.taskId, summary.activeDownloadTaskId)
        assertEquals(active.taskId, summary.activeProgressTaskId)
        assertEquals(true, summary.hasActive)
        assertEquals(true, summary.hasCancelled)
    }

    @Test
    fun completedTaskGeneratingAnEffectKeepsTheProgressOwnerAtFull() {
        val generating = task(
            handle = 1,
            status = TransferStatus.COMPLETED,
            isGeneratingFrame = true,
        )

        val summary = summarizeQueuePillTasks(listOf(generating))

        assertEquals(0, summary.downloadRemaining)
        assertEquals(1, summary.generationRemaining)
        assertEquals(generating.taskId, summary.activeProgressTaskId)
        assertEquals(true, summary.hasActive)
    }
}
