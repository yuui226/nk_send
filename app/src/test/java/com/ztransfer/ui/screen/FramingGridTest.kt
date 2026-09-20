package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Offset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FramingGridTest {
    @Test
    fun cyclesThroughRequestedStylesAndBackToOff() {
        val visited = mutableListOf<ViewfinderGrid>()
        var grid = ViewfinderGrid.OFF
        repeat(6) {
            visited.add(grid)
            grid = grid.next()
        }
        assertEquals(
            listOf(ViewfinderGrid.OFF, ViewfinderGrid.THIRDS, ViewfinderGrid.FOURTHS,
                ViewfinderGrid.CENTER, ViewfinderGrid.GOLDEN, ViewfinderGrid.OFF),
            visited
        )
    }

    @Test
    fun centerCrossUsesDisplayedCenterAndExcludesDesqueezeLetterboxing() {
        val lines = framingGridLines(ViewfinderGrid.CENTER, 1200f, 800f, (3f / 2f) * 2f)
        assertEquals(
            listOf(
                FramingGridLine(Offset(600f, 200f), Offset(600f, 600f)),
                FramingGridLine(Offset(0f, 400f), Offset(1200f, 400f))
            ), lines
        )
    }

    @Test
    fun goldenGridUsesGoldenFractionsWithinCorrectedImage() {
        val lines = framingGridLines(ViewfinderGrid.GOLDEN, 1200f, 800f, 3f)
        assertEquals(4, lines.size)
        assertEquals(458.3592f, lines[0].start.x, 0.001f)
        assertEquals(741.6408f, lines[2].start.x, 0.001f)
        assertEquals(352.7864f, lines[1].start.y, 0.001f)
        assertEquals(447.2136f, lines[3].start.y, 0.001f)
        assertEquals(200f, lines[0].start.y, 0f)
        assertEquals(600f, lines[0].end.y, 0f)
    }

    @Test
    fun heightLimitedViewportKeepsGridInsideCenteredImage() {
        // A wide viewport during landscape/fullscreen transitions has side bars.
        val lines = framingGridLines(ViewfinderGrid.THIRDS, 2000f, 600f, 2f)
        assertEquals(800f, lines[0].start.x, 0.001f)
        assertEquals(1200f, lines[2].start.x, 0.001f)
        assertEquals(Offset(400f, 200f), lines[1].start)
        assertEquals(Offset(1600f, 200f), lines[1].end)
    }

    @Test
    fun allStylesStayAlignedAcrossFrameShapesRotationsAndDesqueezeMultipliers() {
        val frames = listOf(4f / 3f, 3f / 2f, 16f / 9f)
        val multipliers = listOf(1f, 1.33f, 1.5f, 1.8f, 2f)
        val viewports = listOf(720f to 1280f, 1280f to 720f, 2000f to 600f)
        for ((width, height) in viewports) for (sourceAspect in frames) for (multiplier in multipliers) {
            val aspect = sourceAspect * multiplier
            val imageWidth = minOf(width, height * aspect)
            val imageHeight = imageWidth / aspect
            val left = (width - imageWidth) / 2f
            val top = (height - imageHeight) / 2f
            for (grid in ViewfinderGrid.entries) {
                val lines = framingGridLines(grid, width, height, aspect)
                assertEquals(grid.fractions.size * 2, lines.size)
                grid.fractions.forEachIndexed { index, fraction ->
                    val vertical = lines[index * 2]
                    val horizontal = lines[index * 2 + 1]
                    assertEquals(left + imageWidth * fraction, vertical.start.x, 0.001f)
                    assertEquals(top, vertical.start.y, 0.001f)
                    assertEquals(top + imageHeight, vertical.end.y, 0.001f)
                    assertEquals(top + imageHeight * fraction, horizontal.start.y, 0.001f)
                    assertEquals(left, horizontal.start.x, 0.001f)
                    assertEquals(left + imageWidth, horizontal.end.x, 0.001f)
                }
            }
        }
    }

    @Test
    fun offAndInvalidViewportsHaveNoLines() {
        assertTrue(framingGridLines(ViewfinderGrid.OFF, 1200f, 800f, 1.5f).isEmpty())
        assertTrue(framingGridLines(ViewfinderGrid.GOLDEN, 0f, 800f, 1.5f).isEmpty())
        assertTrue(framingGridLines(ViewfinderGrid.CENTER, 1200f, 0f, 1.5f).isEmpty())
        assertTrue(framingGridLines(ViewfinderGrid.THIRDS, 1200f, 800f, Float.NaN).isEmpty())
    }
}
