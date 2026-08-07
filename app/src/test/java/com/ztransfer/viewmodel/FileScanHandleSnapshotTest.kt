package com.ztransfer.viewmodel

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
            sortedHandles = listOf(105, 104, 103, 102, 101),
        )

        assertTrue(snapshot.belongsTo(session))
        assertEquals(
            listOf(104, 102, 101),
            snapshot.remainingAfter(setOf(105, 103)),
        )
    }

    @Test
    fun equalButDifferentSessionCannotReuseHandles() {
        val oldSession = String(charArrayOf('c', 'a', 'm'))
        val newSession = String(charArrayOf('c', 'a', 'm'))
        val snapshot = FileScanHandleSnapshot(
            sessionToken = oldSession,
            storageIds = listOf(0x00010001),
            sortedHandles = listOf(3, 2, 1),
        )

        assertEquals(oldSession, newSession)
        assertFalse(snapshot.belongsTo(newSession))
    }
}
