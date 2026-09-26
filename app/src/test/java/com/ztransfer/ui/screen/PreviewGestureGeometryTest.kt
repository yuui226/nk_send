package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import org.junit.Assert.assertEquals
import org.junit.Test

class PreviewGestureGeometryTest {
    @Test fun pinchKeepsTheSamePixelUnderTheFingersAtAnExistingZoom() {
        val offset = Offset(30f, -50f)
        val centroid = Offset(80f, 90f)
        val oldScale = 2f
        val newScale = 3f
        val pixel = (centroid - offset) / oldScale
        val result = previewPinchOffset(offset, centroid, newScale / oldScale, Offset.Zero)
        assertEquals(centroid, pixel * newScale + result)
    }
    @Test fun upwardPositionUsesAsymmetricPanLimits() {
        val image = Size(400f, 600f)
        val viewport = Size(400f, 800f)
        val center = Offset(200f, 340f)
        assertEquals(Offset(200f, 260f), clampPreviewPan(2f, Offset(1000f, 1000f), image, viewport, center))
        assertEquals(Offset(-200f, -140f), clampPreviewPan(2f, Offset(-1000f, -1000f), image, viewport, center))
    }
    @Test fun returningToOriginalSizeClearsPan() {
        assertEquals(Offset.Zero, clampPreviewPan(1f, Offset(90f, 120f),
            Size(400f, 600f), Size(400f, 800f), Offset(200f, 340f)))
    }
    @Test fun normalPreviewCentersBetweenInformationAndActions() {
        val result = previewPhotoLayout(800f, 400f, 80f, 60f, 84f, 0f)
        assertEquals(1f, result.scale, .001f)
        assertEquals(440f, result.centerY, .001f)
    }
    @Test fun cropAlignsToItsTopAndFitsAboveControls() {
        for (imageHeight in listOf(400f, 1200f)) {
            val result = previewPhotoLayout(800f, imageHeight, 80f, 60f, 84f, 1f)
            assertEquals(60f, result.centerY-imageHeight*result.scale/2f, .001f)
            org.junit.Assert.assertTrue(result.centerY+imageHeight*result.scale/2f <= 716.001f)
        }
    }
    @Test fun layoutTransitionInterpolatesWithoutOvershootingAndSupportsSmallScreens() {
        val start = previewPhotoLayout(800f, 1200f, 80f, 60f, 84f, 0f)
        val end = previewPhotoLayout(800f, 1200f, 80f, 60f, 84f, 1f)
        val middle = previewPhotoLayout(800f, 1200f, 80f, 60f, 84f, .5f)
        assertEquals((start.scale+end.scale)/2f, middle.scale, .001f)
        assertEquals((start.centerY+end.centerY)/2f, middle.centerY, .001f)
        val small = previewPhotoLayout(100f, 1200f, 112f, 140f, 84f, 1f)
        org.junit.Assert.assertTrue(small.scale > 0f && small.centerY.isFinite())
    }

    @Test fun landscapeCropMovesLessButStillClearsControls() {
        val normal = previewPhotoLayout(800f, 300f, 80f, 140f, 84f, 0f)
        val upper = previewPhotoLayout(800f, 300f, 80f, 140f, 84f, 1f)
        val landscape = previewPhotoLayout(800f, 300f, 80f, 140f, 84f, 1f, .5f)
        org.junit.Assert.assertTrue(landscape.centerY > upper.centerY)
        org.junit.Assert.assertTrue(landscape.centerY < normal.centerY)
        org.junit.Assert.assertTrue(landscape.centerY + 150f * landscape.scale <= 716f)
    }

}
