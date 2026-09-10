package com.ztransfer.ui.screen

import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import kotlin.test.Test
import kotlin.test.assertEquals

class QueueConfirmationPositionTest {
    private val window = IntSize(400, 800)
    private val anchor = IntRect(322, 680, 380, 750)

    @Test fun confirmationIsAboveTheUnmovedButtonAnchor() {
        assertEquals(IntOffset(120, 500), QueueConfirmationPositionProvider.calculatePosition(
            anchor, window, LayoutDirection.Ltr, IntSize(260, 180),
        ))
        assertEquals(IntRect(322, 680, 380, 750), anchor)
    }

    @Test fun tallerConfirmationGrowsUpwardWithoutChangingItsBottomOrAnchor() {
        for (height in listOf(1, 80, 180, 300)) {
            val position = QueueConfirmationPositionProvider.calculatePosition(
                anchor, window, LayoutDirection.Ltr, IntSize(260, height),
            )
            assertEquals(anchor.top, position.y + height)
            assertEquals(anchor.right, position.x + 260)
        }
    }

    @Test fun narrowOrShortWindowClampsOnlyThePopup() {
        assertEquals(IntOffset(0, 0), QueueConfirmationPositionProvider.calculatePosition(
            IntRect(80, 40, 138, 110), IntSize(150, 120), LayoutDirection.Ltr, IntSize(260, 180),
        ))
    }

    @Test fun rightToLeftUsesTheLeftEdgeOfTheAnchor() {
        assertEquals(IntOffset(20, 500), QueueConfirmationPositionProvider.calculatePosition(
            IntRect(20, 680, 78, 750), window, LayoutDirection.Rtl, IntSize(260, 180),
        ))
    }

    @Test fun retryAndClearUseTheirOwnAnchorsButNeverEachOthersPopupHeight() {
        val retryAnchor = IntRect(322, 598, 380, 668)
        val retry = QueueConfirmationPositionProvider.calculatePosition(
            retryAnchor, window, LayoutDirection.Ltr, IntSize(260, 130),
        )
        val clear = QueueConfirmationPositionProvider.calculatePosition(
            anchor, window, LayoutDirection.Ltr, IntSize(260, 180),
        )
        assertEquals(468, retry.y)
        assertEquals(500, clear.y)
        assertEquals(598, retryAnchor.top)
    }
}

