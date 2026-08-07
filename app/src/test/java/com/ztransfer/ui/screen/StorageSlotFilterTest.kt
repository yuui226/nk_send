package com.ztransfer.ui.screen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StorageSlotFilterTest {
    private val slots = listOf(1, 2)

    @Test
    fun `default state selects both storage cards`() {
        assertTrue(isStorageSlotSelected(null, 1))
        assertTrue(isStorageSlotSelected(null, 2))
    }

    @Test
    fun `turning off one card leaves the other card selected`() {
        val selectedSlot = toggleStorageSlotSelection(
            selectedSlot = null,
            toggledSlot = 1,
            availableSlots = slots,
        )

        assertEquals(2, selectedSlot)
        assertFalse(isStorageSlotSelected(selectedSlot, 1))
        assertTrue(isStorageSlotSelected(selectedSlot, 2))
    }

    @Test
    fun `adding the other card restores default unfiltered state`() {
        val selectedSlot = toggleStorageSlotSelection(
            selectedSlot = 2,
            toggledSlot = 1,
            availableSlots = slots,
        )

        assertNull(selectedSlot)
        assertTrue(isStorageSlotSelected(selectedSlot, 1))
        assertTrue(isStorageSlotSelected(selectedSlot, 2))
    }

    @Test
    fun `last selected card cannot be turned off`() {
        assertEquals(
            2,
            toggleStorageSlotSelection(
                selectedSlot = 2,
                toggledSlot = 2,
                availableSlots = slots,
            ),
        )
    }
}
