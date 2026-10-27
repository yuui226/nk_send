package com.ztransfer.ui.screen

import com.ztransfer.protocol.NikonCamera
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class GenerationQueueRowsTest {
    private fun task(id: Long) = TransferTask(
        taskId = id,
        file = NikonCamera.FileInfo(id.toInt(), 100L, "DSC_$id.JPG", captureDate = null),
        status = TransferStatus.COMPLETED,
        isGeneratingFrame = true,
    )

    private fun TransferTask.finished(elapsed: Long = 100) = copy(
        isGeneratingFrame = false,
        frameGenerationStartedAtElapsedMs = null,
        frameGenerationElapsedMs = elapsed,
    )

    private fun List<GenerationRowSnapshot>.residents() = filterNot { it.phase.retiring }

    @Test
    fun successfulFirstRowHoldsThenSurvivorAndWaitingQueueMoveUp() {
        val pending = (1L..6L).map(::task)
        val initial = generationRowSnapshots(emptyList(), pending)
        val finished = pending[0].finished(1250)
        val holding = generationRowSnapshots(initial, pending.drop(1), listOf(finished) + pending.drop(1))

        assertEquals(listOf(1L, 2L, 3L), holding.residents().map { it.task.taskId })
        assertEquals(GenerationRowPhase.SUCCEEDED, holding.first().phase)
        assertSame(finished, holding.first().task)
        assertEquals(1250L, holding.first().task.frameGenerationElapsedMs)
        val advanced = finishGenerationRowPhase(holding, 1, GenerationRowPhase.SUCCEEDED)
        val moving = generationRowSnapshots(advanced, pending.drop(1), listOf(finished) + pending.drop(1))

        assertEquals(listOf(2L, 3L, 4L), moving.residents().map { it.task.taskId })
        assertEquals(listOf(0, 1, 2), moving.residents().map { it.position })
        assertEquals(GenerationRowPhase.EXITING_SUCCESS, moving.single { it.task.taskId == 1L }.phase)
        val removed = finishGenerationRowPhase(moving, 1, GenerationRowPhase.EXITING_SUCCESS)
        assertEquals(listOf(2L, 3L, 4L), removed.map { it.task.taskId })
    }

    @Test
    fun secondCompletionLeavesFirstInTopRowAndAdmitsNextWaitingItemAfterHold() {
        val pending = (1L..4L).map(::task)
        val initial = generationRowSnapshots(emptyList(), pending)
        val finishedSecond = pending[1].finished()
        val active = listOf(pending[0]) + pending.drop(2)
        val holding = generationRowSnapshots(initial, active, active + finishedSecond)
        assertEquals(listOf(1L, 2L, 3L), holding.residents().map { it.task.taskId })
        assertEquals(GenerationRowPhase.SUCCEEDED, holding.single { it.task.taskId == 2L }.phase)

        val advanced = finishGenerationRowPhase(holding, 2, GenerationRowPhase.SUCCEEDED)
        val moving = generationRowSnapshots(advanced, active, active + finishedSecond)
        assertEquals(0, moving.single { it.task.taskId == 1L }.position)
        assertEquals(listOf(1L, 3L, 4L), moving.residents().map { it.task.taskId })
    }

    @Test
    fun actualRunningPriorityAndLatestMetadataFollowTheAuthoritativeQueue() {
        val pending = (1L..4L).map(::task)
        val initial = generationRowSnapshots(emptyList(), pending)
        val running = pending[3].copy(frameGenerationStartedAtElapsedMs = 100L)
        val changed = generationRowSnapshots(initial, listOf(running) + pending.take(3))

        assertEquals(listOf(4L, 1L, 2L), changed.residents().map { it.task.taskId })
        assertSame(running, changed.residents().first().task)
        assertTrue(changed.none { it.phase.completed })
    }

    @Test
    fun metadataUpdatesDoNotReplaySuccessOrChangeFrozenDuration() {
        val running = task(1)
        val initial = generationRowSnapshots(emptyList(), listOf(running))
        val finished = running.finished(750)
        val holding = generationRowSnapshots(initial, emptyList(), listOf(finished))
        repeat(10) {
            val unchanged = generationRowSnapshots(holding, emptyList(), listOf(finished.finished(999)))
            assertEquals(holding, unchanged)
            assertEquals(750L, unchanged.single().task.frameGenerationElapsedMs)
        }
        val exiting = finishGenerationRowPhase(holding, 1, GenerationRowPhase.SUCCEEDED)
        assertEquals(GenerationRowPhase.EXITING_SUCCESS,
            generationRowSnapshots(exiting, emptyList(), listOf(finished)).single().phase)
        val removed = finishGenerationRowPhase(exiting, 1, GenerationRowPhase.EXITING_SUCCESS)
        assertTrue(generationRowSnapshots(removed, emptyList(), listOf(finished)).isEmpty())
    }

    @Test
    fun fastQueueNeverRendersAllWaitingJobsOrReplaysInvisibleCompletions() {
        val pending = (1L..1000L).map(::task)
        var rows = generationRowSnapshots(emptyList(), pending)
        assertEquals(listOf(1L, 2L, 3L), rows.map { it.task.taskId })
        for (next in 4L..100L step 3) {
            val current = pending.filter { it.taskId >= next }
            val all = pending.map { if (it.taskId < next) it.finished() else it }
            rows = generationRowSnapshots(rows, current, all)
            assertTrue(rows.size <= 5)
            assertTrue(rows.residents().size <= 3)
            assertTrue(rows.count { it.phase.retiring } <= 2)
            assertEquals(rows.size, rows.map { it.task.taskId }.distinct().size)
            assertFalse(rows.any { it.task.taskId == next - 1 && it.phase.completed })
            for (success in rows.filter { it.phase == GenerationRowPhase.SUCCEEDED }) {
                rows = finishGenerationRowPhase(rows, success.task.taskId, success.phase)
            }
            rows = generationRowSnapshots(rows, current, all)
            assertEquals(current.take(3).map { it.taskId }, rows.residents().map { it.task.taskId })
            for (exit in rows.filter { it.phase.retiring }) {
                rows = finishGenerationRowPhase(rows, exit.task.taskId, exit.phase)
            }
        }
    }

    @Test
    fun thirdPrefetchedItemCanFinishWithoutCreatingAnInvisibleSuccessHold() {
        val pending = (1L..4L).map(::task)
        val initial = generationRowSnapshots(emptyList(), pending)
        val active = listOf(pending[0], pending[1], pending[3])
        val changed = generationRowSnapshots(initial, active, active + pending[2].finished())

        assertEquals(listOf(1L, 2L, 4L), changed.map { it.task.taskId })
        assertTrue(changed.all { it.phase == GenerationRowPhase.ACTIVE })
    }

    @Test
    fun failureCancellationSkippingAndMissingTerminalDataNeverTurnGreen() {
        val running = task(1).copy(frameGenerationStartedAtElapsedMs = 100L)
        val initial = generationRowSnapshots(emptyList(), listOf(running))
        val cases = listOf(
            listOf(running.finished().copy(frameGenerationError = "failed")),
            listOf(running.finished().copy(status = TransferStatus.CANCELLED)),
            listOf(running.finished().copy(frameGenerationSkipped = true)),
            listOf(running.finished().copy(status = TransferStatus.FAILED, error = "failed")),
            emptyList(),
        )
        for (all in cases) {
            val changed = generationRowSnapshots(initial, emptyList(), all)
            assertEquals(GenerationRowPhase.EXITING, changed.single().phase)
            assertFalse(changed.single().phase.completed)
            assertTrue(changed.single().phase.frozen)
        }
    }

    @Test
    fun exitWithoutFinalElapsedRetainsOldClockThenAcceptsOneFinalDuration() {
        val running = task(1).copy(frameGenerationStartedAtElapsedMs = 100L)
        val initial = generationRowSnapshots(emptyList(), listOf(running))
        val failed = running.copy(isGeneratingFrame = false, frameGenerationStartedAtElapsedMs = null,
            frameGenerationError = "failed")
        val changed = generationRowSnapshots(initial, emptyList(), listOf(failed))
        assertSame(running, changed.single().task)
        val final = failed.copy(frameGenerationElapsedMs = 420)
        val finalized = generationRowSnapshots(changed, emptyList(), listOf(final))
        assertSame(final, finalized.single().task)
        assertEquals(GenerationRowPhase.EXITING, finalized.single().phase)
        assertEquals(finalized,
            generationRowSnapshots(finalized, emptyList(), listOf(final.copy(frameGenerationElapsedMs = 999))))
    }

    @Test
    fun retryDuringHoldOrExitIgnoresThePreviousAnimationCallback() {
        val original = task(1).copy(frameGenerationStartedAtElapsedMs = 100L)
        val initial = generationRowSnapshots(emptyList(), listOf(original))
        val finished = original.finished()
        val holding = generationRowSnapshots(initial, emptyList(), listOf(finished))
        val exiting = finishGenerationRowPhase(holding, 1, GenerationRowPhase.SUCCEEDED)
        val retried = original.copy(frameGenerationStartedAtElapsedMs = 200L)
        for (oldRows in listOf(holding, exiting)) {
            val changed = generationRowSnapshots(oldRows, listOf(retried))
            assertEquals(listOf(GenerationRowSnapshot(retried, 0)), changed)
            assertEquals(changed, finishGenerationRowPhase(changed, 1, oldRows.single().phase))
        }
    }

    @Test
    fun clearingQueueWithoutTerminalResultsExitsWithoutInventingCompletion() {
        val pending = (1L..6L).map(::task)
        val initial = generationRowSnapshots(emptyList(), pending)
        var rows = generationRowSnapshots(initial, emptyList(), emptyList())
        assertEquals(listOf(1L, 2L), rows.map { it.task.taskId })
        assertTrue(rows.all { it.phase == GenerationRowPhase.EXITING })
        for (row in rows.toList()) rows = finishGenerationRowPhase(rows, row.task.taskId, row.phase)
        assertTrue(generationRowSnapshots(rows, emptyList(), pending.map { it.finished() }).isEmpty())
    }

    @Test
    fun alreadyTerminalHistoryDoesNotCreateInitialGreenRows() {
        val terminal = (1L..6L).map { task(it).finished() }
        assertTrue(generationRowSnapshots(emptyList(), emptyList(), terminal).isEmpty())
    }

    @Test
    fun genuineEffectSuccessAllowsSkippedOriginalAndZeroMillisecondDuration() {
        val completed = task(1).finished(0).copy(skipped = true)
        assertTrue(generationReallyCompleted(completed))
        assertFalse(generationReallyCompleted(completed.copy(frameGenerationSkipped = true)))
        assertFalse(generationReallyCompleted(completed.copy(frameGenerationElapsedMs = null)))
    }
}
