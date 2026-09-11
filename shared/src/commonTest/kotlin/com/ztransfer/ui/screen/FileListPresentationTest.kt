package com.ztransfer.ui.screen

import com.ztransfer.catalog.UNKNOWN_CAPTURE_DATE_GROUP_KEY
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class FileListPresentationTest {
    private fun file(handle: Int, day: String? = "20260827") = CameraFileInfo(
        handle = handle,
        size = 1_000L,
        fileName = "DSC_${handle.toString().padStart(4, '0')}.JPG",
        captureDate = day?.let { "${it}T120000" },
    )

    private fun task(
        handle: Int,
        status: TransferStatus,
        isGeneratingFrame: Boolean = false,
        taskId: Long = handle.toLong(),
    ) = TransferTask(
        file = file(handle),
        taskId = taskId,
        status = status,
        isGeneratingFrame = isGeneratingFrame,
    )

    @Test
    fun latestTaskIndexKeepsTheNewestTaskForEachHandle() {
        val older = task(handle = 3, status = TransferStatus.WAITING, taskId = 3L)
        val other = task(handle = 4, status = TransferStatus.WAITING, taskId = 4L)
        val newer = older.copy(taskId = 103L, status = TransferStatus.COMPLETED)
        val tasks = listOf(older, other, newer)

        val index = buildLatestTaskIndexByHandle(tasks)

        assertEquals(newer, tasks[index.getValue(3)])
        assertEquals(other, tasks[index.getValue(4)])
    }

    @Test
    fun queuePillModePreservesTransferGenerationAndPausePriority() {
        assertEquals(PillMode.COUNTING, queuePillMode(8, 5))
        assertEquals(PillMode.GENERATING, queuePillMode(0, 5))
        assertEquals(PillMode.DONE, queuePillMode(0, 0))
        assertEquals(PillMode.PAUSED, queuePillMode(8, 0, paused = true))
    }

    @Test
    fun executionControlDependsOnRuntimeAndWaitingWork() {
        assertEquals(QueueExecutionControl.PAUSE, queueExecutionControl(true, 0))
        assertEquals(QueueExecutionControl.START, queueExecutionControl(false, 3))
        assertEquals(null, queueExecutionControl(false, 0))
    }

    @Test
    fun flightHoldsDelayOnlyCardsThatHaveNotLanded() {
        assertEquals(0, queuePillDisplayRemaining(actualRemaining = 24, heldCount = 24))
        assertEquals(0, queuePillDisplayRemaining(actualRemaining = 18, heldCount = 24))
        assertEquals(7, queuePillDisplayRemaining(actualRemaining = 27, heldCount = 20))
        assertEquals(1, queuePillDisplayRemaining(actualRemaining = 2, heldCount = 1))
        assertEquals(2, queuePillDisplayRemaining(actualRemaining = 2, heldCount = 0))
        assertEquals(0, queuePillDisplayRemaining(actualRemaining = 0, heldCount = 20))

        assertTrue(queuePillAllRemainingTasksAreInFlight(actualRemaining = 2, heldCount = 2))
        assertFalse(queuePillAllRemainingTasksAreInFlight(actualRemaining = 27, heldCount = 20))
        assertFalse(queuePillAllRemainingTasksAreInFlight(actualRemaining = 0, heldCount = 2))
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

        val summary = summarizeQueuePillTasks(listOf(waiting, generating, active, cancelled))

        assertEquals(2, summary.downloadRemaining)
        assertEquals(1, summary.generationRemaining)
        assertEquals(active.taskId, summary.activeDownloadTaskId)
        assertEquals(active.taskId, summary.activeProgressTaskId)
        assertTrue(summary.hasActive)
        assertTrue(summary.hasCancelled)
    }

    @Test
    fun completedTaskGeneratingAnEffectOwnsProgressAtFull() {
        val generating = task(
            handle = 1,
            status = TransferStatus.COMPLETED,
            isGeneratingFrame = true,
        )

        val summary = summarizeQueuePillTasks(listOf(generating))

        assertEquals(0, summary.downloadRemaining)
        assertEquals(1, summary.generationRemaining)
        assertEquals(generating.taskId, summary.activeProgressTaskId)
        assertTrue(summary.hasActive)
    }

    @Test
    fun removalDetectionIgnoresSurvivingAliasesAndScopesAffectedDates() {
        val removedOlderDay = file(1, day = "20260825")
        val removedNewerDay = file(2, day = "20260827")
        val survivingDay = file(3, day = "20260826")

        assertEquals(
            setOf("20260825", "20260827"),
            publishedCameraRemovalDates(
                previous = listOf(removedNewerDay, survivingDay, removedOlderDay),
                current = listOf(survivingDay),
            ),
        )
        assertEquals(
            emptySet(),
            publishedCameraRemovalDates(
                previous = listOf(survivingDay.copy(handle = 4)),
                current = listOf(survivingDay),
            ),
        )
        assertEquals(
            setOf(UNKNOWN_CAPTURE_DATE_GROUP_KEY),
            publishedCameraRemovalDates(
                previous = listOf(file(9, day = null)),
                current = emptyList(),
            ),
        )
    }

    @Test
    fun removalDetectionIgnoresEmptyBaselineAdditionsAndUnchangedRows() {
        val first = file(1)
        val second = file(2)

        assertEquals(emptySet(), publishedCameraRemovalDates(emptyList(), listOf(first)))
        assertEquals(emptySet(), publishedCameraRemovalDates(listOf(first), listOf(first, second)))
        assertEquals(emptySet(), publishedCameraRemovalDates(listOf(first, second), listOf(first, second)))
    }

    @Test
    fun removalDetectionReturnsTheDateOfTheMissingPublishedHandle() {
        val first = file(1)
        val second = file(2)

        assertEquals(setOf("20260827"), publishedCameraRemovalDates(listOf(first), listOf(second)))
        assertEquals(
            setOf("20260827"),
            publishedCameraRemovalDates(listOf(first, second), listOf(second)),
        )
    }

    @Test
    fun disconnectedFileListKeepsKnownTransportAndFallsBackToWifi() {
        assertEquals(
            CameraConnectionType.USB,
            disconnectedConnectionType(CameraConnectionType.USB),
        )
        assertEquals(
            CameraConnectionType.WIFI,
            disconnectedConnectionType(CameraConnectionType.WIFI),
        )
        assertEquals(CameraConnectionType.WIFI, disconnectedConnectionType(null))
    }
}
