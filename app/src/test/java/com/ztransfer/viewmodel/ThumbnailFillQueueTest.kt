package com.ztransfer.viewmodel

import com.ztransfer.protocol.NikonCamera
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ThumbnailFillQueueTest {
    @Test
    fun `scan pipeline hits are not enqueued by final seed`() {
        val queue = ThumbnailFillQueue()
        queue.markSettled(2)

        queue.seed(listOf(file(1), file(2), file(3)), null)

        assertEquals(listOf(3, 1), queue.drainHandles())
    }

    @Test
    fun `new camera object runs after current item without rebuilding old work`() {
        val queue = ThumbnailFillQueue()
        queue.seed(listOf(file(3), file(2), file(1)), null)

        assertEquals(3, queue.poll()?.handle)
        queue.enqueueNew(file(4))

        assertEquals(listOf(4, 2, 1), queue.drainHandles())
    }

    @Test
    fun `foreground resume does not reseed the whole scan`() {
        val queue = ThumbnailFillQueue()
        queue.seed(listOf(file(2), file(1)), null)
        assertEquals(2, queue.poll()?.handle)
        queue.markSettled(2)

        queue.seed(listOf(file(3), file(2), file(1)), null)

        assertEquals(listOf(1), queue.drainHandles())
    }

    @Test
    fun `range change reorders only unfinished work`() {
        val queue = ThumbnailFillQueue()
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

        val range = PhotoDateRange.between(
            LocalDate.of(2026, 8, 1),
            LocalDate.of(2026, 8, 2),
        )
        queue.updatePriorityRange(range)
        queue.seed(listOf(file(4, "20260804T120000")), range)

        assertEquals(listOf(2, 1, 3), queue.drainHandles())
    }

    @Test
    fun `new object respects the active priority range`() {
        val range = PhotoDateRange.between(
            LocalDate.of(2026, 8, 1),
            LocalDate.of(2026, 8, 2),
        )
        val queue = ThumbnailFillQueue()
        queue.seed(
            listOf(
                file(3, "20260803T120000"),
                file(2, "20260802T120000"),
            ),
            range,
        )

        queue.enqueueNew(file(4, "20260804T120000"))
        queue.enqueueNew(file(1, "20260801T120000"))

        assertEquals(listOf(1, 2, 4, 3), queue.drainHandles())
    }

    @Test
    fun `failure waits for an external retry trigger`() {
        val queue = ThumbnailFillQueue()
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
    fun `cancelled work from an older scan cannot leak into the new queue`() {
        val queue = ThumbnailFillQueue()
        queue.seed(listOf(file(1)), null)
        val oldRevision = queue.revision
        val inFlight = queue.poll()!!

        queue.beginScan()
        queue.returnToFront(inFlight, oldRevision)

        assertNull(queue.poll())
    }

    @Test
    fun `new camera session forgets handles settled by the old camera`() {
        val queue = ThumbnailFillQueue()
        queue.markSettled(1)
        queue.seed(listOf(file(1)), null)
        assertNull(queue.poll())

        queue.reset()
        queue.seed(listOf(file(1)), null)

        assertEquals(1, queue.poll()?.handle)
    }

    @Test
    fun `removed camera handles leave every thumbnail queue state`() {
        val queue = ThumbnailFillQueue()
        queue.seed(listOf(file(3), file(2), file(1)), null)
        queue.markSettled(4)

        queue.removeHandles(setOf(2, 4))
        queue.enqueueNew(file(4))

        assertEquals(listOf(4, 3, 1), queue.drainHandles())
    }

    private fun ThumbnailFillQueue.drainHandles(): List<Int> = buildList {
        while (true) add(poll()?.handle ?: break)
    }

    private fun file(handle: Int, captureDate: String = "2026080${handle}T120000") =
        NikonCamera.FileInfo(
            handle = handle,
            size = 1L,
            fileName = "$handle.JPG",
            captureDate = captureDate,
        )
}
