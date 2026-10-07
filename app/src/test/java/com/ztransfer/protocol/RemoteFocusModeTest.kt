package com.ztransfer.protocol

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class RemoteFocusModeTest {
    @Test fun vendorEncodingsRemainDistinct() {
        assertEquals("AF-A", rcFocusModeLabel(0x500A, 0x8012))
        assertEquals("AF-F", rcFocusModeLabel(0xD061, 2))
        assertEquals("AF-A", rcFocusModeLabel(0xD061, 5))
        assertFalse(rcFocusModeManual(0xD061, 5))
        assertNull(rcFocusModeLabel(0x500A, 5))
        assertNull(rcFocusModeLabel(0xD161, 5))
        assertEquals("AF-A", rcFocusModeLabel(0xD161, 2))
        assertNull(rcFocusModeLabel(0xD161, 3))
        assertNull(rcFocusModeLabel(0x500A, 999))
        assertTrue(rcFocusModeManual(0x500A, 1))
        assertTrue(rcFocusModeManual(0xD061, 3))
        assertTrue(rcFocusModeManual(0xD061, 4))
        assertFalse(rcFocusModeManual(0xD161, 3))
        assertFalse(rcFocusModeManual(0xD061, 1))
    }
    @Test fun readOnlyStandardAllowsExplicitlyWritableVendorCapability() = runBlocking {
        val locked = RcParam(0x500A, 4, false, 1, listOf(1))
        val vendor = RcParam(0xD061, 2, true, 0, listOf(0, 1))
        val calls = mutableListOf<Int>()
        assertEquals(vendor, readFocusModeCapability {
            calls += it
            if (it == 0x500A) locked else vendor
        })
        assertEquals(listOf(0x500A, 0xD061), calls)
        assertEquals(locked, readFocusModeCapability { if (it == 0x500A) locked else null })
    }
    @Test fun writableStandardStopsExtraQueries() = runBlocking {
        val standard = RcParam(0x500A, 4, true, 0x8010, listOf(0x8010, 0x8011))
        val calls = mutableListOf<Int>()
        assertEquals(standard, readFocusModeCapability { calls += it; standard })
        assertEquals(listOf(0x500A), calls)
    }
    @Test fun unsupportedAndInvalidTypesFallBackWithoutInventingOptions() = runBlocking {
        val calls = mutableListOf<Int>()
        val fallback = RcParam(0xD161, 2, true, 1, listOf(0, 1))
        val result = readFocusModeCapability {
            calls += it
            when(it) {
                0x500A -> null
                0xD061 -> RcParam(it, 4, true, 0, listOf(0, 1))
                else -> fallback
            }
        }
        assertEquals(listOf(0x500A, 0xD061, 0xD161), calls)
        assertEquals(fallback, result)
    }
    @Test fun unavailableCapabilityStaysUnavailable() = runBlocking {
        assertNull(readFocusModeCapability { null })
        assertFalse(validFocusModeParam(RcParam(0x500A, 2, true, 1, listOf(1))))
        assertFalse(validFocusModeParam(RcParam(0x1234, 4, true, 1, listOf(1))))
    }
}
