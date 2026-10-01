package com.ztransfer.viewmodel

import org.junit.Assert.assertEquals
import org.junit.Test

class CachedThumbnailBatchPolicyTest {
    @Test fun warmScanGrowsWithinLimitThenColdBatchRestoresResponsiveness() {
        val policy = CachedThumbnailBatchPolicy()
        assertEquals(12, policy.size)
        policy.complete(12, true)
        assertEquals(24, policy.size)
        policy.complete(24, true)
        assertEquals(48, policy.size)
        repeat(10) { policy.complete(48, true) }
        assertEquals(48, policy.size)
        policy.complete(48, false)
        assertEquals(12, policy.size)
        policy.complete(12, true)
        assertEquals(24, policy.size)
    }

    @Test fun staWarmupIncompleteAndInterruptedBatchesDoNotAccelerate() {
        val policy = CachedThumbnailBatchPolicy()
        for (count in listOf(1, 3, 0, 11)) {
            policy.complete(count, true)
            assertEquals(12, policy.size)
        }
        policy.complete(12, true)
        policy.complete(0, false)
        assertEquals(12, policy.size)
    }
}
