package com.ztransfer.ui.screen

import com.ztransfer.protocol.NikonCamera
import com.ztransfer.viewmodel.ActiveTransferProgress
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class QueueDownloadDisplayTest {
    private fun task(id: Long, status: TransferStatus = TransferStatus.TRANSFERING) = TransferTask(
        taskId = id,
        file = NikonCamera.FileInfo(handle = id.toInt(), size = 100L, fileName = "DSC_$id.JPG", captureDate = null),
        status = status,
    )

    @Test
    fun onlyAnActualDownloadCanOwnProgress() {
        val download = task(1)
        assertSame(download, queueDownloadActiveTask(download))
        assertNull(queueDownloadActiveTask(download.copy(isGeneratingFrame = true)))
        assertNull(queueDownloadActiveTask(download.copy(status = TransferStatus.WAITING)))
        assertNull(queueDownloadActiveTask(download.copy(status = TransferStatus.COMPLETED)))
        assertNull(queueDownloadActiveTask(null))
    }

    @Test
    fun currentFileUsesItsLiveProgressButNeverAnotherFilesSample() {
        val active = task(1).copy(progress = 0.2f)
        assertEquals(0.7f, queueDownloadTargetProgress(active, ActiveTransferProgress(1, fraction = 0.7f)), 0f)
        assertEquals(0.2f, queueDownloadTargetProgress(active, ActiveTransferProgress(2, fraction = 1f)), 0f)
        assertEquals(0.2f, queueDownloadTargetProgress(active, null), 0f)
    }

    @Test
    fun pausedWaitingAndLocalGenerationCannotReuseOldFullProgress() {
        val oldFull = ActiveTransferProgress(1, fraction = 1f)
        val old = task(1)
        for (inactive in listOf(null, old.copy(status = TransferStatus.WAITING),
            old.copy(status = TransferStatus.COMPLETED, isGeneratingFrame = true),
            old.copy(isGeneratingFrame = true))) {
            assertEquals(0f, queueDownloadTargetProgress(inactive, oldFull), 0f)
        }
    }

    @Test
    fun protocolProgressIsClampedWithoutInventingCompletion() {
        val active = task(1)
        for ((raw, expected) in listOf(-0.5f to 0f, 1.5f to 1f, Float.NaN to 0f, Float.POSITIVE_INFINITY to 0f)) {
            assertEquals(expected,
                queueDownloadTargetProgress(active, ActiveTransferProgress(1, fraction = raw)), 0f)
        }
    }

    @Test
    fun successfulVisibleFileFinishesEvenIfTheNextDownloadAlreadyStarted() {
        val completed = task(1, TransferStatus.COMPLETED).copy(
            elapsedMs = 20, downloadMBps = 50f, progress = 1f,
        )
        val next = task(2)
        assertSame(completed, queueDownloadCompletedTask(1, next, listOf(completed, next)))
    }

    @Test
    fun successfulVisibleDownloadFinishesWhenItHandsOffToEffects() {
        val generating = task(1, TransferStatus.COMPLETED).copy(isGeneratingFrame = true)
        assertSame(generating, queueDownloadCompletedTask(1, null, listOf(generating)))
    }

    @Test
    fun legacyCropHandoffFinishesTheObservedDownloadOnly() {
        val crop = task(1).copy(isGeneratingFrame = true)
        assertSame(crop, queueDownloadCompletedTask(1, crop, listOf(crop)))
        // Starting directly in the local generation phase never fabricates a completed download.
        assertNull(queueDownloadCompletedTask(null, crop, listOf(crop)))
    }

    @Test
    fun failedCancelledMissingAndStillRunningFilesNeverFillToFull() {
        for (status in listOf(TransferStatus.FAILED, TransferStatus.CANCELLED, TransferStatus.WAITING,
            TransferStatus.TRANSFERING)) {
            val old = task(1, status)
            assertNull(queueDownloadCompletedTask(1, task(2), listOf(old)))
        }
        assertNull(queueDownloadCompletedTask(1, null, emptyList()))
    }

    @Test
    fun unchangedCurrentFileDoesNotStartCompletionBecauseAnotherFileFinished() {
        val active = task(1)
        val completed = task(2, TransferStatus.COMPLETED)
        assertNull(queueDownloadCompletedTask(1, active, listOf(active, completed)))
    }

    @Test
    fun pureGenerationHasNoRememberedDownloadToComplete() {
        val local = task(1, TransferStatus.COMPLETED).copy(isGeneratingFrame = true)
        assertNull(queueDownloadCompletedTask(null, null, listOf(local)))
        assertNull(queueDownloadCompletedTask(null, null, listOf(local.copy(isGeneratingFrame = false))))
    }

    @Test
    fun completionUsesTheLatestSnapshotAndDoesNotMistakeAnEffectFailureForDownloadFailure() {
        val latest = task(1, TransferStatus.COMPLETED).copy(
            elapsedMs = 34, downloadMBps = 25f, frameGenerationError = "effect save failed",
        )
        assertSame(latest, queueDownloadCompletedTask(1, null, listOf(latest)))
    }

    @Test
    fun cancelledHistoryDoesNotSuppressASuccessfulFilesOwnFinish() {
        val cancelled = task(1, TransferStatus.CANCELLED)
        val completed = task(2, TransferStatus.COMPLETED)
        val tasks = listOf(cancelled, completed)
        assertSame(completed, queueDownloadCompletedTask(2, null, tasks))
        assertNull(queueDownloadCompletedTask(1, null, tasks))
    }

    @Test
    fun retryIdentityCannotCompleteOrAdvanceThePreviousAttempt() {
        val failed = task(1, TransferStatus.FAILED)
        val retry = failed.copy(taskId = 2, status = TransferStatus.TRANSFERING, progress = 0.05f)
        assertNull(queueDownloadCompletedTask(1, retry, listOf(retry)))
        assertEquals(0.05f,
            queueDownloadTargetProgress(retry, ActiveTransferProgress(1, fraction = 1f)), 0f)
    }
}
