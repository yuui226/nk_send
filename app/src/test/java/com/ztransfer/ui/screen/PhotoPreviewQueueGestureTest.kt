package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Offset
import org.junit.Assert.assertEquals
import org.junit.Test

class PhotoPreviewQueueGestureTest {
    @Test
    fun upwardIntentOnlyWinsAfterSlopAndClearDirection() {
        assertEquals(
            PreviewQueueDragDirection.UNDECIDED,
            previewQueueDragDirection(Offset(2f, -5f), touchSlop = 8f),
        )
        assertEquals(
            PreviewQueueDragDirection.UPWARD,
            previewQueueDragDirection(Offset(5f, -24f), touchSlop = 8f),
        )
        assertEquals(
            PreviewQueueDragDirection.UNDECIDED,
            previewQueueDragDirection(Offset(18f, -19f), touchSlop = 8f),
        )
    }

    @Test
    fun horizontalAndDownwardDragsStayWithExistingGestures() {
        assertEquals(
            PreviewQueueDragDirection.REJECTED,
            previewQueueDragDirection(Offset(24f, -8f), touchSlop = 8f),
        )
        assertEquals(
            PreviewQueueDragDirection.REJECTED,
            previewQueueDragDirection(Offset(1f, 20f), touchSlop = 8f),
        )
    }

    @Test
    fun visualDragTracksFingerThenAddsResistanceAfterTrigger() {
        assertEquals(0f, previewQueueVisualOffset(0f, 96f), 0.001f)
        assertEquals(-48f, previewQueueVisualOffset(48f, 96f), 0.001f)
        assertEquals(-96f, previewQueueVisualOffset(96f, 96f), 0.001f)
        assertEquals(-118f, previewQueueVisualOffset(196f, 96f), 0.001f)
        assertEquals(-119.04f, previewQueueVisualOffset(10_000f, 96f), 0.001f)
    }
}
