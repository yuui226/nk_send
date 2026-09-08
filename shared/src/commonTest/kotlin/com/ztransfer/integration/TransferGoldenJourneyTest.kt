package com.ztransfer.integration

import com.ztransfer.catalog.NativeCameraCatalogScan
import com.ztransfer.protocol.*
import com.ztransfer.test.hexBytes
import com.ztransfer.viewmodel.*
import kotlin.test.*

/** Wire dataset -> shared dual-card catalog -> original FIFO/retry -> saved-file lookup.
 * No Swift/platform success is simulated here; actual file byte equality belongs to Mac fixtures.
 */
class TransferGoldenJourneyTest {
    private fun wire(name: String): ByteArray {
        val prefix = hexBytes("0100010001B10080FFFFFFFF01380403020140010000F00000004020000080150000" +
            "0E0000000000000000000000000078563412")
        fun ptp(text: String): ByteArray = byteArrayOf((text.length + 1).toByte()) +
            text.flatMap { listOf(it.code.toByte(), (it.code shr 8).toByte()) }.toByteArray() + byteArrayOf(0, 0)
        return prefix + ptp(name) + ptp("20260904T150607") + byteArrayOf(0)
    }
    @Test fun jpgNefAndMovGoldenJourneysKeepUnsignedSizeDualCardIdentityAndRetryOrder() {
        for (name in listOf("DSC_0001.JPG", "照片😀.NEF", "MOV_0001.MOV")) {
            val first = assertNotNull(parsePtpObjectInfo(7, wire(name)))
            assertEquals(0xFFFFFFFFL, first.size); assertEquals(name, first.fileName)
            val alias = PtpObjectInfo(9, 0x20001, first.objectFormat, first.size, first.fileName,
                first.captureDate, first.isProtected, first.isAssociation, first.identityComplete)
            val scan = NativeCameraCatalogScan(intArrayOf(0x10001, 0x20001), false)
            scan.addHandles(0, intArrayOf(7)); scan.addHandles(1, intArrayOf(9)); scan.begin()
            while (true) {
                val handle = scan.nextReadHandle()
                if (handle != null) scan.accept(handle, if (handle == 7) first else alias)
                else if (!scan.publishNext()) break
            }
            assertEquals(1, scan.rowCount)
            val file = assertNotNull(scan.fileAt(0))
            assertEquals(setOf(0x10001, 0x20001), file.storageIds)
            val queue = NativeOriginalTransferQueue()
            val metadata = if (file.handle == 7) first else alias
            val task = assertNotNull(queue.enqueueCatalog(metadata, file, true, 0))
            assertEquals("ZT2026-09-04", task.destinationFolderName)
            assertEquals(0, queue.enqueueNewMedia(listOf(first, alias), listOf(file), true, 0))
            assertTrue(queue.start()); assertEquals(task.taskId, queue.takeNext()?.taskId)
            queue.progress(task.taskId, 1024, 128, 100)
            queue.failed(task.taskId, "fixture storage failure", false); queue.finishRun()
            val retried = assertNotNull(queue.retry(task.taskId))
            assertNotEquals(task.taskId, retried.taskId); assertEquals(file, retried.file)
            assertTrue(queue.start()); assertEquals(retried.taskId, queue.takeNext()?.taskId)
            queue.completed(retried.taskId, first.size, 1000); queue.finishRun()
            assertEquals(TransferStatus.COMPLETED, queue.taskAt(0)?.status)
            val index = ExistingFileNameIndexCore<String>()
            val copy = name.substringBeforeLast(".") + " (1)." + name.substringAfterLast(".")
            index.add(copy, first.size, "indexed-original")
            assertEquals("indexed-original", index.find(name, first.size)?.value)
            assertNull(index.find(name, first.size + 100000))
        }
    }
    @Test fun emptyCardCannotProducePhantomQueueSuccess() {
        val scan = NativeCameraCatalogScan(intArrayOf(0x10001), false)
        scan.addHandles(0, intArrayOf()); scan.begin()
        assertNull(scan.nextReadHandle()); assertFalse(scan.publishNext()); assertEquals(0, scan.rowCount)
        val queue = NativeOriginalTransferQueue()
        assertFalse(queue.start()); assertNull(queue.takeNext()); assertEquals(0, queue.count)
    }
}
