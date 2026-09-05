package com.ztransfer.viewmodel

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.protocol.PtpConstants
import com.ztransfer.protocol.PtpObjectInfo
import kotlin.test.*

class NativeOriginalReuseTest {
    private fun file(name: String = "DSC_0001.JPG", size: Long = 3) = CameraFileInfo(1, size, name, null)
    private fun info() = PtpObjectInfo(1, 0x10001, 0x3801, 3, "DSC_0001.JPG", null, false, false, true)

    @Test fun exactNameWinsOverEarlierCopyAndCaseVariantsButWrongSizeFallsBack() {
        val index = NativeOriginalFileIndex()
        val update = NativeOriginalIndexUpdate(1, -1, true)
        update.add("dsc_0001 (2).jpg", 7, null, "copy")
        update.add("DSC_0001.JPG", 3, null, "exact")
        assertTrue(index.apply(update))
        assertEquals(NativeOriginalMatch("DSC_0001.JPG", 3, "exact"), index.find(file(), null))
        assertEquals(NativeOriginalMatch("dsc_0001 (2).jpg", 7, "copy"), index.find(file(size = 7), null))
        assertEquals("exact", index.find(file(size = PtpConstants.SIZE_UNKNOWN), null)?.locator)
        assertNull(index.find(file(size = 8), null))
        assertNull(index.find(file("OTHER.JPG"), null))
    }

    @Test fun unknownCameraSizeReturnsActualLocalBytesAndZeroIsNotAWildcard() {
        val index = NativeOriginalFileIndex()
        assertTrue(index.apply(NativeOriginalIndexUpdate(1, -1, true).also {
            it.add("DSC_0001 (1).JPG", 0, null, "empty")
        }))
        assertEquals(0L, index.find(file(size = PtpConstants.SIZE_UNKNOWN), null)?.size)
        assertEquals("empty", index.find(file(size = 0), null)?.locator)
        assertNull(index.find(file(), null))
    }

    @Test fun matchCarriesTheActualNameAndLocatorWithinOnlyItsDestinationBucket() {
        val index = NativeOriginalFileIndex()
        assertTrue(index.apply(NativeOriginalIndexUpdate(1, -1, true).also {
            it.add("DSC_0001.JPG", 3, null, "root")
            it.add("DSC_0001 (2).JPG", 3, "ZT2026-09-05", "date")
        }))
        val match = assertNotNull(index.find(file(), "zt2026-09-05"))
        assertEquals(NativeOriginalMatch("DSC_0001 (2).JPG", 3, "date"), match)
        assertEquals("root", index.find(file(), null)?.locator)
        assertNull(index.find(file(), "ZT2026-09-06"))
        assertEquals(match.locator, index.localLocator(file(), "ZT2026-09-05"))
    }

    @Test fun rescanRemovesOldMatchesAndInvalidOrStaleUpdatesDoNotReplaceThem() {
        val index = NativeOriginalFileIndex()
        assertTrue(index.apply(NativeOriginalIndexUpdate(1, -1, true).also {
            it.add("DSC_0001.JPG", 3, null, "old")
        }))
        val frozen = assertNotNull(index.find(file(), null))
        assertTrue(index.apply(NativeOriginalIndexUpdate(2, 1, false).also {
            it.add("DSC_0001.JPG", 3, null, "new")
        }))
        assertEquals("new", index.find(file(), null)?.locator)
        assertFalse(index.apply(NativeOriginalIndexUpdate(3, 2, false).also {
            it.add("bad/name", 3, null, "invalid")
        }))
        assertFalse(index.apply(NativeOriginalIndexUpdate(1, -1, true)))
        assertEquals("new", index.find(file(), null)?.locator)
        assertTrue(index.apply(NativeOriginalIndexUpdate(3, -1, true)))
        assertNull(index.find(file(), null))
        assertEquals("old", frozen.locator) // Frozen metadata is not mutated by later scans.
    }

    @Test fun skippedOriginalMatchesAndroidCopyAndDoesNotInventDownloadTiming() {
        val queue = NativeOriginalTransferQueue()
        val first = assertNotNull(queue.enqueue(info(), false, 0))
        val next = assertNotNull(queue.enqueue(info(), false, 0))
        assertTrue(queue.start())
        val started = assertNotNull(queue.takeNext())
        queue.progress(first.taskId, 1, 3, 999)
        queue.completedExisting(first.taskId, 3)
        assertEquals(started.copy(status = TransferStatus.COMPLETED, skipped = true,
            progress = 1f, downloaded = 3, speed = 0), queue.taskAt(0))
        assertNull(queue.progressSnapshot())
        assertNull(queue.taskAt(0)?.elapsedMs)
        assertEquals(0f, queue.taskAt(0)?.downloadMBps)
        assertNull(queue.retry(first.taskId))
        assertEquals(next.taskId, queue.takeNext()?.taskId)
    }

    @Test fun skippedCompletionProtectsWaitingWrongIdAndNegativeSizeAndIgnoresLateProgress() {
        val queue = NativeOriginalTransferQueue()
        val task = assertNotNull(queue.enqueue(info(), false, 0))
        queue.completedExisting(task.taskId, 3)
        assertEquals(task, queue.taskAt(0))
        queue.start()
        val started = assertNotNull(queue.takeNext())
        queue.completedExisting(task.taskId + 1, 3)
        queue.completedExisting(task.taskId, -1)
        assertEquals(started, queue.taskAt(0))
        queue.completedExisting(task.taskId, 0)
        val skipped = assertNotNull(queue.taskAt(0))
        assertTrue(skipped.skipped)
        assertEquals(0L, skipped.downloaded)
        queue.progress(task.taskId, 3, 3, 1000)
        queue.failed(task.taskId, "late", false)
        queue.completed(task.taskId, 3, 1)
        queue.completedExisting(task.taskId, 3)
        assertEquals(skipped, queue.taskAt(0))
        queue.finishRun()
        assertFalse(queue.running)
    }

    @Test fun skippedCompletionPreservesPauseAndNormalDownloadStillHasItsOriginalSemantics() {
        val queue = NativeOriginalTransferQueue()
        val first = assertNotNull(queue.enqueue(info(), false, 0))
        val second = assertNotNull(queue.enqueue(info(), false, 0))
        queue.start(); queue.takeNext(); queue.pauseAfterCurrent()
        queue.completedExisting(first.taskId, 3)
        assertNull(queue.takeNext())
        queue.finishRun()
        assertTrue(queue.paused)
        assertTrue(queue.start())
        assertEquals(second.taskId, queue.takeNext()?.taskId)
        queue.completed(second.taskId, 3, 1000)
        assertFalse(assertNotNull(queue.taskAt(1)).skipped)
        assertEquals(1000L, queue.taskAt(1)?.elapsedMs)
        queue.clearTerminal()
        assertEquals(0, queue.count)
    }
}
