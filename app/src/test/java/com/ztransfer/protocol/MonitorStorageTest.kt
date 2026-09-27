package com.ztransfer.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test

class MonitorStorageTest {
    private fun payload(total: Long, free: Long) = ByteBuffer.allocate(26)
        .order(ByteOrder.LITTLE_ENDIAN).apply { putLong(6, total); putLong(14, free) }.array()

    @Test fun capacityUses64BitFieldsAndAllowsFullCards() {
        assertEquals(101_000_000_000L, parseMonitorFreeBytes(payload(128_000_000_000L, 101_000_000_000L)))
        assertEquals(0L, parseMonitorFreeBytes(payload(128_000_000_000L, 0)))
    }
    @Test fun invalidOrUnknownCapacityIsNotShown() {
        assertNull(parseMonitorFreeBytes(ByteArray(25)))
        assertNull(parseMonitorFreeBytes(payload(-1, -1)))
        assertNull(parseMonitorFreeBytes(payload(128, -1)))
        assertNull(parseMonitorFreeBytes(payload(128, 129)))
        assertNull(parseMonitorFreeBytes(payload(0, 0)))
    }
}
