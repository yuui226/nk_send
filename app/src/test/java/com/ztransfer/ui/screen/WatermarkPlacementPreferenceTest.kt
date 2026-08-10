package com.ztransfer.ui.screen

import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.PhotoFrameWatermarkContent
import com.ztransfer.frame.PhotoFrameWatermarkPosition
import org.junit.Assert.assertEquals
import org.junit.Test

class WatermarkPlacementPreferenceTest {
    @Test
    fun borderlessFallbackDoesNotOverwritePreferredBorderPosition() {
        val preferred = watermarkAt(PhotoFrameWatermarkPosition.LEFT)

        val constrained = preferred.withEditorPlacementConstraints(borderEnabled = false)

        assertEquals(PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER, constrained.position)
        assertEquals(PhotoFrameWatermarkPosition.LEFT, preferred.position)
        assertEquals(
            PhotoFrameWatermarkPosition.LEFT,
            preferred.withEditorPlacementConstraints(borderEnabled = true).position,
        )
    }

    @Test
    fun imageFallbackRestoresPreferredPositionWhenReturningToText() {
        val preferred = watermarkAt(PhotoFrameWatermarkPosition.RIGHT)
        val image = preferred.copy(content = PhotoFrameWatermarkContent.IMAGE)

        assertEquals(
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER,
            image.withEditorPlacementConstraints(borderEnabled = true).position,
        )
        assertEquals(
            PhotoFrameWatermarkPosition.RIGHT,
            image.copy(content = PhotoFrameWatermarkContent.TEXT)
                .withEditorPlacementConstraints(borderEnabled = true)
                .position,
        )
    }

    @Test
    fun unrelatedEditsCannotPersistTheTemporaryFallback() {
        val preferred = watermarkAt(PhotoFrameWatermarkPosition.CENTER)
        val constrained = preferred.withEditorPlacementConstraints(borderEnabled = false)

        val merged = mergeWatermarkEditKeepingPreferredPosition(
            preferred = preferred,
            edited = constrained.copy(opacityPercent = 60),
        )

        assertEquals(60, merged.opacityPercent)
        assertEquals(PhotoFrameWatermarkPosition.CENTER, merged.position)
    }

    @Test
    fun explicitPhotoPositionCanReplaceTheOldPreference() {
        val preferred = watermarkAt(PhotoFrameWatermarkPosition.AUTO)
        val explicitlySelected = preferred.copy(
            position = PhotoFrameWatermarkPosition.PHOTO_TOP_LEFT,
        )

        assertEquals(
            PhotoFrameWatermarkPosition.PHOTO_TOP_LEFT,
            explicitlySelected.withEditorPlacementConstraints(borderEnabled = false).position,
        )
        assertEquals(
            PhotoFrameWatermarkPosition.PHOTO_TOP_LEFT,
            explicitlySelected.withEditorPlacementConstraints(borderEnabled = true).position,
        )
    }

    @Test
    fun remainingConstraintDelaysRestorationUntilAllConstraintsAreGone() {
        val preferred = watermarkAt(PhotoFrameWatermarkPosition.LEFT)
        val image = preferred.copy(content = PhotoFrameWatermarkContent.IMAGE)

        assertEquals(
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER,
            image.withEditorPlacementConstraints(borderEnabled = false).position,
        )
        assertEquals(
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER,
            image.withEditorPlacementConstraints(borderEnabled = true).position,
        )
        assertEquals(
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER,
            image.copy(content = PhotoFrameWatermarkContent.TEXT)
                .withEditorPlacementConstraints(borderEnabled = false)
                .position,
        )
        assertEquals(
            PhotoFrameWatermarkPosition.LEFT,
            image.copy(content = PhotoFrameWatermarkContent.TEXT)
                .withEditorPlacementConstraints(borderEnabled = true)
                .position,
        )
    }

    private fun watermarkAt(position: PhotoFrameWatermarkPosition) = PhotoFrameWatermark(
        position = position,
    )
}
