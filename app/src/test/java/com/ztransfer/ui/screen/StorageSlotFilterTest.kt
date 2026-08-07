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

    @Test
    fun `storage filter is hidden unless two cards are available`() {
        assertTrue(storageFilterSlots(emptyList()).isEmpty())
        assertTrue(storageFilterSlots(listOf(2)).isEmpty())
        assertEquals(listOf(1, 2), storageFilterSlots(listOf(2, 1, 2)))
    }

    @Test
    fun `single card selection returns to all after scan completes`() {
        assertNull(
            normalizeStorageSlotFilter(
                selectedSlot = 2,
                availableSlots = emptyList(),
                hasCompletedFileScan = true,
            )
        )
    }

    @Test
    fun `selection is not cleared while card scan is incomplete`() {
        assertEquals(
            2,
            normalizeStorageSlotFilter(
                selectedSlot = 2,
                availableSlots = emptyList(),
                hasCompletedFileScan = false,
            )
        )
    }

    @Test
    fun `valid dual card selection remains active for current process`() {
        assertEquals(
            2,
            normalizeStorageSlotFilter(
                selectedSlot = 2,
                availableSlots = slots,
                hasCompletedFileScan = true,
            )
        )
    }
}
