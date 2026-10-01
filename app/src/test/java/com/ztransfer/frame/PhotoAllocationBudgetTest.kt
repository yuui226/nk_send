package com.ztransfer.frame

import org.junit.Assert.*
import org.junit.Test

class PhotoAllocationBudgetTest {
    @Test fun estimatesCanvasAndWorkingBuffersWithoutIntegerOverflow() {
        assertEquals(96_000_000L, photoAllocationBytes(6000, 4000))
        assertEquals(208_000_000L, photoAllocationBytes(6000, 4000, 2, 16_000_000))
        assertEquals(Long.MAX_VALUE, photoAllocationBytes(Int.MAX_VALUE, Int.MAX_VALUE, 2))
        assertEquals(Long.MAX_VALUE, photoAllocationBytes(0, 4000))
    }

    @Test fun memoryReserveRejectsOversizedJobRatherThanSilentlyDownsampling() {
        val mib = 1024L * 1024
        assertTrue(photoAllocationFits(128 * mib, 512 * mib, 100 * mib))
        assertFalse(photoAllocationFits(128 * mib, 256 * mib, 120 * mib))
        assertFalse(photoAllocationFits(Long.MAX_VALUE, 512 * mib, 0))
        assertFalse(photoAllocationFits(1, 256 * mib, 300 * mib))
    }
    @Test fun nativeCanvasIsNotLimitedToManagedHeapBudget() {
        val mib = 1024L * 1024
        val reportedEstimate = 494348528L
        assertFalse(photoAllocationFits(reportedEstimate, 512 * mib, 0))
        assertTrue(photoNativeAllocationFits(reportedEstimate, 2048 * mib, 256 * mib))
        assertFalse(photoNativeAllocationFits(reportedEstimate, 512 * mib, 128 * mib))
        assertFalse(photoNativeAllocationFits(Long.MAX_VALUE, Long.MAX_VALUE, 0))
        assertFalse(photoNativeAllocationFits(1, 0, 0))
    }
    @Test fun nativeBudgetDoesNotWithholdQuarterOfAvailableRam() {
        val mib = 1024L * 1024
        // Enough for the reported photo plus the OS reserve, even below 1 GiB available.
        assertTrue(photoNativeAllocationFits(494348528L, 600 * mib, 100 * mib))
        assertTrue(photoNativeAllocationFits(3500 * mib, 4096 * mib, 256 * mib))
        assertTrue(photoNativeAllocationFits(384 * mib, 512 * mib, 128 * mib))
        assertFalse(photoNativeAllocationFits(384 * mib + 1, 512 * mib, 128 * mib))
        assertFalse(photoNativeAllocationFits(1, 64 * mib, 128 * mib))
        assertFalse(photoNativeAllocationFits(-1, 512 * mib, 128 * mib))
    }
}
