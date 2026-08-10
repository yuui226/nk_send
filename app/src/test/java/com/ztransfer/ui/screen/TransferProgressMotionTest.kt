package com.ztransfer.ui.screen

import org.junit.Assert.assertEquals
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
}
