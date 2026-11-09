package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import org.junit.Assert.*
import org.junit.Test

class ViewfinderViewportTest {
    @Test fun mirroredPinchKeepsTheCameraPointUnderTheFinger() {
        for (aspect in listOf(3f / 2f, 16f / 9f, 16f / 9f * 1.5f)) {
            for (size in listOf(Size(600f, 1200f), Size(1200f, 600f))) {
                val viewport = ViewfinderViewport()
                viewport.resize(size, aspect)
                val tap = Offset(size.width * .65f, size.height * .45f)
                val originalPoint = Offset(size.width - tap.x, tap.y)
                viewport.transform(tap, Offset.Zero, 2f, aspect, mirrored = true)
                // The mirrored display uses the same inverse mapping for AF and drawing.
                val center = Offset(size.width / 2, size.height / 2)
                val displayed = Offset(
                    center.x - (originalPoint.x - center.x) * viewport.scale - viewport.offset.x,
                    center.y + (originalPoint.y - center.y) * viewport.scale + viewport.offset.y,
                )
                assertEquals(tap.x, displayed.x, .001f)
                assertEquals(tap.y, displayed.y, .001f)
            }
        }
    }

    @Test fun mirroredPanFollowsTheFingerAndClampsAtBothEdges() {
        val aspect = 5f / 3f
        for (pan in listOf(Offset(80f, -30f), Offset(10000f, -10000f), Offset(-10000f, 10000f))) {
            val normal = ViewfinderViewport()
            val mirrored = ViewfinderViewport()
            for (viewport in listOf(normal, mirrored)) {
                viewport.resize(Size(1000f, 600f), aspect)
                viewport.transform(Offset(500f, 300f), Offset.Zero, 2f, aspect)
            }
            normal.transform(Offset(500f, 300f), pan, 1f, aspect)
            mirrored.transform(Offset(500f, 300f), pan, 1f, aspect, mirrored = true)
            assertEquals(normal.offset.x, -mirrored.offset.x, .001f)
            assertEquals(normal.offset.y, mirrored.offset.y, .001f)
            val normalCrop = normal.visibleRegion(aspect)
            val mirroredCrop = mirrored.visibleRegion(aspect)
            assertEquals(normalCrop.left, 1f - mirroredCrop.right, .001f)
            assertEquals(normalCrop.right, 1f - mirroredCrop.left, .001f)
            assertEquals(normalCrop.top, mirroredCrop.top, .001f)
        }
    }

    @Test fun horizonPreservesPortraitDirectionWhileSharingAlignmentTargets() {
        for (axis in listOf(-180f, -90f, 0f, 90f, 180f, 270f)) {
            assertEquals(axis, horizonDisplayRoll(axis), 0.0001f)
            assertTrue(horizonAligned(axis, false))
            assertFalse(horizonAligned(axis + 2f, false))
        }
        assertEquals(46f, horizonDisplayRoll(46f, 44f), 0.0001f)
        assertEquals(181f, horizonDisplayRoll(-179f, 179f), 0.0001f)
        assertEquals(-181f, horizonDisplayRoll(179f, -179f), 0.0001f)
        assertEquals(361f, horizonDisplayRoll(1f, 359f), 0.0001f)
    }

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
        // The original wide image window stays fixed, so vertical panning is available.
        assertEquals(250f, viewport.offset.y, 0f)
        viewport.resize(Size(600f, 300f), 2f)
        val crop = viewport.visibleRegion(2f)
        assertTrue(crop.left >= 0f && crop.right <= 1f)
        assertTrue(crop.top >= 0f && crop.bottom <= 1f)
        viewport.transform(Offset.Zero, Offset.Zero, Float.NaN, 2f)
        assertEquals(2f, viewport.scale, 0f)
    }

    @Test fun zoomRetainsVideoCropAspectEvenInsideSquareOrPortraitPanel() {
        for (aspect in listOf(16f / 9f, 3f / 2f, 16f / 9f * 1.5f)) {
            for (size in listOf(Size(1000f, 1000f), Size(600f, 1200f), Size(1800f, 700f))) {
                val viewport = ViewfinderViewport()
                viewport.resize(size, aspect)
                viewport.transform(Offset(size.width / 2, size.height / 2), Offset.Zero, 2f, aspect)
                val crop = viewport.visibleRegion(aspect)
                assertEquals(0.5f, crop.width, 0.0001f)
                assertEquals(0.5f, crop.height, 0.0001f)
                viewport.transform(Offset.Zero, Offset(100000f, -100000f), 1f, aspect)
                val edge = viewport.visibleRegion(aspect)
                assertEquals(0f, edge.left, 0.0001f)
                assertEquals(1f, edge.bottom, 0.0001f)
                assertEquals(edge.width, edge.height, 0.0001f)
            }
        }
    }

    @Test fun horizonHysteresisAvoidsFlicker() {
        assertTrue(horizonAligned(0.6f, false))
        assertFalse(horizonAligned(0.9f, false))
        assertTrue(horizonAligned(0.9f, true))
        assertFalse(horizonAligned(1.3f, true))
        assertFalse(horizonAligned(Float.NaN, true))
        for (axis in listOf(-180f, -90f, 90f, 180f, 270f)) {
            assertTrue(horizonAligned(axis, false))
            assertTrue(horizonAligned(axis - 0.6f, false))
            assertTrue(horizonAligned(axis + 0.6f, false))
            assertFalse(horizonAligned(axis + 0.9f, false))
            assertTrue(horizonAligned(axis + 0.9f, true))
            assertFalse(horizonAligned(axis - 1.3f, true))
        }
        assertFalse(horizonAligned(45f, true))
        assertFalse(horizonAligned(Float.POSITIVE_INFINITY, true))
    }
}
