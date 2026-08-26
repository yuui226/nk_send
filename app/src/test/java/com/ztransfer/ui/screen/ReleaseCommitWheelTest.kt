package com.ztransfer.ui.screen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReleaseCommitWheelTest {
    @Test
    fun draggingIsReservedForWheelsWithMoreThanThreeOptions() {
        assertFalse(wheelDragEnabled(2))
        assertFalse(wheelDragEnabled(3))
        assertTrue(wheelDragEnabled(4))
    }

    @Test
    fun draggingOnlyCalculatesPreviewPositionWithinBounds() {
        assertEquals(3f, wheelPositionAfterDrag(2, -18f, 18f, 4))
        assertEquals(1f, wheelPositionAfterDrag(2, 18f, 18f, 4))
        assertEquals(4f, wheelPositionAfterDrag(2, -999f, 18f, 4))
        assertEquals(0f, wheelPositionAfterDrag(2, 999f, 18f, 4))
    }

    @Test
    fun releaseSnapsToNearestValidDetent() {
        assertEquals(2, wheelReleaseIndex(1.51f, 4))
        assertEquals(1, wheelReleaseIndex(1.49f, 4))
        assertEquals(0, wheelReleaseIndex(-3f, 4))
        assertEquals(4, wheelReleaseIndex(8f, 4))
    }
}
