package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class FileScanBatchSizeTest {
    @Test fun firstFourThenAdaptiveBatches() {
        assertEquals(1, fileScanBatchSize(0, 12, true))
        assertEquals(3, fileScanBatchSize(1, 12, true))
        assertEquals(2, fileScanBatchSize(2, 12, true))
        assertEquals(12, fileScanBatchSize(4, 12, true))
        assertEquals(24, fileScanBatchSize(16, 24, true))
        assertEquals(48, fileScanBatchSize(40, 48, true))
    }
    @Test fun ordinaryAndSingleObjectReadsKeepRequestedSize() {
        assertEquals(20, fileScanBatchSize(0, 20, false))
        assertEquals(1, fileScanBatchSize(1, 1, true))
    }
}
