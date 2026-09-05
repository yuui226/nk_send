package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Offset
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class QueueFlightCurveTest {
    private fun point(p: Float, from: Offset, to: Offset) =
        queueFlightBezierPoint(p, from, to, 36f, 90f, 12f, 52f, 160f)

    @Test fun endpointsAndOutOfRangeProgressClampExactly() {
        val start = Offset(120f, 700f)
        val end = Offset(950f, 90f)
        for (p in listOf(-1f, -0.001f, 0f)) assertEquals(start, point(p, start, end))
        for (p in listOf(1f, 1.001f, 2f)) assertEquals(end, point(p, start, end))
    }

    @Test fun verticalPathBowsLeftInsteadOfFlyingStraight() {
        assertEquals(Offset(74f, 182f), point(0.5f, Offset(100f, 500f), Offset(100f, 100f)))
        assertEquals(Offset(74f, 82f), point(0.5f, Offset(100f, 100f), Offset(100f, 100f)))
    }

    @Test fun widePathCapsLiftAndFadesHorizontalBow() {
        assertEquals(Offset(500f, 197.5f), point(0.5f, Offset(100f, 700f), Offset(900f, 90f)))
    }

    @Test fun nearTopEndpointsKeepOriginalApexControlEvenWhenItBendsDown() {
        assertEquals(Offset(74f, 12f), point(0.5f, Offset(100f, 4f), Offset(100f, 4f)))
    }

    @Test fun reversingEndpointsPreservesTheSameCurve() {
        val start = Offset(100f, 700f)
        val end = Offset(900f, 90f)
        for (i in 0..8) {
            val p = i / 8f
            assertEquals(point(p, start, end), point(1f - p, end, start))
        }
        assertEquals(0f, QueueFlightEasing.transform(0f))
        assertEquals(1f, QueueFlightEasing.transform(1f))
    }

    @Test fun floorModKeepsNegativeRotationsAndIntegerExtremes() {
        for ((value, expected) in listOf(-5 to 3, -4 to 0, -1 to 3, 0 to 0, 5 to 1, Int.MIN_VALUE to 0, Int.MAX_VALUE to 3)) {
            assertEquals(expected, previewFloorMod(value, 4))
            assertTrue(previewFloorMod(value, 4) in 0..3)
        }
    }
}
