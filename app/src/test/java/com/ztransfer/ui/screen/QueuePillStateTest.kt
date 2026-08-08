package com.ztransfer.ui.screen

import org.junit.Assert.assertEquals
import org.junit.Test

class QueuePillStateTest {
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
    fun flightHoldCannotMakeANonEmptyQueueLookEmpty() {
        assertEquals(24, queuePillDisplayRemaining(actualRemaining = 24, heldCount = 24))
        assertEquals(18, queuePillDisplayRemaining(actualRemaining = 18, heldCount = 24))
    }

    @Test
    fun flightHoldStillDelaysOnlyTheNewlyAddedPartOfAnExistingQueue() {
        assertEquals(7, queuePillDisplayRemaining(actualRemaining = 27, heldCount = 20))
    }

    @Test
    fun genuinelyEmptyQueueStillDisplaysZero() {
        assertEquals(0, queuePillDisplayRemaining(actualRemaining = 0, heldCount = 20))
    }
}
