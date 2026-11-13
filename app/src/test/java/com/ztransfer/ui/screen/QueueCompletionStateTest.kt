package com.ztransfer.ui.screen

import com.ztransfer.protocol.NikonCamera
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class QueueCompletionStateTest {
    private fun task(id: Long, status: TransferStatus = TransferStatus.WAITING) = TransferTask(
        taskId = id,
        file = NikonCamera.FileInfo(
            handle = id.toInt(),
            size = 100L,
            fileName = "DSC_$id.JPG",
            captureDate = null,
        ),
        status = status,
    )

    private fun successful(task: TransferTask) = task.copy(
        status = TransferStatus.COMPLETED,
        progress = 1f,
        elapsedMs = 20L,
    )

    private fun observe(vararg tasks: TransferTask) =
        queueCompletionUpdate(QueueCompletionState(), tasks.toList()).nextState

    private fun assertBatchReset(state: QueueCompletionState, knownIds: Set<Long>) {
        assertTrue(state.unresolvedTaskIds.isEmpty())
        assertFalse(state.hadUnsuccessfulResult)
        assertFalse(state.didRealWork)
        assertEquals(knownIds, state.knownTaskIds)
    }

    @Test
    fun initialIdleAndTerminalHistoryDoNotEmitCompletion() {
        for (history in listOf(
            emptyList(),
            listOf(successful(task(1))),
            listOf(task(1, TransferStatus.FAILED), task(2, TransferStatus.CANCELLED)),
            listOf(task(1, TransferStatus.COMPLETED).copy(frameGenerationError = "Failed")),
        )) {
            val update = queueCompletionUpdate(QueueCompletionState(), history)
            assertBatchReset(update.nextState, history.map { it.taskId }.toSet())
            assertNull(update.completion)
        }
    }

    @Test
    fun aSuccessfulDownloadEmitsOnceAndResetsTheBatch() {
        val waiting = task(1)
        val active = waiting.copy(status = TransferStatus.TRANSFERING)
        val started = queueCompletionUpdate(observe(waiting), listOf(active))
        assertNull(started.completion)
        val completed = successful(active)
        val finished = queueCompletionUpdate(started.nextState, listOf(completed))
        assertEquals(QueueCompletionFeedback(showDone = true, celebrate = true), finished.completion)
        assertBatchReset(finished.nextState, setOf(completed.taskId))
        repeat(3) {
            assertNull(queueCompletionUpdate(finished.nextState, listOf(completed)).completion)
        }
    }

    @Test
    fun allSkippedDownloadsShowDoneWithoutCelebration() {
        val waiting = task(1)
        val skipped = waiting.copy(status = TransferStatus.COMPLETED, skipped = true)
        val update = queueCompletionUpdate(observe(waiting), listOf(skipped))
        assertEquals(QueueCompletionFeedback(showDone = true, celebrate = false), update.completion)
    }

    @Test
    fun queuedOrStartedGenerationThatOnlyFindsAnExistingOutputDoesNotCelebrate() {
        val queued = task(1, TransferStatus.COMPLETED).copy(isGeneratingFrame = true)
        for (pending in listOf(queued, queued.copy(frameGenerationStartedAtElapsedMs = 100L))) {
            val skipped = pending.copy(
                isGeneratingFrame = false,
                frameGenerationStartedAtElapsedMs = null,
                skipped = true,
                frameGenerationSkipped = true,
            )
            val update = queueCompletionUpdate(observe(pending), listOf(skipped))
            assertEquals(QueueCompletionFeedback(showDone = true, celebrate = false), update.completion)
        }
    }

    @Test
    fun downloadedBytesStillCountWhenTheFollowingGenerationIsSkipped() {
        val generating = successful(task(1)).copy(isGeneratingFrame = true)
        val completed = generating.copy(isGeneratingFrame = false, skipped = true)
        val update = queueCompletionUpdate(observe(generating), listOf(completed))
        assertEquals(QueueCompletionFeedback(showDone = true, celebrate = true), update.completion)
    }

    @Test
    fun savedGenerationWithoutADownloadCanCelebrate() {
        val generating = task(1, TransferStatus.COMPLETED).copy(isGeneratingFrame = true)
        val completed = generating.copy(isGeneratingFrame = false, frameGenerationElapsedMs = 0L)
        val update = queueCompletionUpdate(observe(generating), listOf(completed))
        assertEquals(QueueCompletionFeedback(showDone = true, celebrate = true), update.completion)
    }

    @Test
    fun aFailedDownloadDoesNotShowDoneOrCelebrate() {
        val active = task(1, TransferStatus.TRANSFERING)
        val failed = active.copy(status = TransferStatus.FAILED)
        val update = queueCompletionUpdate(observe(active), listOf(failed))
        assertEquals(QueueCompletionFeedback(showDone = false, celebrate = false), update.completion)
    }

    @Test
    fun failedGenerationCannotCelebrateTheSuccessfulOriginalDownload() {
        val generating = successful(task(1)).copy(isGeneratingFrame = true)
        val failed = generating.copy(isGeneratingFrame = false, frameGenerationError = "Failed")
        val update = queueCompletionUpdate(observe(generating), listOf(failed))
        assertEquals(QueueCompletionFeedback(showDone = false, celebrate = false), update.completion)
    }

    @Test
    fun cancelledOrFailedMembersKeepTheBatchUnsuccessfulAfterTheirCardsAreRemoved() {
        val waiting = task(1)
        val active = task(2, TransferStatus.TRANSFERING)
        for (status in listOf(TransferStatus.CANCELLED, TransferStatus.FAILED)) {
            val resolved = queueCompletionUpdate(
                observe(waiting, active),
                listOf(waiting.copy(status = status), active),
            )
            assertNull(resolved.completion)
            assertTrue(resolved.nextState.hadUnsuccessfulResult)
            assertEquals(setOf(active.taskId), resolved.nextState.unresolvedTaskIds)
            val cleared = queueCompletionUpdate(resolved.nextState, listOf(active))
            val finished = queueCompletionUpdate(cleared.nextState, listOf(successful(active)))
            assertEquals(QueueCompletionFeedback(showDone = false, celebrate = false), finished.completion)
        }
    }

    @Test
    fun successfulRemovedMembersKeepTheirRealWorkEvidence() {
        val active = task(1, TransferStatus.TRANSFERING)
        val waiting = task(2)
        val resolved = queueCompletionUpdate(observe(active, waiting), listOf(successful(active), waiting))
        assertEquals(setOf(waiting.taskId), resolved.nextState.unresolvedTaskIds)
        assertTrue(resolved.nextState.didRealWork)
        val removed = queueCompletionUpdate(resolved.nextState, listOf(waiting))
        val skipped = waiting.copy(status = TransferStatus.COMPLETED, skipped = true)
        val finished = queueCompletionUpdate(removed.nextState, listOf(skipped))
        assertEquals(QueueCompletionFeedback(showDone = true, celebrate = true), finished.completion)
    }

    @Test
    fun missingUnresolvedWorkCannotBecomeASuccessfulCompletion() {
        val waiting = task(1)
        val update = queueCompletionUpdate(observe(waiting), emptyList())
        assertEquals(QueueCompletionFeedback(showDone = false, celebrate = false), update.completion)
        assertBatchReset(update.nextState, emptySet())
    }

    @Test
    fun missingMemberRemainsUnsuccessfulUntilTheRestOfTheBatchFinishes() {
        val waiting = task(1)
        val active = task(2, TransferStatus.TRANSFERING)
        val missing = queueCompletionUpdate(observe(waiting, active), listOf(active))
        assertNull(missing.completion)
        assertTrue(missing.nextState.hadUnsuccessfulResult)
        val finished = queueCompletionUpdate(missing.nextState, listOf(successful(active)))
        assertEquals(QueueCompletionFeedback(showDone = false, celebrate = false), finished.completion)
    }

    @Test
    fun unrelatedHistoricalFailuresAndCancellationsDoNotSuppressANewBatch() {
        val history = listOf(
            task(10, TransferStatus.FAILED),
            task(11, TransferStatus.CANCELLED),
            task(12, TransferStatus.COMPLETED).copy(frameGenerationError = "Old failure"),
        )
        val active = task(1, TransferStatus.TRANSFERING)
        val started = queueCompletionUpdate(QueueCompletionState(), history + active)
        assertEquals(setOf(active.taskId), started.nextState.unresolvedTaskIds)
        val finished = queueCompletionUpdate(started.nextState, history + successful(active))
        assertEquals(QueueCompletionFeedback(showDone = true, celebrate = true), finished.completion)
    }

    @Test
    fun aNewBatchDoesNotInheritFailureOrWorkEvidence() {
        val active = task(1, TransferStatus.TRANSFERING)
        val cancelled = task(2)
        val failedBatch = queueCompletionUpdate(
            observe(active, cancelled),
            listOf(successful(active), cancelled.copy(status = TransferStatus.CANCELLED)),
        )
        assertEquals(QueueCompletionFeedback(showDone = false, celebrate = false), failedBatch.completion)
        val next = task(3)
        val nextBatch = queueCompletionUpdate(failedBatch.nextState, listOf(next))
        assertFalse(nextBatch.nextState.hadUnsuccessfulResult)
        assertFalse(nextBatch.nextState.didRealWork)
        val finished = queueCompletionUpdate(nextBatch.nextState,
            listOf(next.copy(status = TransferStatus.COMPLETED, skipped = true)))
        assertEquals(QueueCompletionFeedback(showDone = true, celebrate = false), finished.completion)
    }

    @Test
    fun pausesAndGenerationHandoffsKeepTheSameBatchOpen() {
        val waiting = task(1)
        val initial = observe(waiting)
        assertEquals(initial, queueCompletionUpdate(initial, listOf(waiting)).nextState)
        val generating = successful(waiting).copy(isGeneratingFrame = true)
        val handoff = queueCompletionUpdate(initial, listOf(generating))
        assertNull(handoff.completion)
        assertEquals(setOf(waiting.taskId), handoff.nextState.unresolvedTaskIds)
        val finished = queueCompletionUpdate(handoff.nextState,
            listOf(generating.copy(isGeneratingFrame = false, frameGenerationElapsedMs = 30L)))
        assertEquals(QueueCompletionFeedback(showDone = true, celebrate = true), finished.completion)
    }

    @Test
    fun newTasksJoinAnUnfinishedBatchWithoutReplayingCompletion() {
        val active = task(1, TransferStatus.TRANSFERING)
        val next = task(2)
        val handoff = queueCompletionUpdate(observe(active), listOf(successful(active), next))
        assertNull(handoff.completion)
        assertEquals(setOf(next.taskId), handoff.nextState.unresolvedTaskIds)
        assertTrue(handoff.nextState.didRealWork)
        val finished = queueCompletionUpdate(handoff.nextState, listOf(successful(active), successful(next)))
        assertEquals(QueueCompletionFeedback(showDone = true, celebrate = true), finished.completion)
    }

    @Test
    fun firstSeenFailedMemberKeepsAnOpenBatchUnsuccessfulAfterRemoval() {
        val generating = task(1, TransferStatus.COMPLETED).copy(isGeneratingFrame = true)
        val failed = task(2, TransferStatus.FAILED)
        val coalesced = queueCompletionUpdate(observe(generating), listOf(generating, failed))
        assertNull(coalesced.completion)
        assertTrue(coalesced.nextState.hadUnsuccessfulResult)
        assertEquals(setOf(1L, 2L), coalesced.nextState.knownTaskIds)

        val removed = queueCompletionUpdate(coalesced.nextState, listOf(generating))
        assertEquals(setOf(1L), removed.nextState.knownTaskIds)
        val finished = queueCompletionUpdate(removed.nextState,
            listOf(generating.copy(isGeneratingFrame = false, frameGenerationElapsedMs = 20L)))
        assertEquals(QueueCompletionFeedback(showDone = false, celebrate = false), finished.completion)
        assertBatchReset(finished.nextState, setOf(1L))
    }

    @Test
    fun firstSeenGenerationFailureCountsWhenTheLastObservedMemberFinishes() {
        val active = task(1, TransferStatus.TRANSFERING)
        val failedGeneration = successful(task(2)).copy(frameGenerationError = "Save failed")
        val finished = queueCompletionUpdate(observe(active), listOf(successful(active), failedGeneration))
        assertEquals(QueueCompletionFeedback(showDone = false, celebrate = false), finished.completion)
        assertBatchReset(finished.nextState, setOf(1L, 2L))
    }

    @Test
    fun firstSeenTerminalMemberCountsAlongsideANewUnfinishedMember() {
        val active = task(1, TransferStatus.TRANSFERING)
        val failed = task(2, TransferStatus.FAILED)
        val next = task(3)
        // Put the new unfinished member after the terminal result to verify order independence.
        val joined = queueCompletionUpdate(observe(active), listOf(successful(active), failed, next))
        assertNull(joined.completion)
        assertTrue(joined.nextState.hadUnsuccessfulResult)
        assertEquals(setOf(3L), joined.nextState.unresolvedTaskIds)
        val finished = queueCompletionUpdate(joined.nextState, listOf(successful(next)))
        assertEquals(QueueCompletionFeedback(showDone = false, celebrate = false), finished.completion)
    }

    @Test
    fun firstSeenSuccessfulTerminalMemberSuppliesRealWorkEvidence() {
        val waiting = task(1)
        val skipped = waiting.copy(status = TransferStatus.COMPLETED, skipped = true)
        for (completed in listOf(
            successful(task(2)),
            task(2, TransferStatus.COMPLETED).copy(frameGenerationElapsedMs = 0L),
        )) {
            val finished = queueCompletionUpdate(observe(waiting), listOf(skipped, completed))
            assertEquals(QueueCompletionFeedback(showDone = true, celebrate = true), finished.completion)
            assertBatchReset(finished.nextState, setOf(1L, 2L))
        }
    }

    @Test
    fun taskPublicationOrderDoesNotHaveToMatchIdAllocationOrder() {
        val oldFailure = task(100, TransferStatus.FAILED)
        val active = task(20, TransferStatus.TRANSFERING)
        val initial = observe(oldFailure, active)
        // A background producer allocated this ID earlier but publishes it after ID 100.
        val lateFailure = task(10, TransferStatus.FAILED)
        val finished = queueCompletionUpdate(initial, listOf(oldFailure, successful(active), lateFailure))
        assertEquals(QueueCompletionFeedback(showDone = false, celebrate = false), finished.completion)
        assertBatchReset(finished.nextState, setOf(10L, 20L, 100L))
    }

    @Test
    fun idleFirstSeenTerminalTasksOnlyRefreshTheHistoryBaseline() {
        val idle = observe(task(1, TransferStatus.FAILED))
        for (terminal in listOf(
            successful(task(2)),
            task(2, TransferStatus.FAILED),
            task(2, TransferStatus.COMPLETED).copy(frameGenerationError = "Save failed"),
        )) {
            val added = queueCompletionUpdate(idle, listOf(terminal))
            assertNull(added.completion)
            assertBatchReset(added.nextState, setOf(2L))
            val active = task(3, TransferStatus.TRANSFERING)
            val started = queueCompletionUpdate(added.nextState, listOf(terminal, active))
            val finished = queueCompletionUpdate(started.nextState, listOf(terminal, successful(active)))
            assertEquals(QueueCompletionFeedback(showDone = true, celebrate = true), finished.completion)
        }
    }

    @Test
    fun aNewBatchCanFirstAppearWithOneAlreadyFailedMember() {
        val idle = queueCompletionUpdate(QueueCompletionState(), emptyList()).nextState
        val failed = task(1, TransferStatus.FAILED)
        val active = task(2, TransferStatus.TRANSFERING)
        for (snapshot in listOf(listOf(failed, active), listOf(active, failed))) {
            val started = queueCompletionUpdate(idle, snapshot)
            assertNull(started.completion)
            assertTrue(started.nextState.hadUnsuccessfulResult)
            val finished = queueCompletionUpdate(started.nextState, listOf(failed, successful(active)))
            assertEquals(QueueCompletionFeedback(showDone = false, celebrate = false), finished.completion)
        }
    }
}
