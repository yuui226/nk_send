package com.ztransfer.viewmodel

import com.ztransfer.catalog.StorageHandleOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FileScanHandleSnapshotTest {
    @Test
    fun sameSessionReusesOriginalOrderAndSkipsPublishedHandles() {
        val session = Any()
        val snapshot = FileScanHandleSnapshot(
            sessionToken = session,
            storageIds = listOf(0x00010001, 0x00020001),
            handleOrders = listOf(
                StorageHandleOrder(0x00010001, listOf(105, 103, 101)),
                StorageHandleOrder(0x00020001, listOf(104, 102)),
            ),
        )

        assertTrue(snapshot.belongsTo(session))
        assertEquals(
            listOf(
                StorageHandleOrder(0x00010001, listOf(101)),
                StorageHandleOrder(0x00020001, listOf(104, 102)),
            ),
            snapshot.remainingAfter(setOf(105, 103)),
        )
        assertEquals(5, snapshot.totalHandleCount)
    }

    @Test
    fun equalButDifferentSessionCannotReuseHandles() {
        val oldSession = String(charArrayOf('c', 'a', 'm'))
        val newSession = String(charArrayOf('c', 'a', 'm'))
        val snapshot = FileScanHandleSnapshot(
            sessionToken = oldSession,
            storageIds = listOf(0x00010001),
            handleOrders = listOf(StorageHandleOrder(0x00010001, listOf(3, 2, 1))),
        )

        assertEquals(oldSession, newSession)
        assertFalse(snapshot.belongsTo(newSession))
    }

    @Test
    fun resumeAlsoSkipsProcessedBackupHandleThatWasMergedOutOfVisibleFiles() {
        val snapshot = FileScanHandleSnapshot(
            sessionToken = Any(),
            storageIds = listOf(1, 2),
            handleOrders = listOf(
                StorageHandleOrder(1, listOf(11, 10)),
                StorageHandleOrder(2, listOf(21, 20)),
            ),
        )
        snapshot.markProcessed(listOf(11, 21))

        assertEquals(
            listOf(
                StorageHandleOrder(1, listOf(10)),
                StorageHandleOrder(2, listOf(20)),
            ),
            snapshot.remainingAfter(existingHandles = setOf(11)),
        )
    }
}
