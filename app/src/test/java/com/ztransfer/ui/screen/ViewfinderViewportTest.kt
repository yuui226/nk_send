package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import org.junit.Assert.*
import org.junit.Test

class ViewfinderViewportTest {
    @Test fun centeredZoomAndPanKeepCropInsideImage() {
        val viewport = ViewfinderViewport()
        viewport.resize(Size(1000f, 600f), 5f / 3f)
        viewport.transform(Offset(500f, 300f), Offset.Zero, 2f, 5f / 3f)
        val center = viewport.visibleRegion(5f / 3f)
        assertEquals(0.25f, center.left, 0.0001f)
        assertEquals(0.75f, center.right, 0.0001f)
        viewport.transform(Offset(500f, 300f), Offset(10000f, -10000f), 1f, 5f / 3f)
        val edge = viewport.visibleRegion(5f / 3f)
        assertEquals(0f, edge.left, 0.0001f)
        assertEquals(1f, edge.bottom, 0.0001f)
        viewport.reset()
        assertEquals(1f, viewport.scale, 0f)
        assertEquals(Offset.Zero, viewport.offset)
    }

    @Test fun letterboxAndLayoutResizeKeepVisibleRegionValid() {
        val viewport = ViewfinderViewport()
        viewport.resize(Size(1000f, 1000f), 2f)
        val full = viewport.visibleRegion(2f)
        assertEquals(0f, full.top, 0f)
        assertEquals(1f, full.bottom, 0f)
        viewport.transform(Offset(500f, 500f), Offset(0f, 900f), 2f, 2f)
        // Two-times zoom fills the square vertically: there is still no vertical panning.
        assertEquals(0f, viewport.offset.y, 0f)
        viewport.resize(Size(600f, 300f), 2f)
        val crop = viewport.visibleRegion(2f)
        assertTrue(crop.left >= 0f && crop.right <= 1f)
        assertTrue(crop.top >= 0f && crop.bottom <= 1f)
        viewport.transform(Offset.Zero, Offset.Zero, Float.NaN, 2f)
        assertEquals(2f, viewport.scale, 0f)
    }

    @Test fun horizonHysteresisAvoidsFlicker() {
        assertTrue(horizonAligned(0.6f, false))
        assertFalse(horizonAligned(0.9f, false))
        assertTrue(horizonAligned(0.9f, true))
        assertFalse(horizonAligned(1.3f, true))
        assertFalse(horizonAligned(Float.NaN, true))
    }
}
