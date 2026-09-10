package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class GeniePopupGeometryTest {
    private val anchor = Rect(12f, 40f, 80f, 76f)
    private val panel = Rect(12f, 84f, 388f, 784f)

    @Test fun expandedRowsExactlyMatchOriginalLayout() {
        for (i in 0..GENIE_BANDS) {
            val v = i.toFloat() / GENIE_BANDS
            assertEquals(GenieRow(0f, panel.width, panel.height * v), genieRow(1f, v, anchor, panel))
        }
    }

    @Test fun collapsedRowsStayAtButtonLowerEdgeNotAboveIt() {
        for (i in 0..GENIE_BANDS) {
            val row = genieRow(0f, i.toFloat() / GENIE_BANDS, anchor, panel)
            assertEquals(anchor.bottom - panel.top, row.rightY, 0.001f)
            assertTrue(row.leftY > row.rightY)
            assertEquals(anchor.center.x - panel.left, (row.left + row.right) / 2f, 0.001f)
        }
    }

    @Test fun nearEdgeNarrowsBeforeFarEdgeToFormFunnel() {
        val near = genieRow(0.55f, 0f, anchor, panel)
        val far = genieRow(0.55f, 1f, anchor, panel)
        assertTrue(near.right - near.left < (far.right - far.left) * 0.5f)
    }

    @Test fun rowsNeverFoldCrossOrOvershootButton() {
        for (step in 1..100) {
            val p = step / 100f
            var previousLeftY = Float.NEGATIVE_INFINITY
            var previousRightY = Float.NEGATIVE_INFINITY
            for (i in 0..GENIE_BANDS) {
                val row = genieRow(p, i.toFloat() / GENIE_BANDS, anchor, panel)
                assertTrue(row.leftY >= anchor.bottom - panel.top)
                assertTrue(row.rightY >= anchor.bottom - panel.top)
                assertTrue(row.leftY > previousLeftY)
                assertTrue(row.rightY > previousRightY)
                assertTrue(row.right > row.left)
                assertTrue(row.right - row.left <= panel.width + 0.001f)
                previousLeftY = row.leftY
                previousRightY = row.rightY
            }
        }
    }

    @Test fun trianglesMapCornersAndAllSharedEdgeSamplesWithoutTextureSlips() {
        for (p in listOf(0.02f, 0.25f, 0.5f, 0.8f, 0.99f, 1f)) {
            var previousBottom: List<Offset>? = null
            for (i in 0 until GENIE_BANDS) {
                val top = genieRow(p, i.toFloat() / GENIE_BANDS, anchor, panel)
                val bottom = genieRow(p, (i + 1f) / GENIE_BANDS, anchor, panel)
                val y0 = panel.height * i / GENIE_BANDS
                val y1 = panel.height * (i + 1) / GENIE_BANDS
                val upper = genieBandMatrix(panel.width, y0, y1, top, bottom, upper = true)
                val lower = genieBandMatrix(panel.width, y0, y1, top, bottom, upper = false)
                near(Offset(top.left, top.leftY), upper.map(Offset(0f, y0)))
                near(Offset(top.right, top.rightY), upper.map(Offset(panel.width, y0)))
                near(Offset(bottom.left, bottom.leftY), upper.map(Offset(0f, y1)))
                near(Offset(top.right, top.rightY), lower.map(Offset(panel.width, y0)))
                near(Offset(bottom.right, bottom.rightY), lower.map(Offset(panel.width, y1)))
                near(Offset(bottom.left, bottom.leftY), lower.map(Offset(0f, y1)))
                for (j in 0..8) {
                    val t = j / 8f
                    val diagonal = Offset(panel.width * (1f - t), y0 + (y1 - y0) * t)
                    near(upper.map(diagonal), lower.map(diagonal))
                    previousBottom?.let { near(it[j], upper.map(Offset(panel.width * t, y0))) }
                }
                previousBottom = (0..8).map { lower.map(Offset(panel.width * it / 8f, y1)) }
                for (matrix in listOf(upper, lower)) {
                    assertTrue(matrix.values.all { it.isFinite() })
                    assertTrue(matrix[0, 0] * matrix[1, 1] - matrix[1, 0] * matrix[0, 1] > 0f)
                }
            }
        }
    }

    @Test fun inletContinuouslyWidensInsteadOfHoldingARectangularTube() {
        for (p in listOf(0.25f, 0.4f, 0.55f)) {
            val tip = genieRow(p, 0f, anchor, panel)
            val next = genieRow(p, 0.1f, anchor, panel)
            assertTrue(next.right - next.left > tip.right - tip.left)
        }
    }

    @Test fun leftEdgeAlsoBowsInwardDuringUnfolding() {
        val top = genieRow(0.5f, 0f, anchor, panel)
        val middle = genieRow(0.5f, 0.5f, anchor, panel)
        val bottom = genieRow(0.5f, 1f, anchor, panel)
        assertTrue(middle.left > (top.left + bottom.left) / 2f + 3f)
    }

    @Test fun diagonalInletAndBottomSettleBackToLevel() {
        assertTrue(genieRow(0.5f, 0f, anchor, panel).tilt > 0f)
        val bottom = genieRow(0.5f, 1f, anchor, panel)
        assertTrue(bottom.rightY < bottom.leftY)
        assertTrue(genieRow(0f, 1f, anchor, panel).tilt > 0f)
        assertEquals(0f, genieRow(1f, 1f, anchor, panel).tilt)
        assertTrue(genieRow(0.99f, 1f, anchor, panel).tilt < bottom.tilt * 0.01f)
    }

    @Test fun tiltRemainsBoundedOnWideAndShortPanelsWithoutFoldover() {
        for (height in listOf(100f, 700f, 1800f)) for (step in 1..100) {
            val bounds = Rect(panel.left, panel.top, panel.right, panel.top + height)
            var previous: GenieRow? = null
            for (i in 0..GENIE_BANDS) {
                val row = genieRow(step / 100f, i.toFloat() / GENIE_BANDS, anchor, bounds)
                assertTrue(row.tilt <= bounds.width * 0.045f + 0.001f)
                assertTrue(row.tilt <= (row.right - row.left) * 0.14f + 0.001f)
                previous?.let { assertTrue(row.leftY > it.leftY && row.rightY > it.rightY) }
                previous = row
            }
        }
    }

    @Test fun interruptedOpenAndCloseUseIdenticalShapeAtSameProgress() {
        val forward = (0..100).map { genieRow(it / 100f, 0.4f, anchor, panel) }
        val backward = (100 downTo 0).map { genieRow(it / 100f, 0.4f, anchor, panel) }
        assertEquals(forward.reversed(), backward)
    }

    @Test fun invalidAnchorsCanFallBackWithoutWarping() {
        assertTrue(validGenieAnchor(anchor, panel))
        assertFalse(validGenieAnchor(null, panel))
        assertFalse(validGenieAnchor(Rect.Zero, panel))
        assertFalse(validGenieAnchor(Rect(Float.NaN, 0f, 20f, 30f), panel))
        assertFalse(validGenieAnchor(anchor, Rect.Zero))
        assertFalse(validGenieAnchor(anchor, Rect(0f, 0f, 200f, 400f)))
    }

    @Test fun progressAndFractionsAreBounded() {
        assertEquals(0f, genieProgress(Float.NaN))
        assertEquals(0f, genieProgress(-1f))
        assertEquals(1f, genieProgress(2f))
        assertEquals(genieRow(1f, 1f, anchor, panel), genieRow(2f, 2f, anchor, panel))
    }

    @Test fun differentAnchorPositionsAndPanelHeightsSettleExactly() {
        for (x in listOf(12f, 160f, 312f)) for (height in listOf(100f, 700f, 1800f)) {
            val origin = Rect(x, anchor.top, x + 56f, anchor.bottom)
            val bounds = Rect(panel.left, panel.top, panel.right, panel.top + height)
            assertEquals(GenieRow(0f, bounds.width, bounds.height), genieRow(1f, 1f, origin, bounds))
        }
    }

    @Test fun rightClampedFilterAndDateEditorKeepPositiveTriangleAreas() {
        // Filter can open below a right-hand toolbar button, with its panel clamped leftward.
        for (height in listOf(100f, 240f, 480f)) for (x in listOf(12f, 170f, 312f)) {
            val bounds = Rect(12f, 84f, 372f, 84f + height)
            val origin = Rect(x, 40f, x + 56f, 76f)
            assertTrue(validGenieAnchor(origin, bounds))
            for (step in 3..99) for (i in 0 until GENIE_BANDS) {
                val top = genieRow(step / 100f, i.toFloat() / GENIE_BANDS, origin, bounds)
                val bottom = genieRow(step / 100f, (i + 1f) / GENIE_BANDS, origin, bounds)
                for (upper in listOf(true, false)) {
                    val m = genieBandMatrix(bounds.width, height * i / GENIE_BANDS,
                        height * (i + 1) / GENIE_BANDS, top, bottom, upper)
                    assertTrue(m.values.all { it.isFinite() })
                    assertTrue(m[0, 0] * m[1, 1] - m[1, 0] * m[0, 1] > 0f,
                        "height=$height anchorX=$x progress=$step band=$i upper=$upper")
                }
            }
        }
    }

    private fun near(expected: Offset, actual: Offset) {
        assertEquals(expected.x, actual.x, 0.05f)
        assertEquals(expected.y, actual.y, 0.05f)
    }

    @Test fun mouthMatchesLogoWidthAcrossDensitiesAndDifferentButtonPaddings() {
        assertEquals(27.2f, GENIE_Z_MARK_WIDTH_DP, 0.001f)
        for (density in listOf(1f, 2f, 3.5f)) for (buttonWidth in listOf(52f, 56f, 68f)) {
            val origin = Rect(12f * density, 40f * density,
                (12f + buttonWidth) * density, 76f * density)
            val bounds = Rect(12f * density, 84f * density, 388f * density, 784f * density)
            val expectedWidth = GENIE_Z_MARK_WIDTH_DP * density
            val row = genieRow(0f, 0f, origin, bounds, expectedWidth)
            assertEquals(expectedWidth, row.right - row.left, 0.001f)
            assertTrue(row.right - row.left < origin.width)
            assertEquals(origin.bottom - bounds.top, row.rightY, 0.001f)
        }
    }

    @Test fun easingIsMonotonicBoundedAndHasASoftLanding() {
        for (curve in listOf(GenieExpandEasing, GenieCollapseEasing)) {
            assertEquals(0f, curve.transform(0f))
            assertEquals(1f, curve.transform(1f))
            var previous = 0f
            for (step in 1..100) {
                val current = curve.transform(step / 100f)
                assertTrue(current in previous..1f)
                previous = current
            }
            val middle = curve.transform(0.55f) - curve.transform(0.45f)
            val landing = curve.transform(1f) - curve.transform(0.9f)
            assertTrue(landing < middle * 0.3f)
        }
        assertTrue(GenieExpandEasing.transform(0.25f) > 0.25f)
        assertTrue(GenieCollapseEasing.transform(0.1f) < 0.1f)
    }
}
