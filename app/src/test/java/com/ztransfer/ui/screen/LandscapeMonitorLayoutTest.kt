package com.ztransfer.ui.screen

import org.junit.Assert.*
import org.junit.Test

class LandscapeMonitorLayoutTest {
    @Test fun imageAndAllControlHitTargetsNeverOverlap() {
        for (width in listOf(320f, 640f, 800f, 1024f, 1366f)) {
            for (height in listOf(240f, 360f, 600f, 800f)) {
                for (aspect in listOf(1.5f, 16f / 9f, 2.35f, 3.56f)) {
                    val layout = landscapeMonitorLayout(width, height, aspect)
                    assertEquals(aspect, layout.image.width / layout.image.height, .0001f)
                    for (bounds in listOf(layout.image, layout.controls, layout.interactionBounds)) {
                        assertTrue(bounds.x >= 0f && bounds.y >= 0f)
                        assertTrue(bounds.right <= width + .001f)
                        assertTrue(bounds.bottom <= height + .001f)
                    }
                    assertTrue(if (layout.bottomControls) layout.controls.y >= layout.image.bottom + 7.99f
                        else layout.interactionBounds.x >= layout.image.right + 7.99f)
                    assertTrue(layout.controls.width >= 116f)
                }
            }
        }
    }

    @Test fun tallNarrowRailKeepsFourCompactWheelsAndRecorderOutsideImage() {
        val layout = landscapeMonitorLayout(860f, 500f, 1.5f)
        assertEquals(1, layout.columns)
        assertEquals(116f, layout.controls.width, .001f)
        val wheelRoom = layout.controls.height - 36f - 8f - layout.footerHeight
        assertTrue(wheelRoom >= 4 * 46f + 3 * 2f)
    }

    @Test fun videoUsesSingleColumnInsteadOfManufacturingSpaceForTwo() {
        val layout = landscapeMonitorLayout(640f, 360f, 16f / 9f)
        assertFalse(layout.bottomControls)
        assertEquals(1, layout.columns)
        assertEquals(508f, layout.image.width, .001f)
        assertEquals(116f, layout.controls.width, .001f)
        assertTrue(layout.parameterHeight in 42f..46f)
        val available = layout.controls.height - 36f - 8f - layout.footerHeight
        assertTrue(4 * layout.parameterHeight + 6f <= available)
    }

    @Test fun naturalBottomSpacePreservesFullSizeVideoOnSquareScreen() {
        val layout = landscapeMonitorLayout(800f, 800f, 16f / 9f)
        assertTrue(layout.bottomControls)
        assertEquals(792f, layout.image.width, .001f)
        assertTrue(layout.controls.height >= 40f + maxOf(96f, layout.footerHeight))
        val wheelWidth = (layout.controls.width - 96f - layout.shutterSize - 16f - 6f) / 2f
        assertTrue(wheelWidth >= 80f)
    }

    @Test fun desqueezeMovesControlsBelowAndUsesFullAvailableWidth() {
        val normal = landscapeMonitorLayout(800f, 400f, 16f / 9f)
        assertFalse(normal.bottomControls)
        val wide = landscapeMonitorLayout(800f, 400f, 16f / 9f * 2f)
        assertTrue(wide.bottomControls)
        assertEquals(792f, wide.image.width, .001f)
        assertEquals(16f / 9f * 2f, wide.image.width / wide.image.height, .001f)
        assertTrue(wide.controls.height >= 40f + maxOf(96f, wide.footerHeight))
        assertTrue(wide.controls.y >= wide.image.bottom + 8f)
    }

    @Test fun naturalSideSpacePreservesFullHeightPhoto() {
        val layout = landscapeMonitorLayout(1000f, 400f, 1.5f)
        assertFalse(layout.bottomControls)
        assertEquals(392f, layout.image.height, .001f)
    }

    @Test fun shutterSharesFooterWithoutOverlappingExpandedLocalRecorderOrDisp() {
        for (height in listOf(240f, 360f, 500f, 800f)) {
            val layout = landscapeMonitorLayout(640f, height, 16f / 9f)
            assertTrue(layout.footerHeight - layout.shutterSize >= 40f)
            assertTrue(layout.controls.width - layout.shutterSize >= 48f)
        }
    }

}
