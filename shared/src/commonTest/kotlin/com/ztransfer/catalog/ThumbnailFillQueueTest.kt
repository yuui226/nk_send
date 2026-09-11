package com.ztransfer.catalog

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ThumbnailFillQueueTest {
    @Test
    fun scanPipelineHitsAreNotEnqueuedByFinalSeed() {
        val queue = ThumbnailFillQueue<File>()
        queue.markSettled(2)

        queue.seed(listOf(file(1), file(2), file(3)), null)

        assertEquals(listOf(3, 1), queue.drainHandles())
    }

    @Test
    fun newCameraObjectRunsAfterCurrentItemWithoutRebuildingOldWork() {
        val queue = ThumbnailFillQueue<File>()
        queue.seed(listOf(file(3), file(2), file(1)), null)

        assertEquals(3, queue.poll()?.handle)
        queue.enqueueNew(file(4))

        assertEquals(listOf(4, 2, 1), queue.drainHandles())
    }

    @Test
    fun foregroundResumeDoesNotReseedTheWholeScan() {
        val queue = ThumbnailFillQueue<File>()
        queue.seed(listOf(file(2), file(1)), null)
        assertEquals(2, queue.poll()?.handle)
        queue.markSettled(2)

        queue.seed(listOf(file(3), file(2), file(1)), null)

        assertEquals(listOf(1), queue.drainHandles())
    }

    @Test
    fun rangeChangeReordersOnlyUnfinishedWork() {
        val queue = ThumbnailFillQueue<File>()
        queue.seed(
            listOf(
                file(4, "20260804T120000"),
                file(3, "20260803T120000"),
                file(2, "20260802T120000"),
                file(1, "20260801T120000"),
            ),
            null,
        )
        assertEquals(4, queue.poll()?.handle)
        queue.markSettled(4)

        val range = CaptureDayRange.between(20260801, 20260802)
        queue.updatePriorityRange(range)
        queue.seed(listOf(file(4, "20260804T120000")), range)

        assertEquals(listOf(2, 1, 3), queue.drainHandles())
    }

    @Test
    fun newObjectRespectsTheActivePriorityRange() {
        val range = CaptureDayRange.between(20260801, 20260802)
        val queue = ThumbnailFillQueue<File>()
        queue.seed(
            listOf(file(3, "20260803T120000"), file(2, "20260802T120000")),
            range,
        )

        queue.enqueueNew(file(4, "20260804T120000"))
        queue.enqueueNew(file(1, "20260801T120000"))

        assertEquals(listOf(1, 2, 4, 3), queue.drainHandles())
    }

    @Test
    fun failureWaitsForAnExternalRetryTrigger() {
        val queue = ThumbnailFillQueue<File>()
        val failed = file(1)
        queue.seed(listOf(failed), null)
        assertEquals(failed, queue.poll())

        queue.markFailed(failed)
        assertNull(queue.poll())
        assertEquals(1, queue.failedCount)

        queue.retryFailed()
        assertEquals(failed, queue.poll())
        assertNull(queue.poll())
    }

    @Test
    fun cancelledWorkFromAnOlderScanCannotLeakIntoTheNewQueue() {
        val queue = ThumbnailFillQueue<File>()
        queue.seed(listOf(file(1)), null)
        val oldRevision = queue.revision
        val inFlight = checkNotNull(queue.poll())

        queue.beginScan()
        queue.returnToFront(inFlight, oldRevision)

        assertNull(queue.poll())
    }

    @Test
    fun newCameraSessionForgetsHandlesSettledByTheOldCamera() {
        val queue = ThumbnailFillQueue<File>()
        queue.markSettled(1)
        queue.seed(listOf(file(1)), null)
        assertNull(queue.poll())

        queue.reset()
        queue.seed(listOf(file(1)), null)

        assertEquals(1, queue.poll()?.handle)
    }

    @Test
    fun removedCameraHandlesLeaveEveryQueueState() {
        val queue = ThumbnailFillQueue<File>()
        queue.seed(listOf(file(3), file(2), file(1)), null)
        queue.markSettled(4)

        queue.removeHandles(setOf(2, 4))
        queue.enqueueNew(file(4))

        assertEquals(listOf(4, 3, 1), queue.drainHandles())
    }

    @Test
    fun beginScanKeepsSettledHandlesButClearsFailuresForTheNewEnumeration() {
        val queue = ThumbnailFillQueue<File>()
        queue.markSettled(1)
        queue.seed(listOf(file(2)), null)
        val failed = checkNotNull(queue.poll())
        queue.markFailed(failed)

        queue.beginScan()
        queue.seed(listOf(file(1), file(2)), null)

        assertEquals(0, queue.failedCount)
        assertEquals(listOf(2), queue.drainHandles())
    }

    @Test
    fun duplicateHandlesEnterTheQueueOnlyOnce() {
        val queue = ThumbnailFillQueue<File>()

        queue.seed(listOf(file(1), file(1), file(2), file(2)), null)
        queue.enqueueNew(file(2))

        assertEquals(2, queue.pendingCount)
        assertEquals(listOf(2, 1), queue.drainHandles())
    }

    @Test
    fun thumbnailPriorityRetainsAllFilesAndStableEqualTimeOrder() {
        val raw = file(0x091961BF, "20260806T120000")
        val jpeg = file(0x291961BF, "20260806T120000")
        val movie = file(0x611961BD, "20260806T115959")
        val olderInRange = file(7, "20260805T120000")

        assertEquals(
            listOf(raw, jpeg, movie, olderInRange),
            prioritizedThumbnailFiles(listOf(raw, jpeg, movie, olderInRange), null),
        )
        assertEquals(
            listOf(olderInRange, raw, jpeg, movie),
            prioritizedThumbnailFiles(
                listOf(raw, jpeg, movie, olderInRange),
                CaptureDayRange.between(20260805, 20260805),
            ),
        )
    }

    private fun ThumbnailFillQueue<File>.drainHandles(): List<Int> = buildList {
        while (true) add(poll()?.handle ?: break)
    }

    private data class File(
        override val handle: Int,
        override val captureDate: String,
    ) : CameraCatalogFile {
        override val fileName: String = "$handle.JPG"
        override val isProtected: Boolean = false
        override val storageIds: Set<Int> = emptySet()
        override val extension: String = ".jpg"
    }

    private fun file(handle: Int, captureDate: String = "2026080${handle}T120000") =
        File(handle, captureDate)
}
