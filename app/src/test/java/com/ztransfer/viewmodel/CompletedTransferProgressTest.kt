package com.ztransfer.viewmodel

import com.ztransfer.protocol.endToEndBytesPerSecond
import com.ztransfer.protocol.transferredBytesThisAttempt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CompletedTransferProgressTest {
    @Test fun fastFileWithoutPeriodicSamplesSuppliesSpeedToTheNextFile() {
        val bytes = 4L * 1024L * 1024L
        val speed = endToEndBytesPerSecond(bytes, elapsedMs = 100L)
        val completed = requireNotNull(ActiveTransferProgress(taskId = 1L)
            .withCompletedDownload(1L, bytes, speed))

        assertEquals(1f, completed.fraction)
        assertEquals(bytes, completed.downloaded)
        assertEquals(40L * 1024L * 1024L, completed.bytesPerSecond)
        assertEquals(speed, completed.retainedBytesPerSecond)

        // The next task's start sample remains zero; the capsule keeps the completed speed.
        val next = ActiveTransferProgress(taskId = 2L,
            retainedBytesPerSecond = completed.retainedBytesPerSecond)
        assertEquals(0L, next.bytesPerSecond)
        assertEquals(speed, next.retainedBytesPerSecond)
    }

    @Test fun completionReplacesThePreviousFilesSpeedWithTheNewMeasuredSpeed() {
        val completed = ActiveTransferProgress(taskId = 2L, fraction = .5f,
            downloaded = 500L, bytesPerSecond = 5_000L, retainedBytesPerSecond = 5_000L)
            .withCompletedDownload(2L, 1_000L, 4_000L)

        assertEquals(4_000L, completed?.bytesPerSecond)
        assertEquals(4_000L, completed?.retainedBytesPerSecond)
        assertEquals(1f, completed?.fraction)
    }

    @Test fun missingElapsedTimeDoesNotInventSpeedOrEraseTheLastValidSample() {
        val speed = endToEndBytesPerSecond(1_000L, elapsedMs = 0L)
        val first = ActiveTransferProgress(taskId = 1L).withCompletedDownload(1L, 1_000L, speed)
        val later = ActiveTransferProgress(taskId = 2L, retainedBytesPerSecond = 4_000L)
            .withCompletedDownload(2L, 1_000L, speed)

        assertEquals(0L, first?.retainedBytesPerSecond)
        assertEquals(4_000L, later?.retainedBytesPerSecond)
    }

    @Test fun completionCannotOverwriteAnotherTaskOrReviveAClearedQueue() {
        val next = ActiveTransferProgress(taskId = 2L, fraction = .2f, downloaded = 200L)
        assertEquals(next, next.withCompletedDownload(1L, 1_000L, 4_000L))
        assertNull(null.withCompletedDownload(1L, 1_000L, 4_000L))
        assertEquals(0L, ActiveTransferProgress(taskId = 3L).retainedBytesPerSecond)
    }

    @Test fun resumedVideoSpeedUsesOnlyBytesDownloadedInThisAttempt() {
        val transferred = transferredBytesThisAttempt(downloaded = 10_000L, resumeOffset = 8_000L)
        val completed = ActiveTransferProgress(taskId = 1L)
            .withCompletedDownload(1L, 10_000L, endToEndBytesPerSecond(transferred, 500L))

        assertEquals(10_000L, completed?.downloaded)
        assertEquals(4_000L, completed?.retainedBytesPerSecond)
    }
}
