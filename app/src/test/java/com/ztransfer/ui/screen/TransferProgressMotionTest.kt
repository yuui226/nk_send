package com.ztransfer.ui.screen

import com.ztransfer.viewmodel.TransferStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferProgressMotionTest {

    @Test
    fun progressIsClampedToRenderableRange() {
        assertEquals(0f, normalizedTransferProgress(-0.2f))
        assertEquals(0.45f, normalizedTransferProgress(0.45f))
        assertEquals(1f, normalizedTransferProgress(1.2f))
    }

    @Test
    fun invalidProgressFallsBackToEmpty() {
        assertEquals(0f, normalizedTransferProgress(Float.NaN))
        assertEquals(0f, normalizedTransferProgress(Float.POSITIVE_INFINITY))
        assertEquals(0f, normalizedTransferProgress(Float.NEGATIVE_INFINITY))
    }

    @Test
    fun cardOnlyFillsToCompletionForSuccessfulTransfer() {
        assertEquals(0.62f, transferCardProgressTarget(TransferStatus.TRANSFERING, 0.62f))
        assertEquals(1f, transferCardProgressTarget(TransferStatus.COMPLETED, 0.62f))
        assertEquals(0.62f, transferCardProgressTarget(TransferStatus.FAILED, 0.62f))
        assertEquals(0.62f, transferCardProgressTarget(TransferStatus.CANCELLED, 0.62f))
    }

    @Test
    fun cardWaveContinuesOnlyThroughSuccessfulCompletion() {
        assertTrue(transferCardWaveEligible(TransferStatus.TRANSFERING))
        assertTrue(transferCardWaveEligible(TransferStatus.COMPLETED))
        assertFalse(transferCardWaveEligible(TransferStatus.WAITING))
        assertFalse(transferCardWaveEligible(TransferStatus.FAILED))
        assertFalse(transferCardWaveEligible(TransferStatus.CANCELLED))
    }
}
