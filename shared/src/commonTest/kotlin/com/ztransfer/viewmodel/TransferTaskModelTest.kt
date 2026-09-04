package com.ztransfer.viewmodel

import com.ztransfer.filter.NcpPhotoFilterParameters
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.protocol.CameraFileInfo
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TransferTaskModelTest {
    @Test
    fun frameTimingProgressAndRetryPreserveOriginalSemantics() {
        val original = task(1, taskId = 7L, status = TransferStatus.TRANSFERING)
        val started = original.startFrameGeneration(1_000L)
        val finished = started.finishFrameGeneration(26_250L)
        assertEquals(25_250L, finished.frameGenerationElapsedMs)
        assertFalse(finished.isGeneratingFrame)
        assertEquals(finished, finished.finishFrameGeneration(30_000L))

        val progress = ActiveTransferProgress(7L, fraction = 0.25f, downloaded = 25L, bytesPerSecond = 9L)
        val active = original.withActiveProgress(progress)
        assertEquals(0.25f, active.progress)
        assertEquals(25L, active.downloaded)
        assertEquals(9L, active.speed)

        val failed = finished.copy(
            status = TransferStatus.FAILED,
            error = "failed",
            skipped = true,
            progress = 1f,
        )
        val retry = failed.newAttempt(newTaskId = 8L)
        assertEquals(8L, retry.taskId)
        assertEquals(TransferStatus.WAITING, retry.status)
        assertEquals(0f, retry.progress)
        assertNull(retry.error)
        assertFalse(retry.skipped)
        assertEquals(failed.framePreset, retry.framePreset)
        assertEquals(failed.frameWatermarkRequested, retry.frameWatermarkRequested)
    }

    @Test
    fun plannerDeduplicatesAndSnapshotsEffectsAndDay() {
        var nextId = 10L
        val filter = PhotoFilterSelection(
            PhotoFilterPreset(
                "filter",
                "Filter",
                NcpPhotoFilterParameters(0, 0, IntArray(257) { it * 0x7fff / 256 }),
            ),
            79,
        )
        val tasks = createQueueTasks(
            files = listOf(file(1, "A.JPG", "20260810T010203"), file(1, "A.JPG", null), file(2, "B.NEF", null)),
            photoFrameEnabled = true,
            photoFrameBorderEnabled = false,
            photoFramePreset = PhotoFramePreset.CINEMA,
            photoFrameWatermark = PhotoFrameWatermark(text = "snapshot"),
            photoFilter = filter,
            organizeTransfersByDate = true,
            fallbackDayKey = 20260904,
            nextTaskId = { nextId++ },
        )

        assertEquals(listOf(10L, 11L), tasks.map(TransferTask::taskId))
        assertEquals(PhotoFramePreset.CINEMA, tasks[0].framePreset)
        assertNull(tasks[1].framePreset)
        assertEquals(filter, tasks[0].photoFilterRequested)
        assertNull(tasks[1].photoFilterRequested)
        assertEquals("ZT2026-08-10", tasks[0].destinationFolderName)
        assertEquals("ZT2026-09-04", tasks[1].destinationFolderName)
        assertFalse(tasks[0].frameBorderRequested)
    }

    @Test
    fun candidateAndTaskReducersKeepOrderAndTerminalRules() {
        val waiting = task(1, 1L, TransferStatus.WAITING)
        val active = task(2, 2L, TransferStatus.TRANSFERING)
        val failed = task(3, 3L, TransferStatus.FAILED)
        val generating = task(4, 4L, TransferStatus.COMPLETED).copy(isGeneratingFrame = true)
        val cancelled = task(5, 5L, TransferStatus.CANCELLED)
        val tasks = listOf(waiting, active, failed, generating, cancelled)

        val withdrawn = withdrawWaitingTransferTasks(tasks)
        assertEquals(TransferStatus.CANCELLED, withdrawn[0].status)
        assertEquals(tasks.drop(1), withdrawn.drop(1))
        assertEquals(listOf(waiting, active, generating), keepUnclearedTransferTasks(tasks))
        assertEquals(tasks, removeTransferTaskIfTerminal(tasks, active.taskId))
        assertEquals(tasks, removeTransferTaskIfTerminal(tasks, generating.taskId))
        assertEquals(listOf(waiting, active, generating, cancelled), removeTransferTaskIfTerminal(tasks, failed.taskId))

        val retry = failed.newAttempt(30L)
        assertEquals(
            listOf(waiting, active, retry, generating, cancelled),
            replaceRetryableTransferTasks(tasks, mapOf(failed.taskId to retry)),
        )
    }

    @Test
    fun automaticCandidatesDeduplicateBatchAndExistingQueue() {
        val queued = task(1, 1L, fileName = "A.JPG", captureDate = "20260904T010203")
        val same = file(8, "A.JPG", "20260904T010203")
        val fresh = file(2, "B.JPG", "20260904T020304")
        assertEquals(
            listOf(fresh),
            newMediaQueueCandidates(listOf(same, fresh, fresh.copy(handle = 3)), listOf(queued)),
        )
        assertEquals(2, normalizeThumbnailColumns(0))
        assertEquals(4, normalizeThumbnailColumns(9))
    }

    private fun task(
        handle: Int,
        taskId: Long,
        status: TransferStatus = TransferStatus.WAITING,
        fileName: String = "DSC_${handle}.JPG",
        captureDate: String? = null,
    ) = TransferTask(file(handle, fileName, captureDate), taskId, status = status)

    private fun file(handle: Int, name: String, captureDate: String?) = CameraFileInfo(
        handle = handle,
        fileName = name,
        size = 100L,
        captureDate = captureDate,
    )
}
