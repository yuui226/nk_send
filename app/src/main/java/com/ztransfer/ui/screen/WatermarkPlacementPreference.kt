package com.ztransfer.ui.screen

import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.PhotoFrameWatermarkContent
import com.ztransfer.frame.PhotoFrameWatermarkPosition
import com.ztransfer.frame.isPhotoPlacement

/**
 * Keeps the user's preferred watermark position intact while presenting a valid position for the
 * current editor constraints. Borderless frames and image watermarks only support photo placement.
 */
internal fun PhotoFrameWatermark.withEditorPlacementConstraints(
    borderEnabled: Boolean,
): PhotoFrameWatermark = if (
    (!borderEnabled || content == PhotoFrameWatermarkContent.IMAGE) &&
    !position.isPhotoPlacement()
) {
    copy(position = PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER)
} else {
    this
}

/**
 * Non-position controls edit the constrained watermark shown by the editor. Preserve the separate
 * preferred position so a temporary fallback never becomes a persisted user choice.
 */
internal fun mergeWatermarkEditKeepingPreferredPosition(
    preferred: PhotoFrameWatermark,
    edited: PhotoFrameWatermark,
): PhotoFrameWatermark = edited.copy(position = preferred.position)
