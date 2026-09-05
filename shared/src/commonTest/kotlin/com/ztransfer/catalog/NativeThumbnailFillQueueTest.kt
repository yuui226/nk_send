package com.ztransfer.catalog

import com.ztransfer.protocol.CameraFileInfo
import kotlin.test.*

class NativeThumbnailFillQueueTest {
    private fun file(handle: Int) = CameraFileInfo(handle, 100, "$handle.JPG", "2026090${handle}T120000", false)

    @Test fun orderingMatchesOriginalQueueForAllRangesAndInputOrders() {
        val files = (1..4).map(::file)
        for (input in listOf(files, files.reversed(), listOf(files[1], files[3], files[0], files[2]))) {
            for (range in listOf(null, CaptureDayRange(20260901, 20260902), CaptureDayRange(20260903, 20260904))) {
                val original = ThumbnailFillQueue<CameraFileInfo>().also { it.seed(input, range) }
                val native = NativeThumbnailFillQueue()
                native.setPriorityRange(range?.startDayKey ?: 0, range?.endInclusiveDayKey ?: 0)
                assertTrue(native.replace(input))
                val handles = buildList { while (true) { val row = original.poll() ?: break; add(row.handle) } }
                assertEquals(handles, native.drain())
            }
        }
    }

    @Test fun dateChangeReordersOnlyPendingAndDoesNotInterruptCurrentRequest() {
        val q = NativeThumbnailFillQueue(); q.replace((1..4).map(::file))
        val active = assertNotNull(q.next()); assertEquals(4, active.file.handle)
        assertNull(q.next())
        assertTrue(q.setPriorityRange(20260902, 20260901))
        assertTrue(q.isCurrent(active)); assertTrue(q.settled(active))
        assertEquals(listOf(2, 1, 3), q.drain())
    }

    @Test fun failureWaitsForRealRetryAndUnchangedDateDoesNotGrantAnotherAttempt() {
        val q = NativeThumbnailFillQueue(); q.replace(listOf(file(1)))
        val active = assertNotNull(q.next()); assertTrue(q.failed(active))
        assertNull(q.next()); assertEquals(1, q.failedCount)
        assertFalse(q.setPriorityRange(0, 0)); assertNull(q.next())
        q.retryFailed()
        assertEquals(listOf(1), q.drain()); assertEquals(0, q.failedCount)
    }

    @Test fun foregroundReturnAndLateDuplicateCompletionAreSafe() {
        val q = NativeThumbnailFillQueue(); q.replace((1..3).map(::file))
        val request = assertNotNull(q.next())
        assertTrue(q.returnToFront(request)); assertFalse(q.failed(request)); assertFalse(q.settled(request))
        assertEquals(listOf(3, 2, 1), q.drain())
    }

    @Test fun fullScanInvalidatesOldRequestsAndRechecksDiskClaimsRatherThanAssumingCacheStillExists() {
        val q = NativeThumbnailFillQueue(); q.replace(listOf(file(1), file(2)))
        val old = assertNotNull(q.next()); q.settled(old)
        val inFlight = assertNotNull(q.next())
        assertTrue(q.replace(listOf(file(1), file(2))))
        assertFalse(q.returnToFront(inFlight)); assertFalse(q.settled(inFlight))
        assertEquals(listOf(2, 1), q.drain())
    }

    @Test fun invalidCatalogCannotEraseThePreviousQueueAndInputCollectionsAreCopied() {
        val q = NativeThumbnailFillQueue(); val input = mutableListOf(file(1), file(2))
        q.replace(input); input.clear()
        val active = assertNotNull(q.next())
        assertFalse(q.replace(listOf(file(3), file(3))))
        assertFalse(q.replace(listOf(file(4).copy(size = -1))))
        assertFalse(q.replace(listOf(file(4).copy(fileName = ""))))
        assertTrue(q.isCurrent(active)); q.settled(active)
        assertEquals(listOf(1), q.drain())
    }

    @Test fun fabricatedRequestsAndClosedGenerationCannotMutateQueue() {
        val q = NativeThumbnailFillQueue(); q.replace(listOf(file(1)))
        val active = assertNotNull(q.next())
        assertFalse(q.settled(NativeThumbnailFillRequest(active.revision, active.file)))
        q.clear(); assertFalse(q.failed(active)); assertEquals(0, q.pendingCount); assertNull(q.next())
    }

    private fun NativeThumbnailFillQueue.drain(): List<Int> = buildList {
        while (true) { val request = next() ?: break; add(request.file.handle); assertTrue(settled(request)) }
    }
}
