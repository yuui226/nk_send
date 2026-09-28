package com.ztransfer.ui.screen

import org.junit.Assert.*
import org.junit.Test

class LandscapeMonitorLayoutTest {
    @Test fun selectsSpaceInsteadOfDeviceCategory() {
        assertEquals(MonitorControlPlacement.RIGHT, landscapeMonitorLayout(1000f, 400f, 1.5f, false).placement)
        assertEquals(MonitorControlPlacement.BOTTOM, landscapeMonitorLayout(800f, 800f, 16f / 9f, true).placement)
        assertEquals(MonitorControlPlacement.OVERLAY, landscapeMonitorLayout(640f, 360f, 16f / 9f, true).placement)
    }

    @Test fun imageKeepsItsAspectAndAllBoundsStayInsideViewport() {
        for (width in listOf(320f, 640f, 800f, 1024f, 1366f)) {
            for (height in listOf(240f, 360f, 600f, 800f)) {
                for (aspect in listOf(1.5f, 16f / 9f, 2.35f, 3.56f)) {
                    for (movie in listOf(false, true)) {
                        val layout = landscapeMonitorLayout(width, height, aspect, movie)
                        assertEquals(aspect, layout.image.width / layout.image.height, .0001f)
                        for (bounds in listOf(layout.image, layout.controls, layout.interactionBounds)) {
                            assertTrue(bounds.x >= 0f && bounds.y >= 0f)
                            assertTrue(bounds.right <= width + .001f)
                            assertTrue(bounds.bottom <= height + .001f)
                        }
                        if (layout.placement == MonitorControlPlacement.RIGHT) {
                            assertTrue(layout.controls.x >= layout.image.right)
                        }
                        if (layout.placement == MonitorControlPlacement.BOTTOM) {
                            assertTrue(layout.controls.y >= layout.image.bottom)
                        }
                    }
                }
            }
        }
    }

    @Test fun narrowSideUsesOneColumnWhenTallEnough() {
        val layout = landscapeMonitorLayout(860f, 500f, 1.5f, false)
        assertEquals(MonitorControlPlacement.RIGHT, layout.placement)
        assertEquals(1, layout.columns)
        assertTrue(layout.controls.width < 128f)
        assertTrue(layout.interactionBounds.width >= 128f)
        assertEquals(layout.controls.right, layout.interactionBounds.right, .001f)
        assertTrue(layout.interactionBounds.x < layout.controls.x)
    }
}
