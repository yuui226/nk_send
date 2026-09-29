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
}
