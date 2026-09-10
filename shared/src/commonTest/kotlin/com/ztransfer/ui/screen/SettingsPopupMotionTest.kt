package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Rect
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SettingsPopupMotionTest {
    private val anchor = Rect(16f, 40f, 72f, 96f)
    private val panel = Rect(12f, 104f, 388f, 704f)

    @Test fun seedStartsAtButtonAndDoesNotExposeTextOrShadows() {
        val frame = settingsPopupFrame(0f, anchor, panel, 20f)
        assertEquals(anchor.bottom, frame.bounds.top)
        assertEquals(anchor.center.x, frame.bounds.center.x)
        assertEquals(0f, frame.bounds.height)
        assertEquals(0f, frame.cornerRadius)
        assertEquals(0f, frame.shellAlpha)
        assertEquals(0f, frame.contentAlpha)
    }

    @Test fun separationAndExpansionStartTogetherAtTheLowerEdge() {
        val frame = settingsPopupFrame(0.12f, anchor, panel, 20f)
        assertTrue(frame.bounds.top >= anchor.bottom)
        assertTrue(frame.bounds.width > anchor.width)
        assertTrue(frame.bounds.height > anchor.height)
        assertEquals(0f, frame.contentAlpha)
    }

    @Test fun settledPanelExactlyMatchesMeasuredLayout() {
        val frame = settingsPopupFrame(1f, anchor, panel, 20f)
        assertEquals(panel, frame.bounds)
        assertEquals(20f, frame.cornerRadius)
        assertEquals(1f, frame.contentAlpha)
        assertEquals(1f, frame.shellAlpha)
    }

    @Test fun closeAndOpenUseTheSameGeometryWithoutHysteresis() {
        val forward = (0..100).map { settingsPopupFrame(it / 100f, anchor, panel, 20f) }
        val reverse = (100 downTo 0).map { settingsPopupFrame(it / 100f, anchor, panel, 20f) }
        assertEquals(forward.reversed(), reverse)
        forward.forEach { frame ->
            assertTrue(frame.bounds.width > 0f && frame.bounds.height >= 0f)
            assertTrue(frame.bounds.top >= anchor.bottom)
            assertTrue(frame.contentAlpha in 0f..1f)
            assertTrue(frame.shellAlpha in 0f..1f)
            assertTrue(frame.contentAlpha <= frame.shellAlpha)
        }
        forward.zipWithNext().forEach { (a, b) -> assertTrue(a.contentAlpha <= b.contentAlpha) }
    }

    @Test fun missingOrInvalidAnchorFallsBackToWholePanelFade() {
        for (origin in listOf(null, Rect.Zero, Rect(Float.NaN, 0f, 12f, 12f))) {
            val frame = settingsPopupFrame(0.5f, origin, panel, 20f)
            assertEquals(panel, frame.bounds)
            assertEquals(0.5f, frame.contentAlpha)
            assertEquals(0.5f, frame.shellAlpha)
        }
    }

    @Test fun changingPanelHeightKeepsItsTopAnchorAndEndState() {
        for (height in listOf(100f, 300f, 800f)) {
            val bounds = Rect(panel.left, panel.top, panel.right, panel.top + height)
            assertEquals(bounds, settingsPopupFrame(1f, anchor, bounds, 20f).bounds)
            assertEquals(anchor.bottom, settingsPopupFrame(0f, anchor, bounds, 20f).bounds.top)
        }
    }

    @Test fun progressIsClampedForFirstAndLastFrame() {
        assertEquals(settingsPopupFrame(0f, anchor, panel, 20f),
            settingsPopupFrame(-1f, anchor, panel, 20f))
        assertEquals(settingsPopupFrame(1f, anchor, panel, 20f),
            settingsPopupFrame(2f, anchor, panel, 20f))
        assertEquals(settingsPopupFrame(0f, anchor, panel, 20f),
            settingsPopupFrame(Float.NaN, anchor, panel, 20f))
    }

    @Test fun terminalRemnantFadesAtTheSeamInsteadOfFlyingOverButton() {
        val frame = settingsPopupFrame(0.04f, anchor, panel, 20f)
        assertEquals(0f, frame.shellAlpha)
        assertEquals(0f, frame.contentAlpha)
        assertTrue(frame.bounds.top >= anchor.bottom)
    }

    @Test fun panelHasRestrainedOvershootAndSettlesExactly() {
        assertTrue(settingsPopupFrame(0.85f, anchor, panel, 20f).bounds.height > panel.height)
        for (i in 0..100) {
            val frame = settingsPopupFrame(i / 100f, anchor, panel, 20f)
            assertTrue(frame.bounds.width <= panel.width * 1.018f)
            assertTrue(frame.bounds.height <= panel.height * 1.018f)
        }
        assertEquals(panel, settingsPopupFrame(1f, anchor, panel, 20f).bounds)
    }

}
