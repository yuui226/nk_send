package com.ztransfer.catalog

import com.ztransfer.protocol.PtpObjectInfo
import kotlin.test.*

class NativeCameraCatalogScanTest {
    private fun info(handle: Int, store: Int = 0x10001, name: String = "$handle.JPG",
                     date: String? = "20260905T120000", folder: Boolean = false, complete: Boolean = true) =
        PtpObjectInfo(handle, store, if (folder) 0x3001 else 0x3801, 10, name, date, false, folder, complete)

    @Test fun reverseOpaqueHandlesAndDoNotNumericallySort() {
        val scan = NativeCameraCatalogScan(intArrayOf(0, -1, 0x10000, 0x10001, 0x10001), false)
        // AP low-word filtering preserves -1, as the preexisting policy does.
        assertEquals(listOf(-1, 0x10001), (0 until scan.storageCount).map(scan::storageId))
        assertTrue(scan.addHandles(0, intArrayOf()))
        assertFalse(scan.begin())
        assertTrue(scan.addHandles(1, intArrayOf(91, 2, 87)))
        assertTrue(scan.begin())
        assertFalse(scan.addHandles(0, intArrayOf()))
        val read = mutableListOf<Int>()
        while (true) {
            val handle = scan.nextReadHandle()
            if (handle != null) { read += handle; assertTrue(scan.accept(handle, info(handle))) }
            else if (!scan.publishNext()) break
        }
        assertEquals(listOf(87, 2, 91), read)
        assertEquals(read, (0 until scan.rowCount).map { scan.fileAt(it)!!.handle })
        assertEquals(3, scan.processedHandles)
    }

    @Test fun dualCardHeadsMergeBackupMembershipAndKeepFirstHandle() {
        val scan = NativeCameraCatalogScan(intArrayOf(0x20001, 0x10001), false)
        scan.addHandles(0, intArrayOf(1, 2)); scan.addHandles(1, intArrayOf(4, 3)); scan.begin()
        val infos = mapOf(1 to info(1, date = "20260901"), 2 to info(2, name = "backup.JPG"),
            3 to info(3, 0x20001, name = "backup.JPG"), 4 to info(4, 0x20001, date = "20260903"))
        val reads = mutableListOf<Int>()
        while (true) {
            val h = scan.nextReadHandle()
            if (h != null) { reads += h; scan.accept(h, infos[h]) }
            else if (!scan.publishNext()) break
        }
        assertEquals(listOf(2, 3, 1, 4), reads)
        assertEquals(listOf(2, 4, 1), (0 until scan.rowCount).map { scan.fileAt(it)!!.handle })
        assertEquals(setOf(0x10001, 0x20001), scan.fileAt(0)!!.storageIds)
        assertTrue(scan.metadataComplete)
        assertEquals(listOf(2, 3, 1, 4), (0 until scan.indexedObjectCount).map { scan.indexedObjectInfoAt(it)!!.handle })
        assertSame(infos[3], scan.indexedObjectInfoAt(1)) // Hidden alias must not disappear with row merging.
    }

    @Test fun foldersFailuresIncompleteAndDuplicateHandlesStayDistinctConcepts() {
        val scan = NativeCameraCatalogScan(intArrayOf(0x10001, 0x20001), false)
        scan.addHandles(0, intArrayOf(1, 2, 3)); scan.addHandles(1, intArrayOf(3, 4)); scan.begin()
        assertFalse(scan.accept(999, null))
        val read = mutableListOf<Int>()
        while (true) {
            val h = scan.nextReadHandle()
            if (h != null) {
                read += h
                scan.accept(h, when(h) { 3 -> info(h, folder = true); 2 -> null; else -> info(h, complete = false) })
            } else if (!scan.publishNext()) break
        }
        assertEquals(4, read.distinct().size)
        assertEquals(4, scan.totalHandles)
        assertEquals(2, scan.rowCount)
        assertFalse(scan.metadataComplete)
    }

    @Test fun staAggregateUsesWildcardAndSuccessfulEmptyIsComplete() {
        val scan = NativeCameraCatalogScan(intArrayOf(0, -1, 0x10000), true)
        assertEquals(1, scan.storageCount)
        assertEquals(-1, scan.queryStorageId(0))
        scan.addHandles(0, intArrayOf()); assertTrue(scan.begin())
        assertNull(scan.nextReadHandle()); assertFalse(scan.publishNext())
        assertEquals(0, scan.rowCount); assertTrue(scan.metadataComplete)
    }

    @Test fun metadataIndexExcludesFoldersAndFailuresButRetainsIncompleteFileIdentity() {
        val scan = NativeCameraCatalogScan(intArrayOf(0x10001), false)
        assertEquals(0, scan.indexedObjectCount)
        assertNull(scan.indexedObjectInfoAt(-1)); assertNull(scan.indexedObjectInfoAt(0))
        scan.addHandles(0, intArrayOf(1, 2, 3, 4)); scan.begin()
        while (true) {
            val h = scan.nextReadHandle()
            if (h != null) scan.accept(h, when (h) { 4 -> info(h, folder = true); 3 -> null; 2 -> info(h, complete = false); else -> info(h) })
            else if (!scan.publishNext()) break
        }
        assertEquals(listOf(2, 1), (0 until scan.indexedObjectCount).map { scan.indexedObjectInfoAt(it)!!.handle })
        assertFalse(scan.indexedObjectInfoAt(0)!!.identityComplete)
        assertFalse(scan.metadataComplete)
        assertNull(scan.indexedObjectInfoAt(scan.indexedObjectCount))
    }

    @Test fun repeatedRawHandlesAreIndexedOnceWithoutNumericSorting() {
        val scan = NativeCameraCatalogScan(intArrayOf(0x10001, 0x20001), false)
        scan.addHandles(0, intArrayOf(3, 99, 3)); scan.addHandles(1, intArrayOf(99, Int.MIN_VALUE)); scan.begin()
        val reads = ArrayList<Int>()
        while (true) {
            val h = scan.nextReadHandle()
            if (h != null) { reads += h; scan.accept(h, info(h)) }
            else if (!scan.publishNext()) break
        }
        assertEquals(reads.distinct(), (0 until scan.indexedObjectCount).map { scan.indexedObjectInfoAt(it)!!.handle })
        assertEquals(reads.distinct().size, scan.indexedObjectCount)
    }
}
