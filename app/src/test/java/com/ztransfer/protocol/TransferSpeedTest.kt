package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class TransferSpeedTest {
    @Test
    fun speedMatchesTheUserVisibleEndToEndDuration() {
        assertEquals(
            2_478_452L,
            endToEndBytesPerSecond(
                transferredBytes = 26L * 1024L * 1024L,
                elapsedMs = 11_000L,
            ),
        )
    }

    @Test
    fun speedIncludesProtocolAndStorageWaitingTime() {
        assertEquals(
            4L * 1024L * 1024L,
            endToEndBytesPerSecond(
                transferredBytes = 8L * 1024L * 1024L,
                elapsedMs = 2_000L,
            ),
        )
    }

    @Test
    fun speedIsZeroBeforeAnyBytesOrElapsedTimeAreAvailable() {
        assertEquals(0L, endToEndBytesPerSecond(0L, 1_000L))
        assertEquals(0L, endToEndBytesPerSecond(1024L, 0L))
    }

    @Test
    fun resumedTransferCountsOnlyBytesReadByTheCurrentAttempt() {
        assertEquals(
            6L * 1024L * 1024L,
            transferredBytesThisAttempt(
                downloaded = 26L * 1024L * 1024L,
                resumeOffset = 20L * 1024L * 1024L,
            ),
        )
        assertEquals(0L, transferredBytesThisAttempt(downloaded = 4L, resumeOffset = 8L))
    }
}
